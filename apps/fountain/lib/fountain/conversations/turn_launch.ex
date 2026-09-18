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

  `relaunch_crashed/3` is the one exception, and says why at its definition: an
  unbounded adapter that a native crash killed before it wrote a byte is
  launched once more under the same turn (#2402).
  """
  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.Conversations
  alias Fountain.Conversations.{CodexChatGPT, Connection, ExecutionLimits}
  alias Fountain.Conversations.{McpServers, Output, TurnMachine}

  def run(state, conv, turn, prompt, agent, images, fail_before_start) do
    case TurnMachine.session_plan(turn, state.runtime_session_id) do
      {:ok, plan} ->
        spec = %{conv: conv, agent: agent, prompt: prompt, images: images, relaunched?: false}
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

    try do
      spawn_opts =
        [
          env: state.sprite_env,
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
              acp_peer_mon: peer_mon
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
  is not relaunched here.

  Returns `{:relaunched, state}`, or `{:finish, state}` for the caller to end
  the turn with the exit code.
  """
  def relaunch_crashed(
        %{
          turn_execution: nil,
          current_turn: %{} = turn,
          turn_metrics: %{first_output?: false, launch: %{relaunched?: false} = launch}
        } = state,
        code,
        fail_before_start
      )
      when is_map_key(@native_crashes, code) do
    signal = Map.fetch!(@native_crashes, code)

    Logger.warning(
      "conv #{state.conversation_id}: adapter died on #{signal} before any output; " <>
        "launching it once more (#2402)"
    )

    Connection.stop_peer(Connection.from_state(state))

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

    state = %{
      state
      | current_command: nil,
        current_command_ref: nil,
        acp_peer: nil,
        acp_peer_mon: nil
    }

    {mode, id} = launch.plan

    state =
      case TurnMachine.session_plan(turn, mode, id) do
        {:ok, plan} ->
          spec = %{Map.delete(launch, :plan) | relaunched?: true}
          launch(state, turn, spec, fail_before_start, plan)

        # Fenced since the first launch. Unlike a first launch's refusal, the
        # turn was announced, so it ends through the failure path that
        # publishes its terminal stage and closes its span.
        {:error, reason} ->
          previous_span = OpenTelemetry.Tracer.set_current_span(state.current_turn_span)
          state = fail_before_start.(state, turn, {:relaunch_refused, reason})
          OpenTelemetry.Tracer.set_current_span(previous_span)
          state
      end

    # A relaunch that did not start ended the turn on its own failure path,
    # which leaves the first launch's measurements behind.
    if state.current_command_ref,
      do: {:relaunched, state},
      else:
        {:relaunched,
         %{
           state
           | current_turn: nil,
             current_turn_span: nil,
             turn_metrics: nil,
             stream_tracer: nil
         }}
  end

  def relaunch_crashed(state, _code, _fail_before_start), do: {:finish, state}

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
