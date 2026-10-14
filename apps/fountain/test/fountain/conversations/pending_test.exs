defmodule Fountain.Conversations.PendingTest do
  @moduledoc """
  What a turn waits on (#1375), driven without a server: a permission request
  answered, denied by timeout and drained at the turn's end. The parked
  caller-tool calls this suite also covered went with the retired tool bridge
  (ADR 0057, #2252). The peer is this process, so what would reach it is
  asserted as messages; the timers land here too.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.Pending

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id)
    turn = insert_turn(conv, status: "running", started_at: DateTime.utc_now())
    {:ok, conv: conv, turn: turn, pending: %Pending{}}
  end

  defp stages(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  defp denials(conv_id) do
    Fountain.Repo.all(
      from(a in Fountain.Audit.Event,
        where: a.resource_id == ^conv_id and a.action == "conversation.permission_denied"
      )
    )
    |> Enum.map(& &1.metadata)
  end

  # A stand-in peer: a process that records the deny cast it receives.
  defp fake_peer do
    test = self()

    spawn_link(fn ->
      receive do
        {:"$gen_cast", {:deny_permission, id}} -> send(test, {:denied, id})
      end
    end)
  end

  describe "from_state/1 and into_state/2" do
    test "round-trip the server field" do
      state = %{permission_timer: :t, other: 1}
      assert %Pending{permission_timer: :t} = p = Pending.from_state(state)

      assert Pending.into_state(state, %{p | permission_timer: nil}) == %{
               state
               | permission_timer: nil
             }
    end
  end

  describe "a permission request" do
    test "restoring an old request expires it without granting a new timeout window" do
      old = DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.to_iso8601()

      pending =
        Pending.restore_permission_timer(%Pending{}, %{
          pending_permission: %{"request_id" => "old-request", "asked_at" => old}
        })

      assert is_reference(pending.permission_timer)
      # The deadline is immediate; observing its message is subject to scheduler
      # load. Pin the timer state before allowing time for delivery, so this
      # cannot hide a regression that grants a new permission window.
      assert Process.read_timer(pending.permission_timer) in [false, 0]
      assert_receive {:permission_timeout, "old-request"}, 5_000
    end

    test "restoring a current request replaces its timer without extending its original deadline" do
      asked = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.to_iso8601()
      previous = Process.send_after(self(), :old_timer, 300_000)

      pending =
        Pending.restore_permission_timer(%Pending{permission_timer: previous}, %{
          pending_permission: %{"request_id" => "held-request", "asked_at" => asked}
        })

      assert Process.read_timer(previous) == false
      remaining = Process.read_timer(pending.permission_timer)
      assert remaining > 0
      assert remaining <= Fountain.Conversations.Lifecycle.ask_timeout_ms() - 30_000
      Process.cancel_timer(pending.permission_timer)
    end

    test "ask/6 puts it on the row, announces it and arms the timeout", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      {turn, pending} = Pending.ask(pending, conv.id, turn, 7, "bash", ["yes", "no"])

      assert %{"request_id" => 7, "tool" => "bash", "options" => ["yes", "no"], "asked_at" => _} =
               turn.pending_permission

      assert Fountain.Repo.get!(Conversations.Turn, turn.id).pending_permission["tool"] == "bash"

      assert [{"started", %{"request_id" => 7, "tool" => "bash", "timeout_ms" => ms}}] =
               stages(conv.id, "request")

      assert is_integer(ms) and ms > 0
      assert is_reference(pending.permission_timer)
      assert Process.read_timer(pending.permission_timer) > 0
      Process.cancel_timer(pending.permission_timer)
    end

    test "ask/6 with no turn announces and arms, with nothing to persist on", %{
      conv: conv,
      pending: pending
    } do
      {nil, pending} = Pending.ask(pending, conv.id, nil, 7, "bash", [])
      assert [{"started", _}] = stages(conv.id, "request")
      Process.cancel_timer(pending.permission_timer)
    end

    test "pending_tool/1 reads the row" do
      assert Pending.pending_tool(%{pending_permission: %{"tool" => "bash"}}) == "bash"
      assert Pending.pending_tool(%{pending_permission: nil}) == nil
      assert Pending.pending_tool(nil) == nil
    end

    test "an answer clears the row, cancels the timer, says done and audits nothing", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      {turn, pending} = Pending.ask(pending, conv.id, turn, 7, "bash", ["yes"])
      timer = pending.permission_timer
      peer = fake_peer()

      {turn, pending} =
        Pending.resolve_permission(pending, conv.id, turn, peer, 7, "answered", "yes")

      assert turn.pending_permission == nil
      assert pending.permission_timer == nil
      assert Process.read_timer(timer) == false

      assert [{"started", _}, {"done", %{"outcome" => "answered", "option_id" => "yes"}}] =
               stages(conv.id, "request")

      assert denials(conv.id) == []
      refute_receive {:denied, _}, 50
    end

    test "a timeout denies at the peer, says done (never failed) and audits the tool", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      {turn, pending} = Pending.ask(pending, conv.id, turn, 7, "bash", ["yes"])
      peer = fake_peer()

      {turn, _pending} =
        Pending.resolve_permission(pending, conv.id, turn, peer, 7, "timeout", nil)

      assert turn.pending_permission == nil
      assert_receive {:denied, 7}

      assert [{"started", _}, {"done", %{"outcome" => "timeout", "option_id" => nil}}] =
               stages(conv.id, "request")

      assert [%{"tool" => "bash", "verdict" => "timeout"}] = denials(conv.id)
    end

    test "resolve_pending_permission/5 drains whatever the row holds, and nothing otherwise", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      assert {^turn, ^pending} =
               Pending.resolve_pending_permission(pending, conv.id, turn, nil, "turn_ended")

      assert {nil, ^pending} =
               Pending.resolve_pending_permission(pending, conv.id, nil, nil, "turn_ended")

      {turn, pending} = Pending.ask(pending, conv.id, turn, 9, "rm", [])

      {turn, pending} =
        Pending.resolve_pending_permission(pending, conv.id, turn, nil, "turn_ended")

      assert turn.pending_permission == nil
      assert pending.permission_timer == nil
      assert [%{"tool" => "rm", "verdict" => "turn_ended"}] = denials(conv.id)
    end

    test "answer_permission/6 hands the option to the peer first, and is an error with no peer",
         %{
           conv: conv,
           turn: turn,
           pending: pending
         } do
      assert {{:error, :no_pending_permission}, ^turn, ^pending} =
               Pending.answer_permission(pending, conv.id, turn, nil, 7, "yes")

      test = self()

      peer =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:answer_permission, 7, "yes"}} ->
              send(test, :peer_took_it)
              GenServer.reply(from, :ok)
          end
        end)

      {turn, pending} = Pending.ask(pending, conv.id, turn, 7, "bash", ["yes"])

      assert {:ok, turn, pending} =
               Pending.answer_permission(pending, conv.id, turn, peer, 7, "yes")

      assert_receive :peer_took_it
      assert turn.pending_permission == nil
      assert pending.permission_timer == nil

      refusing =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, _} -> GenServer.reply(from, {:error, :unknown_option})
          end
        end)

      assert {{:error, :unknown_option}, ^turn, ^pending} =
               Pending.answer_permission(pending, conv.id, turn, refusing, 7, "made-up")
    end
  end
end
