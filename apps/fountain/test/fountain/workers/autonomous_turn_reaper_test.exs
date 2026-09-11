defmodule Fountain.Workers.AutonomousTurnReaperTest do
  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Repo
  alias Fountain.Workers.AutonomousTurnReaper

  setup :set_mimic_global

  defp minutes_ago(minutes) do
    DateTime.utc_now()
    |> DateTime.add(-minutes * 60, :second)
    |> DateTime.truncate(:second)
  end

  defp running_turn(minutes \\ 45, overrides \\ %{}) do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")

    turn =
      insert_turn(
        conv,
        Map.merge(
          %{status: "running", origin: "autonomous", started_at: minutes_ago(minutes)},
          overrides
        )
      )

    {user, conv, turn}
  end

  defp no_live_servers do
    stub(Fountain.Conversations.ConversationServer, :whereis, fn _ -> nil end)
  end

  test "reaps an old silent turn with no live server" do
    {user, conv, turn} = running_turn()
    no_live_servers()

    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")

    capture_log(fn -> assert 1 = AutonomousTurnReaper.sweep_stuck_turns() end)

    reloaded = Repo.reload(turn)
    assert reloaded.status == "interrupted"
    assert %DateTime{} = reloaded.ended_at
    assert %DateTime{} = reloaded.orphaned_at
    assert Repo.reload(conv).status == "idle"

    assert_receive {:log_event, %{stage: "reattach", state: "interrupted"} = event}
    assert Jason.decode!(event.data)["reason"] == "stuck_running_no_server"

    assert Enum.any?(Audit.list_recent_for_user(user.id), fn event ->
             event.action == "conversation.turn.orphaned" and
               event.actor == "system:autonomous_turn_reaper" and
               event.resource_id == turn.id
           end)
  end

  test "leaves a turn with a live server alone" do
    {_user, conv, turn} = running_turn(120)

    stub(Fountain.Conversations.ConversationServer, :whereis, fn id ->
      if id == conv.id, do: self()
    end)

    assert 0 = AutonomousTurnReaper.sweep_stuck_turns()
    assert Repo.reload(turn).status == "running"
  end

  test "leaves recent and recently-active turns alone" do
    {_user, recent_conv, recent_turn} = running_turn(5)
    {_user, active_conv, active_turn} = running_turn(60)

    insert_log_event(active_conv, %{turn_id: active_turn.id, inserted_at: minutes_ago(5)})
    no_live_servers()

    assert 0 = AutonomousTurnReaper.sweep_stuck_turns()
    assert Repo.reload(recent_turn).status == "running"
    assert Repo.reload(active_turn).status == "running"
    assert Repo.reload(recent_conv).status == "running"
  end

  test "leaves a turn waiting on a person's permission alone" do
    {_user, _conv, turn} =
      running_turn(120, %{
        pending_permission: %{"request_id" => 42, "tool" => "shell", "options" => []}
      })

    no_live_servers()

    assert 0 = AutonomousTurnReaper.sweep_stuck_turns()
    assert Repo.reload(turn).status == "running"
  end

  test "does not resurrect a terminated conversation" do
    {_user, conv, turn} = running_turn()
    {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})
    no_live_servers()

    assert 1 = AutonomousTurnReaper.sweep_stuck_turns()
    assert Repo.reload(turn).status == "interrupted"
    assert Repo.reload(conv).status == "terminated"
  end

  test "a concurrent turn ending wins over orphan reconciliation" do
    {user, conv, stale_turn} = running_turn()

    {:ok, completed} =
      Conversations._unsafe_update_turn(stale_turn, %{
        status: "completed",
        ended_at: minutes_ago(1)
      })

    assert :noop = Conversations._unsafe_orphan_turn(stale_turn, "stale_candidate")
    assert Repo.reload(completed).status == "completed"
    assert Repo.reload(completed).orphaned_at == nil
    assert Repo.reload(conv).status == "running"

    refute Enum.any?(Audit.list_recent_for_user(user.id), fn event ->
             event.action == "conversation.turn.orphaned"
           end)
  end

  describe "ConversationServer.terminate/2" do
    test "a normal stop reconciles the turn its in-memory timer can no longer close" do
      {_user, conv, turn} = running_turn()

      assert :ok =
               ConversationServer.terminate(:normal, %{
                 conversation_id: conv.id,
                 sandbox_id: conv.sandbox_id,
                 callback_api_key_id: nil,
                 current_turn: turn
               })

      assert Repo.reload(turn).status == "interrupted"
      assert Repo.reload(turn).orphaned_at
      assert Repo.reload(conv).status == "idle"
    end

    test "an old actor leaves a rebound conversation and its turn untouched" do
      {user, conv, turn} = running_turn()
      replacement = insert_sandbox(user_id: user.id, status: "ready")
      {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: replacement.id})
      Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")

      assert :ok =
               ConversationServer.terminate(:normal, %{
                 conversation_id: conv.id,
                 sandbox_id: conv.sandbox_id,
                 callback_api_key_id: nil,
                 current_turn: turn
               })

      assert Repo.reload(turn) == turn
      assert Repo.reload(conv).sandbox_id == replacement.id
      assert Repo.reload(conv).status == "running"
      refute_receive {:log_event, %{stage: "reattach"}}

      refute Enum.any?(
               Audit.list_recent_for_user(user.id),
               &(&1.action == "conversation.turn.orphaned")
             )
    end

    test "a supervisor shutdown leaves the turn available for reattach" do
      {_user, conv, turn} = running_turn()

      assert :ok =
               ConversationServer.terminate(:shutdown, %{
                 conversation_id: conv.id,
                 sandbox_id: conv.sandbox_id,
                 callback_api_key_id: nil,
                 current_turn: turn
               })

      assert Repo.reload(turn).status == "running"
      assert Repo.reload(turn).orphaned_at == nil
      assert Repo.reload(conv).status == "running"
    end
  end

  test "caps each sweep at 25 and takes the oldest candidates first" do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")

    turns =
      for n <- 1..30 do
        insert_turn(conv, %{
          status: "running",
          origin: "autonomous",
          turn_number: n,
          started_at: minutes_ago(45 + n)
        })
      end

    expected = turns |> Enum.sort_by(& &1.started_at) |> Enum.take(25) |> MapSet.new(& &1.id)
    no_live_servers()

    capture_log(fn -> assert 25 = AutonomousTurnReaper.sweep_stuck_turns() end)

    reaped =
      turns
      |> Enum.map(&Repo.reload/1)
      |> Enum.filter(&(&1.status == "interrupted"))
      |> MapSet.new(& &1.id)

    assert reaped == expected
  end

  test "is scheduled every five minutes" do
    crontab =
      Application.fetch_env!(:fountain, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
        _ -> nil
      end)

    assert {"*/5 * * * *", AutonomousTurnReaper} in crontab
  end
end
