defmodule Fountain.Conversations.Reattachment do
  @moduledoc "ACP peer restoration and bounded recovery of an accepted runner turn."

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{Connection, Output, Pending, TurnMachine}

  @replay_dedup_ttl_ms 10_000

  # An ACP turn is only alive while something answers the agent: a
  # `session/request_permission` left unanswered blocks it forever, and the
  # `session/prompt` response is the only thing that ends it — the adapter
  # keeps running until stdin closes. Before this, a reattached ACP turn had
  # its stdout logged raw and no peer, so every turn in flight across a deploy
  # hung until the user prompted again (which interrupts it) or the sandbox
  # hit its lifetime ceiling.
  #
  # No tracer: the turn span belongs to a previous BEAM lifetime.
  def acp_peer(state, running_turn, conv) do
    {:ok, peer} =
      Managoat.ACP.Peer.start(
        owner: self(),
        # The transport seam (Managoat.ACP.Transport): the peer writes through
        # this function and never sees the sandbox. `write_stdin/2` is total —
        # a runtime that has already exited answers {:error, :command_exited},
        # which the peer reports as {:failed, {:acp_write_failed, _}}.
        writer: fn iodata -> Managoat.Sandbox.write_stdin(state.current_command, iodata) end,
        ref: state.current_command_ref,
        prompt: running_turn.prompt,
        mode: :continue,
        session_id: conv.runtime_session_id,
        attach: running_turn.acp_prompt_id,
        # A reattached peer answers `session/request_permission` exactly like a
        # fresh one — the adapter in the sprite is mid-turn and still asking.
        # Resolving from the agent here (rather than reading a policy frozen on
        # the conversation row) is what makes a tightening apply across a
        # deploy.
        permission_policy:
          TurnMachine.effective_permission_policy(conv, TurnMachine.agent_for(conv)),
        auth:
          Fountain.Conversations.CodexChatGPT.peer_auth(
            state.runtime_module,
            state.inference_credentials
          ),
        # Hand back the request the previous peer was holding, if any (#940).
        # The agent minted the JSON-RPC id and is still blocked on it, so the
        # id outlives our process — but only if we wrote it down. This is the
        # same trap `acp_prompt_id` exists for, and the reason the turn row
        # carries `pending_permission` at all.
        pending_permission: running_turn.pending_permission
      )

    # ownership: ConversationServer passes its bound conversation and that
    # conversation's persisted running turn; neither ID comes from a request here.
    dedup =
      Conversations._unsafe_recent_output_lines(state.conversation_id, running_turn.id, "acp")

    Process.send_after(self(), :clear_replay_dedup, @replay_dedup_ttl_ms)

    runner_replay =
      if state.handle.provider == :runner do
        Process.send_after(
          self(),
          {:runner_replay_timeout, state.current_command_ref},
          @replay_dedup_ttl_ms
        )

        Fountain.Conversations.RunnerReplay.new(running_turn.acp_prompt_id)
      end

    state =
      Pending.into_state(
        state,
        Pending.restore_permission_timer(Pending.from_state(state), running_turn)
      )

    %{
      state
      | acp_peer: peer,
        acp_peer_mon: Process.monitor(peer),
        runner_replay: runner_replay,
        stream_tracer: nil,
        replay_dedup: dedup
    }
  end

  @runner_reconnect_ms 120_000
  def wait_for_runner(state, on_expired) do
    recovery =
      state.runner_reconnect ||
        %{deadline: System.monotonic_time(:millisecond) + @runner_reconnect_ms, token: make_ref()}

    if is_nil(state.runner_reconnect) do
      Output.publish_stage(state.conversation_id, "connection", "started", %{
        reason: "runner_disconnected",
        turn_id: state.current_turn.id,
        timeout_ms: @runner_reconnect_ms
      })
    end

    state = %{state | runner_reconnect: recovery}

    if runner_reconnect_expired?(state) do
      on_expired.(state, :runner_reconnect_timeout)
    else
      Process.send_after(self(), {:runner_reconnect, recovery.token}, 1_000)
      {:noreply, state}
    end
  end

  def runner_reconnect_expired?(state),
    do: System.monotonic_time(:millisecond) >= state.runner_reconnect.deadline

  def finish_runner_reconnect(%{runner_reconnect: nil} = state, _outcome), do: state

  def finish_runner_reconnect(state, outcome) do
    Output.publish_stage(state.conversation_id, "connection", "done", %{
      reason: "runner_reconnect",
      outcome: outcome
    })

    %{state | runner_reconnect: nil}
  end

  def fail_transport(state, reason) do
    Logger.error("sprite command error mid-turn: #{inspect(reason)} — failing the turn")
    state = finish_runner_reconnect(state, "failed")

    # Stop the failed connection's local peer before committing the turn result.
    # Completion rechecks the actor's binding after this callback can yield.
    Connection.stop_peer(Connection.from_state(state))

    turn =
      TurnMachine.finish(
        TurnMachine.from_state(state),
        "failed",
        %{"error" => inspect(reason)},
        %{reason: "sprite connection lost: #{inspect(reason)}"}
      )

    state = TurnMachine.into_state(state, turn)

    {:noreply,
     %{
       %{state | last_activity_at: DateTime.utc_now()}
       | current_command: nil,
         current_command_ref: nil,
         runner_reconnect: nil,
         runner_replay: nil,
         acp_peer: nil,
         acp_peer_mon: nil
     }}
  end

  def disconnect_runner(state) do
    # Do not cancel the remote command: only the socket disappeared. The
    # daemon journals output until a new connection attaches to this turn.
    Connection.stop_peer(Connection.from_state(state))
    TurnMachine.finalize_tracer(state.stream_tracer)

    %{
      state
      | current_command: nil,
        current_command_ref: nil,
        acp_peer: nil,
        acp_peer_mon: nil,
        stream_tracer: nil,
        runner_replay: nil
    }
  end
end
