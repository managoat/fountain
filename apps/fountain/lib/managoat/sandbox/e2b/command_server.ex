defmodule Managoat.Sandbox.E2B.CommandServer do
  @moduledoc """
  One process per streaming E2B command: owns the Connect stream, translates
  envd events into the `Managoat.Sandbox` owner-frame contract, and
  heartbeats the sandbox TTL while the command lives.

  E2B sandboxes always carry a TTL, so a long agent turn must keep extending
  it — a missed heartbeat degrades to an auto-pause (state preserved), never
  a kill, because the adapter creates sandboxes with `autoPause: true`.

  Frame mapping (envd `StartResponse`/`ConnectResponse` events, JSON codec):

    * `data.stdout` / `data.stderr` (base64) → `{:stdout | :stderr, %{ref: ref}, bin}`
    * `end.exitCode` → `{:exit, %{ref: ref}, code}`
    * EndStream (flag 2) with an error → `{:error, %{ref: ref}, reason}`
    * EndStream without a preceding end event → `{:error, %{ref: ref},
      :closed_before_exit}` — the stream ended with the command's fate
      unknown, and the contract forbids fabricating a zero for it. In
      `:attach` mode the shim's exit file is the one authority that outlives
      the stream, so a readable one still yields the `{:exit, _, code}` it
      records
    * transport failure → `{:error, %{ref: ref}, reason}` — the process may
      still be running sandbox-side; reattach exists for exactly this

  In `:attach` mode the stream is a `tail`-based replayer over the journal
  files the spawn shim wrote (see `Managoat.Sandbox.E2B`), so the buffered
  output replays from byte zero; the real exit code is read from the shim's
  exit file when the replayer ends.
  """

  use GenServer

  alias Managoat.Sandbox.E2B.Api
  alias Managoat.Sandbox.E2B.Envd

  require Logger

  @heartbeat_ms 240_000

  def start(opts), do: GenServer.start(__MODULE__, opts)

  def write_stdin(pid, data), do: GenServer.call(pid, {:write_stdin, data})
  def close_stdin(pid), do: GenServer.call(pid, :close_stdin)

  @doc """
  Block until envd acknowledges the process (its `start` event, always the
  stream's first frame) or the stream dies first.

  Spawn must not return before this: the caller's first `write_stdin` —
  the ACP peer writes `initialize` immediately — addresses the process by
  tag, and a SendInput that races envd's registration 404s, which reads as
  "process exited" and fails the turn before it began. Measured live on
  prod (2026-08-14): the race lost twice in a row at ~300ms.
  """
  def await_start(pid, timeout) do
    GenServer.call(pid, :await_start, timeout)
  catch
    # Already gone = the command ran its whole life before we asked; its
    # terminal frame is in the owner's mailbox and that is the truth. Only
    # a live-but-silent server is a failed start.
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, _ -> {:error, {:unavailable, :start_timeout}}
  end

  @impl true
  def init(opts) do
    state = %{
      sandbox_id: Keyword.fetch!(opts, :sandbox_id),
      tag: Keyword.fetch!(opts, :tag),
      ref: Keyword.fetch!(opts, :ref),
      owner: Keyword.fetch!(opts, :owner),
      # In attach mode, stdin targets the ORIGINAL tagged process while the
      # stream comes from the replayer.
      stdin_tag: Keyword.get(opts, :stdin_tag, Keyword.fetch!(opts, :tag)),
      # The pid stdin is addressed by once known: from this stream's start
      # event when stdin is this process's own, or looked up from the tag the
      # first time a tag selector is refused. See `stdin_target/1`.
      stdin_pid: nil,
      attach?: Keyword.has_key?(opts, :stdin_tag),
      request: Keyword.fetch!(opts, :request),
      exit_file: Keyword.get(opts, :exit_file),
      buffer: <<>>,
      exited?: false,
      started?: false,
      await_from: nil,
      heartbeat: nil,
      stream_task: nil
    }

    {:ok, state, {:continue, :open_stream}}
  end

  @impl true
  def handle_continue(:open_stream, state) do
    server = self()
    %{sandbox_id: sandbox_id, request: {path, payload}} = state

    task =
      Task.async(fn ->
        Req.post(Envd.req(sandbox_id),
          url: "/" <> path,
          headers: [{"content-type", Envd.stream_content_type()}],
          body: Envd.encode_frame(payload),
          receive_timeout: :infinity,
          into: fn {:data, data}, {req, resp} ->
            send(server, {:chunk, data})
            {:cont, {req, resp}}
          end
        )
      end)

    heartbeat = :timer.send_interval(@heartbeat_ms, :heartbeat)
    {:noreply, %{state | stream_task: task, heartbeat: heartbeat}}
  end

  @impl true
  def handle_call({:write_stdin, data}, _from, state) do
    # By the time writes are allowed the process has been start-acked, so a
    # 404 here means it has since exited — the contract's :command_exited.
    {reply, state} =
      with_stdin_target(state, &Envd.send_input(state.sandbox_id, &1, data))

    reply =
      case reply do
        {:error, {:api_error, 404, _body}} -> {:error, :command_exited}
        other -> other
      end

    {:reply, reply, state}
  end

  def handle_call(:await_start, _from, %{started?: true} = state), do: {:reply, :ok, state}

  def handle_call(:await_start, _from, %{exited?: true} = state),
    do: {:reply, {:error, :command_exited}, state}

  def handle_call(:await_start, from, state), do: {:noreply, %{state | await_from: from}}

  def handle_call(:close_stdin, _from, state) do
    {reply, state} = with_stdin_target(state, &Envd.close_stdin(state.sandbox_id, &1))
    {:reply, reply, state}
  end

  # Address stdin by pid when it is known, else by tag. A resumed sandbox's
  # envd refuses a tag selector with 404 while it still lists the process
  # under that tag, so a refused tag is resolved to its pid once and the call
  # retried; the pid is kept for every later call. A tag envd no longer lists
  # is a process that has exited, and the 404 stands.
  defp with_stdin_target(%{stdin_pid: pid} = state, call) when is_integer(pid),
    do: {call.({:pid, pid}), state}

  defp with_stdin_target(state, call) do
    case call.(state.stdin_tag) do
      {:error, {:api_error, 404, _body}} = refused ->
        case Envd.pid_for_tag(state.sandbox_id, state.stdin_tag) do
          {:ok, pid} -> {call.({:pid, pid}), %{state | stdin_pid: pid}}
          _ -> {refused, state}
        end

      other ->
        {other, state}
    end
  end

  @impl true
  def handle_info({:chunk, data}, state) do
    {frames, rest} = Envd.decode_frames(state.buffer <> data)
    state = Enum.reduce(frames, %{state | buffer: rest}, &handle_frame/2)

    if state.exited? do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:heartbeat, state) do
    case Api.set_timeout(Envd.id_of(state.sandbox_id)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("e2b: TTL heartbeat failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info({ref, result}, %{stream_task: %Task{ref: ref}} = state) do
    # The HTTP request finished. If no terminal frame was delivered yet, this
    # is where the close-without-exit and transport-failure verdicts land.
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, _resp} -> finish(state, :closed_before_exit)
        {:error, reason} -> finish(state, {:error, reason})
      end

    {:stop, :normal, %{state | stream_task: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    state = finish(state, {:error, {:stream_task_down, reason}})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.heartbeat, do: :timer.cancel(state.heartbeat)
    if state.stream_task, do: Task.shutdown(state.stream_task, :brutal_kill)
    :ok
  end

  # ── frame handling ─────────────────────────────────────────────────────────

  defp handle_frame({:message, %{"event" => event}}, state), do: handle_event(event, state)
  defp handle_frame({:message, _other}, state), do: state

  defp handle_frame({:end_stream, trailers}, state) do
    case trailers do
      %{"error" => error} when not is_nil(error) -> finish(state, {:error, error})
      _ -> finish(state, :closed_before_exit)
    end
  end

  # The start event names the process's pid. It is stdin's target only when
  # stdin is this process's own: an attach streams from a replayer and writes
  # to the original process, whose pid is looked up instead.
  defp handle_event(%{"start" => start}, state) do
    if state.await_from, do: GenServer.reply(state.await_from, :ok)

    pid =
      case {state.attach?, start} do
        {false, %{"pid" => pid}} when is_integer(pid) -> pid
        _ -> state.stdin_pid
      end

    %{state | started?: true, await_from: nil, stdin_pid: pid}
  end

  defp handle_event(%{"data" => data}, state) do
    emit_data(state, :stdout, data["stdout"])
    emit_data(state, :stderr, data["stderr"])
    state
  end

  defp handle_event(%{"end" => end_event}, state) do
    finish(state, {:exit, end_event["exitCode"] || 0})
  end

  defp handle_event(_other, state), do: state

  defp emit_data(_state, _stream, nil), do: :ok

  defp emit_data(state, stream, base64) do
    case Base.decode64(base64) do
      {:ok, ""} -> :ok
      {:ok, bin} -> send(state.owner, {stream, %{ref: state.ref}, bin})
      :error -> :ok
    end
  end

  # Exactly one terminal frame, ever. In attach mode the replayer's own clean
  # exit is a proxy — the real code comes from the shim's exit file.
  defp finish(%{exited?: true} = state, _terminal), do: state

  # The stream ended with no exit event. The shim's exit file outlives the
  # stream, so in attach mode it can still answer with the real code; with no
  # file, or an unreadable one, the fate is unknown and the frame says so.
  defp finish(state, :closed_before_exit) do
    case state.exit_file && read_exit_code(state) do
      {:ok, code} -> deliver_exit(state, code)
      _no_authority -> finish(state, {:error, :closed_before_exit})
    end
  end

  defp finish(state, {:exit, code}) do
    deliver_exit(state, if(state.exit_file, do: read_exit_code(state, code), else: code))
  end

  defp finish(state, {:error, reason}) do
    send(state.owner, {:error, %{ref: state.ref}, reason})
    state |> fail_waiter(reason) |> Map.put(:exited?, true)
  end

  defp deliver_exit(state, code) do
    send(state.owner, {:exit, %{ref: state.ref}, code})
    state |> fail_waiter(:command_exited) |> Map.put(:exited?, true)
  end

  # A stream that dies before the start ack means the spawn never happened —
  # the blocked caller gets the verdict instead of a timeout.
  defp fail_waiter(%{await_from: nil} = state, _reason), do: state

  defp fail_waiter(state, reason) do
    GenServer.reply(state.await_from, {:error, reason})
    %{state | await_from: nil}
  end

  defp read_exit_code(state, fallback) do
    case read_exit_code(state) do
      {:ok, code} -> code
      :error -> fallback
    end
  end

  defp read_exit_code(state) do
    with {:ok, contents} <- Envd.read_file(state.sandbox_id, state.exit_file),
         {code, _rest} <- Integer.parse(String.trim(contents)) do
      {:ok, code}
    else
      _unreadable -> :error
    end
  end
end
