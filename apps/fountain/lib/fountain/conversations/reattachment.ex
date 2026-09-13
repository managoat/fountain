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

  # If a turn is marked `running` in the DB and the sprite has an active
  # detachable session, reattach to it: the WebSocket reconnects, stdout
  # continues streaming where it left off, and the eventual `:exit` message
  # closes the turn cleanly. If no active session is found, the command
  # finished while the BEAM was down — we don't know the exit code, so
  # mark the orphaned turn `interrupted` so the user gets a clear signal.
  def reattach_running_turn(state) do
    running_turn = find_running_turn(state.conversation_id)

    if is_nil(running_turn) do
      # No turn was in flight, but a deploy also killed the idle peer that
      # outlives a turn (#817), leaving its detachable adapter session running
      # with nothing to drive it. Reap it — by this conversation's tag, never
      # the head of the list: a co-tenant's live turn on the same machine must
      # not be touched (ADR 0023, #1058).
      reap_orphan_sessions(state)
    else
      case Managoat.Sandbox.Retry.with_backoff(
             fn -> Managoat.Sandbox.list_sessions(state.handle) end,
             label: "session list on reattach"
           ) do
        {:ok, sessions} ->
          # Don't filter by `is_active`: a detached session reports
          # `is_active: false` while no client is connected, but the
          # underlying exec is alive and `attach_session` resumes its
          # stream (replaying the session buffer + live-tailing).
          #
          # Match on the conversation tag, never the head of the list: with
          # several conversations on one machine, the head is as likely to be
          # someone else's process as ours (`Fountain.Conversations.Identity`).
          case Fountain.Conversations.Identity.reattach_session(
                 state.handle,
                 sessions,
                 state.conversation_id
               ) do
            :none ->
              mark_orphan(state, running_turn, "no_active_session")
              state

            {:ok, session, matched_by} ->
              attempt_session_attach(state, running_turn, session, matched_by)
          end

        {:error, reason} ->
          Logger.warning("list_sessions failed during reattach: #{inspect(reason)}")
          mark_orphan(state, running_turn, "list_sessions_failed")
          state
      end
    end
  end

  # After a restart with no turn in flight, stop this conversation's own
  # leftover adapter sessions (#817). Matched by tag; a session tagged for
  # another conversation, or untagged, is left alone.
  defp reap_orphan_sessions(state) do
    case Managoat.Sandbox.list_sessions(state.handle) do
      {:ok, sessions} ->
        mine =
          Fountain.Conversations.Identity.owned_sessions(
            state.handle,
            sessions,
            state.conversation_id
          )

        Enum.each(mine, &Connection.reap_session(state.handle, &1.id))

        outcome = if mine == [], do: "no_running_turn", else: "orphan_session_reaped"

        Output.publish_stage(state.conversation_id, "reattach", "done", %{
          outcome: outcome,
          reaped: length(mine)
        })

        state

      {:error, _reason} ->
        Output.publish_stage(state.conversation_id, "reattach", "done", %{
          outcome: "no_running_turn"
        })

        state
    end
  end

  defp attempt_session_attach(state, running_turn, session, matched_by) do
    # ownership: the server's bound conversation and the running turn
    # `find_running_turn/1` read for it; no id here came from a request.
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    acp? = Fountain.RuntimeDispatch.acp_enabled?(conv.runtime)

    case Managoat.Sandbox.attach(state.handle, session.id, owner: self(), stdin: true) do
      {:ok, idle_command} when acp? and is_nil(running_turn.acp_prompt_id) ->
        # The previous peer died before it wrote `session/prompt` (or the turn
        # predates the column). The adapter is sitting idle in its handshake
        # with nothing to answer, and no peer can pick that up: the ids it
        # would need are gone with the process. Stop it — otherwise it lingers
        # as a session the next reattach could bind to — and orphan the turn.
        Managoat.Sandbox.stop_command(idle_command)
        mark_orphan(state, running_turn, "acp_prompt_not_sent")
        state

      {:ok, command} ->
        # sprites replays the tail of the session's buffered output before
        # live-tailing. On the legacy path, count the bytes we already
        # persisted for this turn so the stdout/stderr handlers can drop the
        # replayed prefix. On the ACP path the peer re-encodes protocol lines
        # so byte counts do not line up; the replayed lines are matched by
        # content instead (`replay_dedup`).
        # ownership: as above — the bound conversation and its own running turn.
        replay_skip =
          if acp?,
            do: %{},
            else:
              Conversations._unsafe_output_bytes_by_stream(
                state.conversation_id,
                running_turn.id
              )

        Output.publish_stage(state.conversation_id, "reattach", "done", %{
          outcome: "session_attached",
          matched_by: matched_by,
          session_id: session.id,
          turn_id: running_turn.id,
          turn_number: running_turn.turn_number,
          replay_skip_bytes: replay_skip,
          acp_prompt_id: running_turn.acp_prompt_id
        })

        {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

        # turn_metrics stays nil on purpose, so this turn contributes no
        # duration sample (#536). Its start is in a previous BEAM lifetime:
        # monotonic time isn't comparable across a restart, and measuring
        # from the row's started_at would fold the whole deploy gap into the
        # histogram. A missing sample beats a wrong one.
        state = %{
          state
          | current_command: command,
            current_command_ref: command.ref,
            current_turn: running_turn,
            replay_skip: replay_skip
        }

        if acp?, do: acp_peer(state, running_turn, conv), else: state

      {:error, reason} ->
        Logger.warning("attach_session failed: #{inspect(reason)}")
        mark_orphan(state, running_turn, "attach_failed")
        state
    end
  end

  # ownership: `running_turn` came from `find_running_turn/1`, scoped to the
  # conversation this server owns.
  defp mark_orphan(_state, running_turn, why),
    do: Conversations._unsafe_orphan_turn(running_turn, why)

  def find_running_turn(conv_id) do
    import Ecto.Query

    Fountain.Repo.one(
      from t in Fountain.Conversations.Turn,
        where: t.conversation_id == ^conv_id and t.status == "running",
        order_by: [desc: t.turn_number],
        limit: 1
    )
  end
end
