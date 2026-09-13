defmodule Fountain.Conversations.ReattachmentFailureTest do
  use Fountain.DataCase, async: false

  alias Fountain.Conversations
  alias Fountain.Conversations.{Reattachment, TurnMachine}

  defmodule Peer do
    use GenServer
    def start_link(on_stop), do: GenServer.start_link(__MODULE__, on_stop)
    def init(on_stop), do: {:ok, on_stop}
    def terminate(:normal, on_stop), do: on_stop.()
    def terminate(_reason, _on_stop), do: :ok
  end

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, status: "running")
    turn = insert_turn(conv, status: "running")
    owner = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:fountain, :turn, :completed],
      fn event, _, meta, _ ->
        if meta.conv_id == conv.id, do: send(owner, {event, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{user: user, conv: conv, turn: turn}
  end

  test "stops the local peer before committing failure and preserves its stage and metric", ctx do
    owner = self()

    state =
      state(ctx, fn ->
        refute Repo.in_transaction?()
        send(owner, {:peer_stopped, Repo.reload!(ctx.turn).status})
      end)

    assert {:noreply, cleared} = Reattachment.fail_transport(state, :closed)
    assert_received {:peer_stopped, "running"}
    refute Process.alive?(state.acp_peer)
    assert Repo.reload!(ctx.turn).status == "failed"
    assert Repo.reload!(ctx.conv).status == "idle"
    assert [event] = stages(ctx)
    assert event.state == "failed"
    assert Jason.decode!(event.data)["reason"] == "sprite connection lost: :closed"
    assert_receive {[:fountain, :turn, :completed], %{status: "failed"}}
    assert_cleared(cleared)
  end

  for change <- [:reassigned, :completed, :terminated, :deleted] do
    @tag during_stop: change
    test "#{change} during peer shutdown preserves the persisted result", ctx do
      replacement = insert_sandbox(user_id: ctx.user.id)

      state =
        state(ctx, fn ->
          case ctx.during_stop do
            :reassigned ->
              Conversations.update_conversation(ctx.conv, %{sandbox_id: replacement.id})

            :completed ->
              ctx.turn |> Ecto.Changeset.change(status: "completed") |> Repo.update!()
              insert_turn(ctx.conv, status: "running")

            :terminated ->
              Conversations.update_conversation(ctx.conv, %{status: "terminated"})

            :deleted ->
              Repo.delete!(ctx.conv)
          end
        end)

      assert {:noreply, cleared} = Reattachment.fail_transport(state, :closed)
      refute Process.alive?(state.acp_peer)
      assert_cleared(cleared)
      assert stages(ctx) == []
      refute_receive {[:fountain, :turn, :completed], _}, 50

      case ctx.during_stop do
        :deleted ->
          assert Repo.reload(ctx.conv) == nil
          assert Repo.reload(ctx.turn) == nil

        :terminated ->
          assert Repo.reload!(ctx.conv).status == "terminated"
          assert Repo.reload!(ctx.turn).status == "running"

        :completed ->
          assert Repo.reload!(ctx.conv).status == "running"
          assert Repo.reload!(ctx.turn).status == "completed"

        :reassigned ->
          assert Repo.reload!(ctx.conv).sandbox_id == replacement.id
          assert Repo.reload!(ctx.conv).status == "running"
          assert Repo.reload!(ctx.turn).status == "running"
      end
    end
  end

  defp state(ctx, on_stop) do
    peer = start_supervised!(Supervisor.child_spec({Peer, on_stop}, restart: :temporary))
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), peer)

    %{
      conversation_id: ctx.conv.id,
      sandbox_id: ctx.conv.sandbox_id,
      current_turn: ctx.turn,
      current_turn_span: nil,
      turn_metrics:
        TurnMachine.start_metrics("claude", :runner, System.monotonic_time(:millisecond)),
      stream_tracer: nil,
      turn_session_retry: nil,
      replay_dedup: MapSet.new(),
      current_command: :closed_transport,
      current_command_ref: make_ref(),
      autonomous_quiet: nil,
      acp_peer: peer,
      acp_peer_mon: Process.monitor(peer),
      runner_reconnect: nil,
      runner_replay: %{},
      last_activity_at: DateTime.utc_now()
    }
  end

  defp assert_cleared(state) do
    for field <- [
          :current_turn,
          :current_turn_span,
          :turn_metrics,
          :stream_tracer,
          :current_command,
          :current_command_ref,
          :acp_peer,
          :acp_peer_mon,
          :runner_reconnect,
          :runner_replay
        ] do
      assert state[field] == nil
    end
  end

  defp stages(ctx) do
    Repo.all(
      from e in Conversations.LogEvent,
        where: e.conversation_id == ^ctx.conv.id and e.stage == "turn"
    )
  end
end
