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
  """
  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.Conversations
  alias Fountain.Conversations.{CodexChatGPT, Connection, ExecutionLimits}
  alias Fountain.Conversations.{McpServers, Output, TurnMachine}

  def run(state, conv, turn, prompt, agent, images, fail_before_start) do
    case TurnMachine.session_plan(turn, state.runtime_session_id) do
      {:ok, plan} ->
        launch(state, conv, turn, prompt, agent, images, fail_before_start, plan)

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

  defp launch(
         state,
         conv,
         turn,
         prompt,
         agent,
         images,
         fail_before_start,
         {mode, runtime_session_id}
       ) do
    turn_number = turn.turn_number

    {cmd, args, cwd} = TurnMachine.command(conv, agent, state.handle)

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

    # Open an OTel span for the turn. We can't use Telemetry.span here
    # because the turn finishes asynchronously (in the :exit handler);
    # so we open it explicitly and store the span context in state to
    # close it later. While this span is current, build_sprite_env
    # picks up the trace context as TRACEPARENT for the runtime CLI.
    turn_span = TurnMachine.open_span(state.user_id, conv, turn, mode, agent)
    previous_span = OpenTelemetry.Tracer.set_current_span(turn_span)

    # Tag the detachable session with this conversation, on its own command
    # line, so a reattach after a deploy can tell it from another
    # conversation's process on the same machine (ADR 0023 gate 1).
    {cmd, args} = Fountain.Conversations.Identity.tag_command(state.conversation_id, cmd, args)

    # Stamped before the spawn so the duration covers the round trip to
    # sprites.dev — that latency is part of what the user waits through.
    # Kept local until the spawn succeeds: a spawn that never starts has no
    # run to time, and a stamp left in state would attach itself to the
    # next turn.
    turn_started_mono = System.monotonic_time(:millisecond)

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
                TurnMachine.start_metrics(conv.runtime, state.handle.provider, turn_started_mono),
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
