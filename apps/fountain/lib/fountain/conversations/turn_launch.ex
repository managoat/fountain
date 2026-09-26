defmodule Fountain.Conversations.TurnLaunch do
  @moduledoc """
  Launch a fresh command for a turn the actor has already admitted.

  Extracted from `ConversationServer.run_fresh_turn/6`: the actor is
  the largest module in the system and its line count only ratchets down
  (`conversation_server_size_test.exs`), so the bounded-turn lifecycle #1749
  adds has to buy its room from somewhere. This is the natural seam — a pure
  launch, given a state it does not own and returning it.

  `fail_before_start` is the actor's own pre-start failure path, passed in
  rather than duplicated: it logs the failure and retires any bounded
  execution, both of which are the actor's business.

  Nothing here is bounded-turn specific. `run_turn/6` decides whether a turn is
  bounded and which transport it gets; by the time this runs that is settled.

  `relaunch_crashed/3` and `relaunch_contended/3` are the exceptions, and say
  why at their definitions: an unbounded adapter that a native crash killed
  before it wrote a byte is launched once more under the same turn (#2402),
  and one whose Codex could not open its SQLite state is launched again after
  a pause (#1910).
  """
  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.Conversations
  alias Fountain.Conversations.{CodexChatGPT, Connection, ExecutionLimits}
  alias Fountain.Conversations.{McpServers, Output, TurnMachine}

  def run(state, conv, turn, prompt, agent, images, fail_before_start) do
    case TurnMachine.session_plan(turn, state.runtime_session_id) do
      {:ok, plan} ->
        spec = %{
          conv: conv,
          agent: agent,
          prompt: prompt,
          images: images,
          relaunched?: false,
          contended: 0
        }

        launch(state, turn, spec, fail_before_start, plan)

      {:error, _} ->
        session_plan_refused(state, turn)
    end
  end

  defp session_plan_refused(state, turn) do
    # ownership: the conversation actor supplied its already admitted turn.
    Logger.warning("conv #{state.conversation_id}: runtime session preparation refused")
    {:ok, _} = Conversations._unsafe_update_turn(turn, %{status: "failed"})
    {:ok, _} = Conversations._unsafe_idle_after_turn(turn)
    if state.turn_execution, do: Connection.close_bounded(state), else: state
  end

  # `spec` is what the launch runs, kept on the turn's metrics so a relaunch
  # (`relaunch_crashed/3`) runs the same thing.
  defp launch(state, turn, spec, fail_before_start, {mode, runtime_session_id}) do
    %{conv: conv, agent: agent, prompt: prompt, images: images, relaunched?: relaunch?} = spec
    turn_number = turn.turn_number

    {cmd, args, cwd} = TurnMachine.command(conv, agent, state.handle)

    # A relaunch continues the turn the first launch announced and timed.
    unless relaunch?, do: publish_started(state, turn, turn_number, mode)

    # Open an OTel span for the turn. We can't use Telemetry.span here
    # because the turn finishes asynchronously (in the :exit handler);
    # so we open it explicitly and store the span context in state to
    # close it later. While this span is current, build_sprite_env
    # picks up the trace context as TRACEPARENT for the runtime CLI.
    turn_span =
      if relaunch?,
        do: state.current_turn_span,
        else: TurnMachine.open_span(state.user_id, conv, turn, mode, agent)

    previous_span = OpenTelemetry.Tracer.set_current_span(turn_span)

    # Tag the detachable session with this conversation, on its own command
    # line, so a reattach after a deploy can tell it from another
    # conversation's process on the same machine (ADR 0023 gate 1).
    {cmd, args} = delayed(cmd, args, Map.get(spec, :start_delay))
    {cmd, args} = Fountain.Conversations.Identity.tag_command(state.conversation_id, cmd, args)

    # Stamped before the spawn so the duration covers the round trip to
    # sprites.dev — that latency is part of what the user waits through.
    # Kept local until the spawn succeeds: a spawn that never starts has no
    # run to time, and a stamp left in state would attach itself to the
    # next turn. A relaunch keeps the first launch's stamp: the user has
    # been waiting since then.
    turn_started_mono =
      if relaunch?,
        do: state.turn_metrics.started_mono,
        else: System.monotonic_time(:millisecond)

    # What this turn's model needs in the adapter's own env, on top of the
    # sandbox's. Recorded with the peer, so a reuse can tell it apart.
    model_env = TurnMachine.model_env(state.runtime_module, conv, agent)

    try do
      spawn_opts =
        [
          env: state.sprite_env ++ model_env,
          owner: self(),
          # The peer writes protocol requests and permission answers over
          # this channel throughout the adapter's lifetime.
          stdin: true,
          tty: false,
          dir: cwd,
          # Detachable: the sprite-side session survives a WebSocket
          # disconnect, so a BEAM restart can list_sessions + reattach.
          detachable: true
        ]

      # A bounded turn goes through the supervised transport, which records
      # spawn intent before any I/O and keeps stdin closed until the provider
      # names its session (ADR 0046). Unbounded turns spawn directly.
      spawn_result =
        if state.turn_execution do
          # ownership: admission registered this actor's turn against its
          # persisted tenant and sandbox.
          Connection._unsafe_spawn_bounded(state, conv.runtime, cmd, args, spawn_opts)
        else
          with {:ok, command} <-
                 Connection.spawn_command(state, conv.runtime, cmd, args, spawn_opts),
               do: {:ok, command, nil}
        end

      case spawn_result do
        {:ok, command, transport} ->
          stream_tracer = Managoat.ACP.Tracer.new(turn_span, prefix: "fountain")

          {peer, peer_mon} =
            TurnMachine.start_acp_peer(command, prompt, mode, runtime_session_id,
              cwd: cwd,
              images: images,
              mcp_servers:
                McpServers.for_session(agent, conv,
                  user_id: state.user_id,
                  conversation_id: state.conversation_id,
                  callback_token: state.callback_token,
                  resolved: state.resolved_mcp_servers
                ),
              additional_directories: repository_directories(state),
              model: TurnMachine.acp_model(conv, agent),
              permission_policy: TurnMachine.effective_permission_policy(conv, agent),
              auth: CodexChatGPT.peer_auth(state.runtime_module, state.inference_credentials),
              execution_transport: transport,
              execution_limits: bounded_sdk_limits(state, conv.runtime)
            )

          %{
            state
            | current_command: command,
              execution_transport: transport,
              current_command_ref: command.ref,
              current_turn: turn,
              runtime_session_id: runtime_session_id,
              current_turn_span: turn_span,
              turn_metrics:
                conv.runtime
                |> TurnMachine.start_metrics(state.handle.provider, turn_started_mono)
                |> Map.put(:launch, Map.put(spec, :plan, {mode, runtime_session_id})),
              stream_tracer: stream_tracer,
              acp_peer: peer,
              acp_peer_mon: peer_mon,
              acp_model_env: model_env
          }

        {:error, reason} ->
          fail_before_start.(state, turn, reason)
      end
    after
      # The successful path keeps the span open until :exit; the error
      # path above closes it explicitly. In both cases we restore the
      # caller's previous current-span here.
      OpenTelemetry.Tracer.set_current_span(previous_span)
    end
  end

  defp publish_started(state, turn, turn_number, mode) do
    Output.publish_stage(
      state.conversation_id,
      "turn",
      "started",
      Conversations.Turn.correlate(turn, %{
        turn_id: turn.id,
        turn_number: turn_number,
        mode: Atom.to_string(mode)
      })
    )
  end

  # Exit statuses Sprites reports for a process a native crash killed:
  # 128 + the signal (#2402). SIGKILL and SIGTERM are not here: something
  # outside the process sent those, and it would send them again.
  @native_crashes %{
    132 => "SIGILL",
    133 => "SIGTRAP",
    134 => "SIGABRT",
    135 => "SIGBUS",
    136 => "SIGFPE",
    139 => "SIGSEGV"
  }

  @doc """
  Launch an unbounded turn's adapter once more after a native crash killed it
  before it wrote a byte (#2402).

  Node 24 on Sprites guests has been seen to die of SIGSEGV during startup
  under concurrent launches, and one of six concurrent Claude turns failed
  that way in production. Such a turn failed with nothing sent to the model.

  Retrying is safe only because of what the conditions prove. The command
  wrote nothing to stdout, and its stdout and its exit reach this actor from
  the same command process, in order. So the adapter never answered
  `initialize`, the peer never sent `session/new`, and no `session/prompt`
  existed to be answered twice. The launch must also be this turn's own
  fresh launch (`:launch` is set only here): an idle peer carried across
  turns may already have been prompted. Only the first launch retries, so a
  crash that recurs fails the turn as it always did.

  A bounded turn's command belongs to its execution journal and deadline, and
  is not relaunched here. Neither is a turn whose conversation has moved to
  another sandbox since this actor launched it, including while its peer was
  stopping: the plan write carries the actor's binding and refuses.

  `finish` is the server's exit path, `(state, code) -> {:noreply, state}`.
  Every exit goes through here; the ones that do not qualify, and any retry
  that is refused or cannot start, end through `finish` exactly as an exit
  always did.
  """
  def relaunch_crashed(
        %{
          turn_execution: nil,
          current_turn: %{} = turn,
          turn_metrics: %{first_output?: false, launch: %{relaunched?: false} = launch}
        } = state,
        code,
        finish
      )
      when is_map_key(@native_crashes, code) do
    # Stop the dead command's peer before the fence, as the exit path does:
    # the stop waits, and a check made before it would be stale after it.
    Connection.stop_peer(Connection.from_state(state))
    state = %{state | acp_peer: nil, acp_peer_mon: nil}
    {mode, id} = launch.plan

    # An unbounded turn has no journal naming its sandbox, so the plan write
    # carrying this actor's binding is the only check that Wake has not moved
    # the conversation to a replacement. Nothing is announced or spawned
    # before it passes. On any refusal the exit ends the turn as it always
    # did: `finish` is the server's exit path, whose `Machine.end_turn/3`
    # applies the same binding.
    case TurnMachine.session_plan(turn, mode, id, state.sandbox_id) do
      {:ok, plan} ->
        spec = %{Map.delete(launch, :plan) | relaunched?: true}
        relaunch(state, turn, spec, plan, code, finish)

      {:error, reason} ->
        Logger.info(
          "conv #{state.conversation_id}: adapter crashed before any output; " <>
            "not relaunched (#{inspect(reason)})"
        )

        finish.(state, code)
    end
  end

  def relaunch_crashed(state, code, finish), do: finish.(state, code)

  @doc """
  The exit a `turn`/`done` stage reports: the code, and for a native crash the
  signal it stands for (#2402). A bare 139 reads as the runtime's own error;
  `SIGSEGV` says the process died, which is what the reader needs to know.
  """
  @spec exit_meta(integer()) :: %{
          required(:exit_code) => integer(),
          optional(:signal) => String.t()
        }
  def exit_meta(code) do
    case @native_crashes do
      %{^code => signal} -> %{exit_code: code, signal: signal}
      _ -> %{exit_code: code}
    end
  end

  defp relaunch(state, turn, spec, plan, code, finish) do
    signal = Map.fetch!(@native_crashes, code)

    Logger.warning(
      "conv #{state.conversation_id}: adapter died on #{signal} before any output; " <>
        "launching it once more (#2402)"
    )

    Output.publish_stage(state.conversation_id, "session", "done", %{
      event: "restarted",
      reason: "adapter_crashed",
      detail: signal,
      turn_id: turn.id,
      message:
        "The agent's runtime crashed while starting (#{signal}), before your prompt " <>
          "was sent. It is being started again."
    })

    TurnMachine.stamp_span(state.current_turn_span, %{"acp.adapter_relaunched" => signal})

    # A relaunch that cannot start ends the turn as the crash would have:
    # through the exit path, with the crash's code, the first launch's
    # measurements and its completion metric. The turn already ran, so the
    # never-started path's silence would drop it from the failure rate.
    cannot_start = fn state, _turn, reason ->
      Logger.warning(
        "conv #{state.conversation_id}: adapter relaunch did not start: #{inspect(reason)}"
      )

      {:noreply, state} = finish.(state, code)
      state
    end

    state = %{state | current_command: nil, current_command_ref: nil}
    {:noreply, launch(state, turn, spec, cannot_start, plan)}
  end

  # The error Codex's app-server exits with, on `initialize`, when it cannot
  # open its SQLite state (#1910). In production that was `database is locked`
  # (SQLITE_BUSY): the app-server waits five seconds for the lock at startup,
  # and a `CODEX_HOME` shared by every Codex conversation on the machine (or on
  # one ChatGPT sign-in) can keep it busier than that during a burst of turns.
  @state_runtime_failed "failed to initialize sqlite state runtime"

  # Seconds each relaunch waits, before jitter of up to as much again. The
  # production bursts on #1910 each lasted about a minute; the waits, plus a
  # launch each, cover about that before the turn fails as it always did.
  @contended_waits [2, 6, 15]

  @doc """
  Launch an unbounded turn's adapter again, after a pause, when Codex could
  not open its SQLite state (#1910).

  Codex keeps its state in SQLite under its home, which every Codex
  conversation on the machine shares, or every one on the same ChatGPT
  sign-in. A new app-server writes there before it answers `initialize`, and
  gives up after five seconds of other processes holding the lock. The error
  names no cause (Codex drops it); the evidence on #1910 is the processes
  beside it logging `database is locked` in the same minutes. The fix is state
  per conversation, which #1910 tracks. Until then a burst of turns passes in
  about a minute, so the turn is launched again rather than failed.

  It is safe for the reason #2402's relaunch is: the failure is the reply to
  `initialize`, which the peer sends before anything else, so no session was
  opened and no prompt was sent. The adapter is still running and is closed
  first. The launch must be this turn's own fresh launch (`:launch` is set
  only there), unbounded, and still on this actor's sandbox (the plan write
  carries the binding, as for #2402). A bounded turn's command belongs to its
  execution journal and is not relaunched.

  The pause runs inside the sandbox, as a `sleep` in front of the adapter, so
  this actor stays responsive: an interrupt stops the command as it would any
  other, and a prompt meanwhile is refused as busy. The peer's `initialize`
  waits in the adapter's stdin. At most three relaunches, then the turn fails
  with the error it has now.

  `drive` is the server's path for a peer report, `(state, payload) -> state`.
  Every report goes through here; the ones that do not qualify, a refused
  plan, and a relaunch that cannot start, all end through `drive` exactly as
  the report always did.
  """
  def relaunch_contended(
        %{
          turn_execution: nil,
          current_turn: %{} = turn,
          turn_metrics: %{launch: %{contended: attempt} = launch}
        } = state,
        {:failed, {:acp_error, :initialize, %{} = error}} = payload,
        drive
      )
      when attempt < length(@contended_waits) do
    if state_runtime_failed?(error) do
      {mode, id} = launch.plan

      case TurnMachine.session_plan(turn, mode, id, state.sandbox_id) do
        {:ok, plan} ->
          relaunch_after_contention(state, turn, launch, plan, payload, drive)

        {:error, reason} ->
          Logger.info(
            "conv #{state.conversation_id}: codex state was locked; " <>
              "not relaunched (#{inspect(reason)})"
          )

          drive.(state, payload)
      end
    else
      drive.(state, payload)
    end
  end

  def relaunch_contended(state, payload, drive), do: drive.(state, payload)

  # codex-acp 1.10.0 puts Codex's stderr in the message; `data.details` is
  # where an adapter's detail goes otherwise, so either counts.
  defp state_runtime_failed?(error) do
    details = with %{"details" => details} <- error["data"], do: details

    [error["message"], details]
    |> Enum.any?(&(is_binary(&1) and String.contains?(&1, @state_runtime_failed)))
  end

  defp relaunch_after_contention(state, turn, launch, plan, payload, drive) do
    attempt = launch.contended + 1
    wait = Enum.at(@contended_waits, launch.contended)
    wait = wait + :rand.uniform(wait + 1) - 1

    Logger.warning(
      "conv #{state.conversation_id}: codex could not open its sqlite state; " <>
        "launching it again in #{wait}s (attempt #{attempt}, #1910)"
    )

    Output.publish_stage(state.conversation_id, "session", "done", %{
      event: "restarted",
      reason: "runtime_state_locked",
      attempt: attempt,
      turn_id: turn.id,
      message:
        "The agent's runtime could not open its local state, which other " <>
          "conversations on this machine are using, before your prompt was sent. " <>
          "It is being started again in #{wait} seconds."
    })

    TurnMachine.stamp_span(state.current_turn_span, %{"acp.state_locked_relaunches" => attempt})

    state =
      Connection.into_state(
        state,
        Connection.close(Connection.from_state(state), state.conversation_id, state.handle)
      )

    # A relaunch that cannot start ends the turn as the report would have.
    cannot_start = fn state, _turn, reason ->
      Logger.warning(
        "conv #{state.conversation_id}: adapter relaunch did not start: #{inspect(reason)}"
      )

      drive.(state, payload)
    end

    spec = %{Map.delete(launch, :plan) | relaunched?: true, contended: attempt}
    launch(state, turn, Map.put(spec, :start_delay, wait), cannot_start, plan)
  end

  # The pause in front of a relaunched adapter, as positional arguments to a
  # fixed script: `exec` keeps the process the provider named its session for.
  defp delayed(cmd, args, nil), do: {cmd, args}

  defp delayed(cmd, args, seconds) when is_integer(seconds) and seconds > 0,
    do:
      {"sh",
       ["-c", ~S(sleep "$1"; shift; exec "$@"), "fountain-relaunch", "#{seconds}", cmd | args]}

  # The environment's clones, which codex adds to its sandbox's writable roots
  # (#1684): without them a clone outside its cwd is read-only, and a worktree
  # cut from it fails. Each clone's `.git` goes too, as a root of its own:
  # codex keeps `.git` read-only inside every writable root, so a branch or a
  # commit still failed with the clone alone. A path that does not exist is
  # ignored by codex. Read the way `Egress.refresh_before_turn/1` reads it,
  # tenant-scoped on the provisioned environment; a row that is gone gives
  # nothing. Mapped like `cwd`, since the adapter checks them in band.
  defp repository_directories(%{secret_sources: %{environment_id: env_id}} = state)
       when is_binary(env_id) do
    env_id
    |> Fountain.Environments.get_environment(state.user_id)
    |> Fountain.Environments.Environment.repository_mounts()
    |> Enum.flat_map(&[&1, Path.join(&1, ".git")])
    |> Enum.map(&Managoat.Sandbox.host_path(state.handle, &1))
  end

  defp repository_directories(_state), do: []

  # The SDK's own view of the allowance, from the frozen journal copy rather
  # than from current policy: an in-flight turn keeps what it was admitted
  # under. Nil for an unbounded turn, which asks the SDK for nothing.
  defp bounded_sdk_limits(%{turn_execution: nil}, _runtime), do: nil

  # The hard match is safe at a distance, which is worth saying rather than
  # leaving to be rediscovered: admission already called
  # `Managoat.Runtimes.ACP.execution_limits/2` for this runtime and allowance
  # inside `_unsafe_register_bounded/3`, through a `with` that rolls the turn
  # back on `{:error, _}`. A journal row therefore cannot exist for a runtime
  # that refuses its own limits, so reaching here with one is a bug in
  # admission and crashing is the right answer to it.
  defp bounded_sdk_limits(state, runtime) do
    options = ExecutionLimits.sdk_options(state.turn_execution.execution_limits)
    {:ok, limits} = Managoat.Runtimes.ACP.execution_limits(runtime, options)
    limits
  end
end
