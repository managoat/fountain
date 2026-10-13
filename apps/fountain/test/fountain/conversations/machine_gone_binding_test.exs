defmodule Fountain.Conversations.MachineGoneBindingTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.Conversation

  # Every `during machine-gone cleanup` case in
  # `conversation_server_shared_sandbox_test.exs` sends a prompt first, so
  # `end_running_turn/5`'s own binding guard leaves the turn `running` and the
  # running-turn clause below short-circuits before the other two are read.
  # These cases reach the transaction with no running turn, which is the only
  # way the binding and terminal clauses decide anything.
  setup do
    user = insert_verified_user()
    actor = insert_sandbox(user_id: user.id, status: "terminated")
    conv = insert_conversation(user_id: user.id, sandbox: actor, status: "running")
    %{user: user, actor: actor, conv: conv}
  end

  defp rebind(conv, sandbox) do
    {1, _} =
      Repo.update_all(from(c in Conversation, where: c.id == ^conv.id),
        set: [sandbox_id: sandbox.id]
      )
  end

  describe "_unsafe_finish_machine_gone/2" do
    test "idles the actor's own conversation", ctx do
      insert_turn(ctx.conv, status: "interrupted")

      assert :ok = Conversations._unsafe_finish_machine_gone(ctx.conv.id, ctx.actor.id)
      assert Repo.reload!(ctx.conv).status == "idle"
    end

    # The binding clause. Idle is the state that isolates it: a `running`
    # parent with no running turn is released either way (see below), so it
    # cannot tell a present actor from a stale one.
    test "an idle conversation that moved on is not this actor's to narrate", ctx do
      replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")
      {:ok, _} = Conversations.update_conversation(ctx.conv, %{status: "idle"})
      rebind(ctx.conv, replacement)

      assert :noop = Conversations._unsafe_finish_machine_gone(ctx.conv.id, ctx.actor.id)
      assert Repo.reload!(ctx.conv).status == "idle"
    end

    # The terminal clause. A terminal conversation is never `running`, so
    # nothing else in the body would refuse it.
    for status <- ["terminated", "failed"] do
      @tag status: status
      test "a #{status} conversation on the same binding is not narrated", ctx do
        {:ok, _} = Conversations.update_conversation(ctx.conv, %{status: ctx.status})

        assert :noop = Conversations._unsafe_finish_machine_gone(ctx.conv.id, ctx.actor.id)
        assert Repo.reload!(ctx.conv).status == ctx.status
      end
    end

    # The running-turn clause, on the actor's own binding: a successor
    # admitted while this notification was in the mailbox keeps the parent
    # `running`.
    test "a running turn keeps the conversation running", ctx do
      insert_turn(ctx.conv, status: "running")

      assert :noop = Conversations._unsafe_finish_machine_gone(ctx.conv.id, ctx.actor.id)
      assert Repo.reload!(ctx.conv).status == "running"
    end

    # The invariant every other #1767 fence rests on: a refusal must leave the
    # row recoverable. `follow_cotenants/2` casts `:machine_gone` and then
    # rebinds, so this actor's finish routinely reads the new binding after
    # `_unsafe_idle_interrupted_turn/1` — which takes no `sandbox_id` (#2000) —
    # retired the last running turn. `SandboxReaper.sweep_stuck_turns/0` selects running
    # turns and there is none, so refusing the write here strands the row for
    # good.
    test "a conversation that moved on with no running turn is still released", ctx do
      replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")
      insert_turn(ctx.conv, status: "interrupted")
      rebind(ctx.conv, replacement)

      assert :noop = Conversations._unsafe_finish_machine_gone(ctx.conv.id, ctx.actor.id)

      released = Repo.reload!(ctx.conv)
      assert released.status == "idle"
      assert released.sandbox_id == replacement.id
    end

    # The release is a repair of a stuck pair, not a licence to idle a busy
    # conversation the actor no longer owns.
    test "a conversation that moved on and is busy again is left running", ctx do
      replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")
      insert_turn(ctx.conv, status: "running")
      rebind(ctx.conv, replacement)

      assert :noop = Conversations._unsafe_finish_machine_gone(ctx.conv.id, ctx.actor.id)
      assert Repo.reload!(ctx.conv).status == "running"
    end

    test "a deleted conversation is a no-op", ctx do
      id = ctx.conv.id
      Repo.delete!(ctx.conv)

      assert :noop = Conversations._unsafe_finish_machine_gone(id, ctx.actor.id)
    end
  end
end
