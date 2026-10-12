defmodule Fountain.Conversations.ExecutionTransport do
  @moduledoc """
  Owns one bounded command outside the conversation actor.

  Spawn intent precedes I/O. Only provider control metadata matching the returned
  command reference can bind identity; stdin remains closed to callers until
  that binding succeeds. Each write rechecks the durable journal. A failed or
  timed-out write retires the entire execution and is never replayed.

  Local task termination is not remote confirmation. Late identity can still
  make an expired spawn cleanable; after a bounded drain, unresolved intent stays
  in the journal. Public admission remains disabled pending released identity
  support and complete lifecycle integration.

  **Sprites only, and that is a real limit rather than a staging detail.**
  `_unsafe_start/5` refuses any other provider with `:provider_not_supported`,
  and admission rolls back the same way, because binding a provider-issued
  session id from trusted control metadata is a per-adapter capability and only
  the Sprites adapter has it. E2B and self-hosted runners (ADR 0018,
  ADR 0022) therefore cannot carry a bounded turn at all. They get a refusal at
  admission, not a silently unbounded turn — a caller that asks for a limit and
  is told no is fine; one that asks and is ignored is not.

  The `:deadline` timer set in `init/1` is not the enforcement mechanism. It is
  a local convenience for a process that happens to still be alive; the
  guarantee is the absolute `deadline_at` on the journal row, which
  `ExecutionDeadlineWorker` acts on whether or not this process survived.
  """
  use GenServer, restart: :temporary

  alias Fountain.Repo
  alias Fountain.Conversations.{ExecutionGuard, TurnExecution}
  alias Managoat.Sandbox
  alias Managoat.Sandbox.Command

  @buffer_bytes 262_144
  @buffer_frames 64

  @doc "System-owned launch of an already registered execution; never retries a spawn."
  def _unsafe_start(id, owner, program, args, opts \\ []) do
    # ownership: internal caller registered this execution for its owned actor;
    # the spawn claim rechecks the immutable tenant/sandbox binding before I/O.
    with %TurnExecution{provider: "sprites"} <- Repo.get(TurnExecution, id),
         {:ok, execution} <- ExecutionGuard._unsafe_claim_spawn(id),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             Fountain.ExecutionTransportSupervisor,
             {__MODULE__,
              execution: execution,
              owner: owner,
              io_timeout_ms: Keyword.get(opts, :io_timeout_ms, 30_000)}
           ),
         :ok <- call(pid, {:spawn, program, args, opts}, 30_000) do
      {:ok, pid}
    else
      nil -> {:error, :not_found}
      %TurnExecution{} -> {:error, :provider_not_supported}
      error -> error
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def await_ready(pid, timeout \\ 30_000), do: call(pid, :ready, timeout)
  def write(pid, data, timeout \\ 30_000), do: call(pid, {:write, data}, timeout)
  @doc "Acknowledge persisted retirement intent, not confirmed remote termination."
  def close(pid), do: call(pid, :close, 30_000)

  # A dead transport and a transport that did not answer in time mean different
  # things to the journal: the first cannot be mid-write, the second may be. Both
  # used to arrive as `:transport_unavailable`, which reads as "nothing
  # happened" and is only true of the first.
  defp call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :transport_timeout}
    :exit, _ -> {:error, :transport_unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    execution = Keyword.fetch!(opts, :execution)
    owner = Keyword.fetch!(opts, :owner)
    remaining = schedule_deadline(execution)
    Process.send_after(self(), :drain_end, remaining + 30_000)

    {:ok,
     %{
       execution: execution,
       owner: owner,
       owner_ref: Process.monitor(owner),
       command: nil,
       phase: :new,
       ready_waiter: nil,
       close_waiter: nil,
       retired: false,
       jobs: %{},
       buffer: [],
       bytes: 0,
       io_timeout: Keyword.fetch!(opts, :io_timeout_ms)
     }}
  end

  @impl true
  def handle_call({:spawn, program, args, opts}, _from, %{phase: :new} = state) do
    owner = self()
    name = state.execution.sandbox_name

    # No credential-bearing spawn options enter the supervisor's child spec.
    opts =
      Keyword.take(opts, [:env, :dir, :tty]) ++
        [owner: owner, session_info: true, stdin: true, detachable: true]

    state =
      start_job(%{state | phase: :spawning}, :spawn, nil, fn ->
        handle = Sandbox.build_handle(:sprites, name)
        Sandbox.spawn(handle, program, args, opts)
      end)

    {:reply, :ok, state}
  end

  def handle_call({:spawn, _, _, _}, _from, state),
    do: {:reply, {:error, :execution_fenced}, state}

  def handle_call(:close, from, state) do
    cond do
      state.retired -> {:reply, :ok, state}
      state.close_waiter -> {:reply, {:error, :already_closing}, state}
      true -> {:noreply, retire(%{state | close_waiter: from})}
    end
  end

  def handle_call(:ready, from, state) do
    cond do
      live?(state) -> {:reply, {:ok, state.command}, state}
      state.phase in [:fenced, :exited] -> {:reply, {:error, :execution_fenced}, state}
      state.ready_waiter -> {:reply, {:error, :already_waiting}, state}
      true -> {:noreply, %{state | ready_waiter: from}}
    end
  end

  def handle_call({:write, data}, from, state) do
    cond do
      not live?(state) ->
        {:reply, {:error, :execution_fenced}, state}

      Enum.any?(state.jobs, fn {_, job} -> job.kind == :write end) ->
        {:reply, {:error, :write_pending}, state}

      true ->
        execution = state.execution
        command = state.command

        task = fn ->
          # ownership: this transport holds the original registered connection;
          # the journal rechecks its tenant, command identity and absolute deadline.
          case ExecutionGuard._unsafe_authorize_write(execution.id, execution.connection_id) do
            {:ok, %{permitted: true}} -> Sandbox.write_stdin(command, data)
            _ -> {:refused, :execution_fenced}
          end
        end

        {:noreply, start_job(state, :write, from, task)}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        {:noreply, state}

      {job, jobs} ->
        Process.demonitor(ref, [:flush])
        {:noreply, complete_job(job, result, %{state | jobs: jobs})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:noreply, retire(state)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        {:noreply, state}

      {job, jobs} ->
        if job.from, do: GenServer.reply(job.from, {:error, :operation_unconfirmed})
        state = %{state | jobs: jobs}
        if job.kind == :retire, do: Process.send_after(self(), :retry_retire, 1_000)
        {:noreply, retire(state)}
    end
  end

  def handle_info({kind, %{ref: _}, _} = frame, state)
      when kind in [:session_info, :stdout, :stderr, :exit, :error] do
    {:noreply, accept_frame(frame, state)}
  end

  def handle_info(:retire, state), do: {:noreply, retire(state)}

  def handle_info(:deadline, state) do
    # A relative timer is only a wakeup hint. Rounding or a clock adjustment
    # must not retire a still-valid journal as an ordinary interruption.
    if DateTime.compare(DateTime.utc_now(), state.execution.deadline_at) == :lt do
      schedule_deadline(state.execution)
      {:noreply, state}
    else
      {:noreply, retire(state)}
    end
  end

  def handle_info(:retry_retire, state), do: {:noreply, request_retirement(state)}
  def handle_info(:drain_end, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_deadline(execution) do
    microseconds = DateTime.diff(execution.deadline_at, DateTime.utc_now(), :microsecond)
    milliseconds = max(div(microseconds + 999, 1_000), 0)
    Process.send_after(self(), :deadline, milliseconds)
    milliseconds
  end

  defp complete_job(%{kind: :spawn}, {:ok, %Command{provider: :sprites} = command}, state) do
    buffered = Enum.reverse(state.buffer)
    state = %{state | command: command, buffer: [], bytes: 0}
    Enum.reduce(buffered, state, &accept_frame/2)
  end

  defp complete_job(%{kind: :spawn}, _result, state), do: retire(state)

  defp complete_job(%{kind: :write, from: from}, :ok, state) do
    GenServer.reply(from, if(live?(state), do: :ok, else: {:error, :execution_fenced}))
    state
  end

  defp complete_job(%{kind: :write, from: from}, {:refused, reason}, state) do
    GenServer.reply(from, {:error, reason})
    retire(state)
  end

  defp complete_job(%{kind: :write, from: from}, _result, state) do
    GenServer.reply(from, {:error, :operation_unconfirmed})
    retire(state)
  end

  defp complete_job(%{kind: :retire}, {:ok, _}, state) do
    send(state.owner, {:execution_retired, state.execution.id})
    if state.close_waiter, do: GenServer.reply(state.close_waiter, :ok)
    Process.send_after(self(), :drain_end, 30_000)
    %{state | retired: true, close_waiter: nil}
  end

  defp complete_job(%{kind: :retire}, _result, state) do
    Process.send_after(self(), :retry_retire, 1_000)
    state
  end

  defp accept_frame(frame, %{command: nil} = state) do
    bytes = :erlang.external_size(frame)

    if length(state.buffer) < @buffer_frames and state.bytes + bytes <= @buffer_bytes,
      do: %{state | buffer: [frame | state.buffer], bytes: state.bytes + bytes},
      else: retire(state)
  end

  # Seal writes on exit but let the actor interpret its terminal frame. Racing
  # that decision with an invented interruption can overwrite a valid reply.
  # The original deadline and owner monitor remain active until it records one.
  defp accept_frame(_frame, %{phase: :exited} = state), do: state

  defp accept_frame({:session_info, %{ref: ref}, id}, %{command: %{ref: ref}} = state) do
    execution = state.execution

    # ownership: provider control metadata matches this transport's command ref;
    # bind it only to the original journal and connection, including after expiry.
    case ExecutionGuard._unsafe_bind_identity(execution.id, execution.connection_id, id) do
      {:ok, %{state: "active", provider_session_id: ^id} = bound} when state.phase != :fenced ->
        state = %{state | execution: bound, phase: :ready}

        if live?(state) do
          if state.ready_waiter, do: GenServer.reply(state.ready_waiter, {:ok, state.command})
          %{state | ready_waiter: nil}
        else
          retire(state)
        end

      _ ->
        retire(state)
    end
  end

  defp accept_frame({:exit, %{ref: ref}, _} = frame, %{command: %{ref: ref}} = state) do
    if live?(state) do
      send(state.owner, frame)
      %{state | phase: :exited}
    else
      retire(state)
    end
  end

  defp accept_frame({kind, %{ref: ref}, _} = frame, %{command: %{ref: ref}} = state) do
    if live?(state), do: send(state.owner, frame)
    if kind in [:exit, :error], do: retire(state), else: state
  end

  defp accept_frame(_frame, state), do: state

  defp live?(state),
    do:
      state.phase == :ready and
        DateTime.compare(DateTime.utc_now(), state.execution.deadline_at) == :lt

  defp retire(%{phase: :fenced} = state), do: request_retirement(state)

  defp retire(state) do
    if state.ready_waiter, do: GenServer.reply(state.ready_waiter, {:error, :execution_fenced})
    state = %{state | phase: :fenced, ready_waiter: nil}
    request_retirement(state)
  end

  defp request_retirement(%{retired: true} = state), do: state

  defp request_retirement(state) do
    if Enum.any?(state.jobs, fn {_, job} -> job.kind == :retire end) do
      state
    else
      execution = state.execution

      start_job(state, :retire, nil, fn ->
        # ownership: retire only this transport's original journal; remote cleanup
        # is driven independently from its persisted intent by the deadline worker.
        ExecutionGuard._unsafe_complete(execution.id, "interrupted")
      end)
    end
  end

  defp start_job(state, kind, from, fun) do
    timeout = if kind == :write, do: min(state.io_timeout, 5_000), else: state.io_timeout

    task =
      Task.Supervisor.async_nolink(Fountain.TaskSupervisor, fn ->
        {:ok, timer} = :timer.kill_after(timeout)

        try do
          fun.()
        rescue
          _ -> {:error, :operation_unconfirmed}
        catch
          _, _ -> {:error, :operation_unconfirmed}
        after
          :timer.cancel(timer)
        end
      end)

    %{state | jobs: Map.put(state.jobs, task.ref, %{task: task, kind: kind, from: from})}
  end

  @impl true
  def terminate(_reason, state) do
    state.jobs
    |> Enum.map(fn {_, job} -> job.task end)
    |> Task.yield_many(timeout: 1_000)
    |> Enum.each(fn {task, result} ->
      if is_nil(result), do: Task.shutdown(task, :brutal_kill)
    end)

    # This closes only the local transport. The journal retains its remote
    # cleanup obligation even when the SDK confirms local shutdown.
    if state.command, do: Sandbox.stop_command(state.command)

    :ok
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, %{execution_id: state.execution.id, phase: state.phase}}
      {key, _value} when key in [:message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      entry -> entry
    end)
  end
end
