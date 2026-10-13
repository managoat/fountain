defmodule Fountain.Conversations.ReleaseFenceTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Termination

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    %{conv: Repo.reload!(conv), sandbox: sandbox}
  end

  test "an orphaned running turn does not block release", c do
    # This test used to assert the opposite, and the opposite took away a
    # release that always worked. With no server alive a `running` turn row is
    # as likely an orphan as a live turn — a deploy, a Horde rebalance or a
    # plain `{:stop, :normal, _}` leaves one behind, which is what
    # `wake_for_interrupt/1` exists for — and release is what an owner reaches
    # for in exactly that state. Inferring "busy" from the row there fences
    # the owner out of their own recovery with nothing to un-fence it.
    turn = insert_turn(c.conv, status: "running")
    assert is_nil(ConversationServer.whereis(c.conv.id))
    assert :ok = Termination.release_conversation(c.conv.id)
    assert Conversations._unsafe_get_conversation!(c.conv.id).status == "terminated"
    # Release terminates the parent; it does not rewrite the turn's history.
    assert Repo.reload!(turn).status == "running"
  end

  test "a live actor's running turn still refuses release", c do
    # The row is only authoritative when something is there to run it.
    turn = insert_turn(c.conv, status: "running")

    assert {:error, :busy} =
             Termination._unsafe_release_binding(c.conv.id, c.sandbox.id, actor_alive?: true)

    assert Conversations._unsafe_get_conversation!(c.conv.id).status == "idle"
    assert Repo.reload!(turn).status == "running"
  end

  test "a released parent cannot be revived by a later admission", c do
    assert :ok = Termination.release_conversation(c.conv.id)
    assert Repo.reload!(c.conv).status == "terminated"
    assert Repo.reload!(c.sandbox) == c.sandbox

    attrs = %{
      conversation_id: c.conv.id,
      turn_number: 2,
      prompt: "too late",
      status: "running",
      started_at: DateTime.utc_now()
    }

    assert {:error, :not_running} =
             Conversations._unsafe_create_turn_on_sandbox(attrs, c.sandbox.id)
  end

  test "an unrelated co-tenant may keep working when this idle conversation releases", c do
    other =
      insert_conversation(user_id: c.conv.user_id, sandbox: c.sandbox, status: "running")

    turn = insert_turn(other, status: "running")
    other = Repo.reload!(other)
    assert :ok = Termination.release_conversation(c.conv.id)
    assert Repo.reload!(other) == other
    assert Repo.reload!(turn) == turn
    assert Repo.reload!(c.sandbox) == c.sandbox
  end

  test "a deleted parent returns not_running", c do
    Repo.delete!(c.conv)
    assert {:error, :not_running} = Termination.release_conversation(c.conv.id)
  end

  test "an explicit no-sandbox binding cannot release a bound replacement", c do
    assert {:error, :ownership_changed} =
             Termination._unsafe_release_binding(c.conv.id, nil, [])

    assert Repo.reload!(c.conv) == c.conv
    assert Repo.reload!(c.sandbox) == c.sandbox
  end

  test "an actor with no sandbox still reports a missing parent as not_running", c do
    Repo.delete!(c.conv)

    assert {:error, :not_running} =
             Termination._unsafe_release_binding(c.conv.id, nil, [])

    # The deletion itself leaves its descriptor on the live machine (#2515);
    # the release wrote nothing.
    assert %{Repo.reload!(c.sandbox) | departed_conversations: []} == c.sandbox
  end
end
