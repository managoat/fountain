defmodule Fountain.Conversations.TurnParentTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Turn, TurnMachine}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    conv =
      insert_conversation(
        user_id: user.id,
        sandbox: sandbox,
        status: "running",
        runtime_session_id: "original-session"
      )

    turn = insert_turn(conv, status: "running")
    %{conv: conv, turn: turn, sandbox: sandbox}
  end

  defp machine(c),
    do: %TurnMachine{conversation_id: c.conv.id, sandbox_id: c.conv.sandbox_id, row: c.turn}

  defp actor(c),
    do: %{
      conversation_id: c.conv.id,
      current_turn: c.turn,
      runtime_session_id: "original-session"
    }

  # Another writer ends the current turn, as an interrupt does.
  defp interrupt!(c) do
    Repo.get!(Turn, c.turn.id)
    |> Ecto.Changeset.change(
      status: "interrupted",
      ended_at: DateTime.truncate(DateTime.utc_now(), :second)
    )
    |> Repo.update!()
  end

  defp successor(c) do
    interrupt!(c)
    insert_turn(c.conv, status: "running")
  end

  # Named for the mechanism that actually refuses this write. `successor/1`
  # cancels before it admits, so the stale actor's turn is already
  # `interrupted` when its completion lands and the writer refuses on the
  # turn's own status, before any parent decision is reached. The refusal that
  # depends on the successor existing is the `latest_turn?` pair below.
  test "a completion whose turn another actor already ended writes nothing", c do
    next = successor(c)
    assert Repo.get!(Turn, c.turn.id).status == "interrupted"

    TurnMachine.finish(machine(c), "completed", %{}, %{})

    assert Repo.get!(Turn, c.turn.id).status == "interrupted"
    assert Repo.get!(Conversation, c.conv.id).status == "running"
    assert Repo.get!(Turn, next.id).status == "running"
  end

  test "a superseded turn cannot idle the parent once its successor has ended too", c do
    insert_turn(c.conv,
      status: "completed",
      ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )

    TurnMachine.finish(machine(c), "completed", %{}, %{})

    assert Repo.get!(Turn, c.turn.id).status == "completed"
    assert Repo.get!(Conversation, c.conv.id).status == "running"
  end

  test "an abandoned older turn cannot stop the newest one idling the parent", c do
    newest = insert_turn(c.conv, status: "running")

    TurnMachine.finish(%{machine(c) | row: newest}, "completed", %{}, %{})

    assert Repo.get!(Turn, c.turn.id).status == "running"
    assert Repo.get!(Turn, newest.id).status == "completed"
    assert Repo.get!(Conversation, c.conv.id).status == "idle"
  end

  test "a completion cannot idle a parent that is not running", c do
    c.conv |> Ecto.Changeset.change(status: "pending") |> Repo.update!()

    TurnMachine.finish(machine(c), "completed", %{}, %{})

    assert Repo.get!(Turn, c.turn.id).status == "completed"
    assert Repo.get!(Conversation, c.conv.id).status == "pending"
  end

  test "the interrupt's delayed second half cannot idle a successor", c do
    next = successor(c)
    TurnMachine.close_interrupted(machine(c))
    assert Repo.get!(Conversation, c.conv.id).status == "running"
    assert Repo.get!(Turn, next.id).status == "running"
  end

  test "the current ended generation can idle its parent", c do
    interrupt!(c)

    assert {:ok, %{applied: true, conversation: %{status: "idle"}}} =
             Conversations._unsafe_idle_after_turn(c.turn)

    assert {:ok, %{applied: false}} = Conversations._unsafe_idle_after_turn(c.turn)
  end

  test "a running turn cannot idle itself", c do
    assert {:ok, %{applied: false}} = Conversations._unsafe_idle_after_turn(c.turn)
    assert Repo.get!(Conversation, c.conv.id).status == "running"
  end

  test "late terminal callbacks preserve terminated and failed parents", c do
    interrupt!(c)

    for status <- ["terminated", "failed"] do
      c.conv |> Ecto.Changeset.change(status: status) |> Repo.update!()
      TurnMachine.close_interrupted(machine(c))
      assert Repo.get!(Conversation, c.conv.id).status == status
    end
  end

  test "session reports update durable and actor state while their turn is current", c do
    state = TurnMachine.accept_runtime_session(actor(c), "new-session")
    assert state.runtime_session_id == "new-session"
    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "new-session"
  end

  test "late session reports and resets cannot change the successor's session or old actor state",
       c do
    successor(c)
    c.conv |> Ecto.Changeset.change(runtime_session_id: "successor-session") |> Repo.update!()
    old = actor(c)
    assert ^old = TurnMachine.accept_runtime_session(old, "late-session")
    assert ^old = TurnMachine.forget_turn_session(old, "session_gone", "old peer")
    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "successor-session"
  end

  test "an ended turn fences session writes even before a successor exists", c do
    interrupt!(c)

    assert {:ok, %{applied: false}} =
             Conversations._unsafe_set_turn_session(c.turn, "late-session")

    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "original-session"
  end

  test "a current missing-session report clears only its own session", c do
    assert %{runtime_session_id: nil} =
             TurnMachine.forget_turn_session(actor(c), "session_gone", "gone")

    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == nil
  end

  test "a forged parent cannot authorize a session write", c do
    other = insert_conversation(user_id: insert_verified_user().id)

    assert {:error, :ownership_changed} =
             Conversations._unsafe_set_turn_session(
               %{c.turn | conversation_id: other.id},
               "wrong-tenant"
             )

    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "original-session"
    assert Repo.get!(Conversation, other.id).runtime_session_id == nil
  end

  test "a deleted parent returns an explicit refusal", c do
    interrupt!(c)
    Repo.delete!(c.conv)
    assert {:error, :not_found} = Conversations._unsafe_idle_after_turn(c.turn)
    assert {:error, :not_found} = Conversations._unsafe_set_turn_session(c.turn, "orphan")
  end

  test "idle legacy reset preserves its behavior but cannot clear a changed session" do
    conv =
      insert_conversation(
        user_id: insert_verified_user().id,
        status: "idle",
        runtime_session_id: "legacy"
      )

    state = %{conversation_id: conv.id, current_turn: nil, runtime_session_id: "old"}
    assert ^state = TurnMachine.forget_turn_session(state, "session_gone", "gone")

    assert %{runtime_session_id: nil} =
             TurnMachine.forget_turn_session(
               %{state | runtime_session_id: "legacy"},
               "session_gone",
               "gone"
             )

    assert Repo.get!(Conversation, conv.id).runtime_session_id == nil
  end

  test "orphan recovery interrupts the turn before idling the parent", c do
    assert {:ok, updated, %{status: "idle"}} =
             Conversations._unsafe_orphan_turn(c.turn, "lost_actor")

    assert updated.status == "interrupted"
    assert updated.orphaned_at
    assert :noop = Conversations._unsafe_orphan_turn(c.turn, "duplicate")
  end

  test "recovering an old already-ended turn leaves its successor untouched", c do
    next = successor(c)
    assert :noop = Conversations._unsafe_orphan_turn(c.turn, "stale_candidate")
    assert Repo.get!(Conversation, c.conv.id).status == "running"
    assert Repo.get!(Turn, next.id).status == "running"
  end

  test "an actor cannot recover an unbounded turn whose parent was rebound" do
    user = insert_verified_user()
    old = insert_sandbox(user_id: user.id, status: "ready")
    replacement = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: old, status: "running")
    turn = insert_turn(conv, status: "running")

    {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: replacement.id})

    # The actor's own `:sandbox_id` is the only record of the binding.
    assert {:error, :ownership_changed} =
             Conversations._unsafe_orphan_turn(turn, "rebound", sandbox_id: old.id)

    assert Repo.get!(Turn, turn.id).status == "running"
    assert Repo.get!(Conversation, conv.id).status == "running"
  end

  test "an actor expecting no sandbox cannot recover a bound parent" do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
    turn = insert_turn(conv, status: "running")

    # An explicit nil is an expectation of "no sandbox", not an absent one.
    assert {:error, :ownership_changed} =
             Conversations._unsafe_orphan_turn(turn, "unbound_actor", sandbox_id: nil)

    assert Repo.get!(Turn, turn.id).status == "running"

    # The reaper omits the key entirely and still recovers.
    assert {:ok, %{status: "interrupted"}, _} = Conversations._unsafe_orphan_turn(turn, "reaper")
  end

  test "legacy recovery closes its old turn without idling a newer running generation" do
    conv = insert_conversation(user_id: insert_verified_user().id, status: "running")
    old = insert_turn(conv, status: "running")
    next = insert_turn(conv, status: "running")

    assert {:ok, %{status: "interrupted"}, %{status: "running"}} =
             Conversations._unsafe_orphan_turn(old, "old_legacy")

    assert Repo.get!(Turn, next.id).status == "running"
  end

  test "admission commits running status even when an older snapshot still said running", c do
    interrupt!(c)
    {:ok, _} = Conversations.update_conversation(c.conv, %{status: "idle"})

    attrs = %{
      conversation_id: c.conv.id,
      turn_number: 2,
      prompt: "next",
      status: "running",
      started_at: DateTime.utc_now()
    }

    assert {:ok, _} =
             Conversations._unsafe_create_turn_on_sandbox(attrs, c.sandbox.id)

    assert Repo.get!(Conversation, c.conv.id).status == "running"
  end

  test "failed admission cannot leave an idle parent running", c do
    interrupt!(c)
    {:ok, _} = Conversations.update_conversation(c.conv, %{status: "idle"})
    attrs = %{conversation_id: c.conv.id, turn_number: 2, status: "running"}

    assert {:error, %Ecto.Changeset{}} =
             Conversations._unsafe_create_turn_on_sandbox(attrs, c.sandbox.id)

    assert Repo.get!(Conversation, c.conv.id).status == "idle"
  end

  test "closed parents refuse user and background admission without revival", c do
    interrupt!(c)
    attrs = %{conversation_id: c.conv.id, turn_number: 2, prompt: "late", status: "running"}

    for status <- ["terminated", "failed"] do
      c.conv |> Ecto.Changeset.change(status: status) |> Repo.update!()

      # Both doors are the same door: autonomous turns go through the
      # sandbox-bound admission like any other (#1749), so one refusal covers
      # the user prompt and the background follow-up.
      assert {:error, :not_running} =
               Conversations._unsafe_create_turn_on_sandbox(attrs, c.sandbox.id)

      assert {:error, :not_running} =
               Fountain.Conversations.Connection.open_autonomous_turn(
                 c.conv.id,
                 c.conv.user_id,
                 c.sandbox.id,
                 c.conv.configuration_revision,
                 c.conv.inference_source
               )

      assert Repo.get!(Conversation, c.conv.id).status == status
    end

    assert Repo.aggregate(Turn, :count) == 1
  end

  test "session preparation and a late pre-start failure cannot change a successor", c do
    next = successor(c)
    assert {:error, :plan_refused} = TurnMachine.session_plan(c.turn, nil)

    assert :ok =
             TurnMachine.fail_before_start(
               c.turn,
               c.conv.id,
               c.conv.sandbox_id,
               "late failure"
             )

    assert Repo.get!(Conversation, c.conv.id).status == "running"
    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "original-session"
    assert Repo.get!(Turn, next.id).status == "running"
  end

  test "refused session preparation returns before command construction", c do
    successor(c)
    state = %{conversation_id: c.conv.id, runtime_session_id: nil}

    assert ^state =
             Conversations.TurnLaunch.run(state, c.conv, c.turn, "late", nil, [], fn _, _, _ ->
               flunk("unexpected spawn failure")
             end)

    assert Repo.get!(Conversation, c.conv.id).status == "running"
  end
end
