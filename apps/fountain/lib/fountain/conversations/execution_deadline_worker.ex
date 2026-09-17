defmodule Fountain.Conversations.ExecutionDeadlineWorker do
  @moduledoc """
  Drives the execution journal independently of conversation mailboxes.

  Expiration and termination have separate bounded task pools. A blocked provider
  call cannot occupy the slots that expire other turns. Every task has its own
  hard local timeout, including after this coordinator dies. Killing a local
  task says nothing about remote termination: the journal retains submitted
  intent, and recovery marks an abandoned attempt uncertain without replaying it.

  An obligation nothing can resolve is written off rather than retried. A lost
  or failed termination leaves `uncertain`, and the journal deliberately never
  authorizes a second provider write for the same attempt — so the exit is age,
  not a retry: past `@abandon_after_seconds` the row retires to `stopped` with
  its `last_error` intact. Without that, one slow `terminate_session` fenced a
  conversation and its shared home for good, and took `reset_sandbox/2` with it.

  Off unless configured. `runtime.exs` starts this only where
  `FOUNTAIN_EXECUTION_LIMITS` sets a host ceiling, because the tick is a poll of
  `turn_executions` on every node and a deployment that has not asked for
  bounded turns should pay nothing for them.

  Public admission remains disabled until trusted identity and all lifecycle
  paths are integrated. This worker alone does not enable bounded execution.
  """
  use GenServer

  require Logger

  alias Fountain.Conversations.ExecutionGuard

  @pool_size 8
  @batch_size 100
  @job_timeout_ms 10_000
  @recovery_after_seconds 60
  # How long an obligation nothing can resolve keeps its fence. Past this a row
  # in `awaiting_identity` or `uncertain` is written off with its `last_error`
  # intact — see `ExecutionGuard._unsafe_retire_unresolved/2` for why giving up
  # is the right answer and what it does not claim.
  #
  # Two minutes, measured rather than guessed (#1925). The last moment anything
  # can still resolve one of these rows is the command transport's `:drain_end`,
  # which it arms at `deadline + 30_000` — after that no late `bind_identity`
  # and no late acknowledgment can arrive, because the process that held the
  # attempt is gone. Two minutes clears that with margin, and it composes with
  # `@recovery_after_seconds` because a row's clock starts when it *enters*
  # `uncertain`, not when it was submitted.
  #
  # This is also the tenant's only exit: reset refuses while a bounded
  # execution is unresolved, and #1925 settled that there is no
  # `reset_sandbox(force: true)` to skip the wait — so the number is how long
  # an owner can be locked out of their own machine. An hour was not a
  # defensible answer to that; two minutes is.
  @abandon_after_seconds 120

  # `terminate_session/3` is only wired for Sprites (`ExecutionTransport` refuses
  # every other provider, and admission rolls back `:provider_not_supported`), so
  # this map says so rather than implying four backends work. A provider joins it
  # in the PR that teaches the transport to spawn there.
  @providers %{"sprites" => :sprites}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :tick)

    {:ok,
     %{
       jobs: %{},
       interval:
         Keyword.get(
           opts,
           :interval_ms,
           Application.get_env(:fountain, :execution_deadline_interval_ms, 5_000)
         ),
       timeout: Keyword.get(opts, :job_timeout_ms, @job_timeout_ms),
       supervisor: Keyword.get(opts, :task_supervisor, Fountain.TaskSupervisor),
       terminator: Keyword.get(opts, :terminator, &terminate_session/1)
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)
    state = start_single(state, :scan, &scan/0)

    state =
      start_single(state, :recovery, fn ->
        now = DateTime.utc_now()
        # ownership: system recovery of persisted intents; neither call grants a
        # provider write. The first hands an abandoned attempt back to the
        # retry path below by marking it uncertain; the second gives up on one
        # that has been uncertain long enough that nothing will ever resolve it.
        ExecutionGuard._unsafe_recover_submissions(
          DateTime.add(now, -@recovery_after_seconds, :second)
        )

        ExecutionGuard._unsafe_retire_unresolved(
          DateTime.add(now, -@abandon_after_seconds, :second)
        )
      end)

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{kind: :scan}, jobs} ->
        Process.demonitor(ref, [:flush])
        state = %{state | jobs: jobs}
        state = start_candidates(state, :expiry, result.due)
        {:noreply, start_candidates(state, :termination, result.ready)}

      {_job, jobs} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | jobs: jobs}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # The durable claim, if any, remains submitted until recovery. Never infer
    # a remote result from a local exit or grant another provider write here.
    {:noreply, %{state | jobs: Map.delete(state.jobs, ref)}}
  end

  # Defining the clauses above removed the `handle_info/2` that `use GenServer`
  # supplies, so without this one an `:EXIT` from a linked process, a `:DOWN`
  # that is not a process down, or any telemetry or PubSub message would raise
  # and take the worker with it (#2380). That costs the in-flight `jobs` map —
  # recovery covers the durable side, the tasks themselves do not survive — and
  # a share of the application supervisor's restart budget, for a message the
  # worker was never going to act on. So log the shape and carry on.
  #
  # The tick is deliberately not re-armed here: it is armed once in `init/1`
  # and re-armed by the `:tick` clause, and a stray message is not a tick.
  def handle_info(message, state) do
    Logger.warning("execution deadline worker: unexpected message #{shape(message)}; ignoring")

    {:noreply, state}
  end

  # The tag and the arity, never the payload: an unexpected `{ref, result}`
  # here carries a scan's rows, and a log line is not a place to put them.
  defp shape(message) when is_tuple(message) and tuple_size(message) > 0,
    do: "#{inspect(elem(message, 0))}/#{tuple_size(message)}"

  defp shape(message) when is_atom(message), do: inspect(message)
  defp shape(_message), do: "an unrecognized term"

  @impl true
  def terminate(_reason, state) do
    # Give short journal writes time to finish before forcing local shutdown.
    # A blocked provider still gets only this bounded grace, never confirmation.
    state.jobs
    |> Enum.map(fn {_ref, job} -> job.task end)
    |> Task.yield_many(timeout: 1_000)
    |> Enum.each(fn {task, result} ->
      if is_nil(result), do: Task.shutdown(task, :brutal_kill)
    end)

    :ok
  end

  defp scan do
    now = DateTime.utc_now()

    # ownership: system-wide journal scan; these reads grant no provider authority.
    %{
      due: ExecutionGuard._unsafe_due_deadlines(now, @batch_size),
      ready: ExecutionGuard._unsafe_ready_terminations(@batch_size)
    }
  end

  defp start_single(state, kind, fun) do
    if Enum.any?(state.jobs, fn {_ref, job} -> job.kind == kind end),
      do: state,
      else: start_job(state, kind, nil, fun)
  end

  defp start_candidates(state, kind, ids) do
    busy = MapSet.new(state.jobs, fn {_ref, job} -> job.id end)
    used = Enum.count(state.jobs, fn {_ref, job} -> job.kind == kind end)

    ids
    |> Enum.reject(&MapSet.member?(busy, &1))
    # `max(_, 0)`: a negative count makes `Enum.take/2` take from the END of the
    # list rather than return `[]`, which would start the wrong jobs instead of
    # none. `used` cannot exceed the pool today; this is so that staying true is
    # not load-bearing.
    |> Enum.take(max(@pool_size - used, 0))
    |> Enum.reduce(state, fn id, state ->
      fun =
        case kind do
          # ownership: system scan selected this journal's immutable turn binding.
          # Do not pass the scan's pre-lock clock to the authority check.
          :expiry -> fn -> ExecutionGuard._unsafe_expire(id) end
          :termination -> fn -> stop(id, state.terminator) end
        end

      start_job(state, kind, id, fun)
    end)
  end

  defp start_job(state, kind, id, fun) do
    timeout = state.timeout

    task =
      Task.Supervisor.async_nolink(state.supervisor, fn ->
        {:ok, timer} = :timer.kill_after(timeout)

        try do
          fun.()
        after
          :timer.cancel(timer)
        end
      end)

    %{state | jobs: Map.put(state.jobs, task.ref, %{task: task, kind: kind, id: id})}
  end

  defp stop(id, terminator) do
    # ownership: system-selected journal id; the claim rechecks tenant and sandbox binding.
    case ExecutionGuard._unsafe_claim_termination(id) do
      {:ok, %{permitted: true, execution: attempt}} ->
        result = call_terminator(terminator, attempt)
        ExecutionGuard._unsafe_record_termination(id, attempt.attempt_id, result)

      other ->
        other
    end
  end

  defp call_terminator(terminator, attempt) do
    terminator.(attempt)
  rescue
    _ -> {:error, :termination_unconfirmed}
  catch
    _, _ -> {:error, :termination_unconfirmed}
  end

  defp terminate_session(attempt) do
    with {:ok, provider} <- Map.fetch(@providers, attempt.provider) do
      handle = Managoat.Sandbox.build_handle(provider, attempt.sandbox_name)
      Managoat.Sandbox.terminate_session(handle, attempt.provider_session_id, timeout_ms: 5_000)
    else
      :error -> {:error, :not_supported}
    end
  end
end
