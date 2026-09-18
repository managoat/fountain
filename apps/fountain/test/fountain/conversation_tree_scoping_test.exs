defmodule Fountain.ConversationTreeScopingTest do
  @moduledoc """
  Tenant scoping for the conversation spawn graph.

  Two defects, one feeding the other. `parent_conversation_id` came straight
  from a client header and the changeset only enforced a foreign key, so any
  conversation id in the system was accepted — including another tenant's. And
  `get_conversation_tree/1` was raw recursive SQL with no `user_id` predicate,
  so it happily walked across that link. The result leaked conversation ids,
  sources and statuses in *both* directions: the attacker's view pulled in the
  victim's tree, and the victim's view showed the attacker's node.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.Launch

  setup do
    stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
    :ok
  end

  describe "parent_conversation_id validation" do
    test "another tenant's conversation is rejected" do
      victim = insert_verified_user()
      attacker = insert_verified_user()
      victim_conv = insert_conversation(user_id: victim.id)
      agent = insert_agent(user_id: attacker.id)

      assert {:error, :parent_not_found} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => attacker.id,
                 "parent_conversation_id" => victim_conv.id
               })
    end

    test "a nonexistent conversation is rejected" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:error, :parent_not_found} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "parent_conversation_id" => Ecto.UUID.generate()
               })
    end

    test "the caller's own conversation is accepted" do
      user = insert_verified_user()
      parent = insert_conversation(user_id: user.id)
      agent = insert_agent(user_id: user.id)

      assert {:ok, conv} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "parent_conversation_id" => parent.id
               })

      assert conv.parent_conversation_id == parent.id
    end

    test "no parent is still fine" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:ok, conv} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      assert conv.parent_conversation_id == nil
    end
  end

  describe "get_conversation_tree/2" do
    test "returns the caller's own tree" do
      user = insert_verified_user()
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)

      ids = Conversations.get_conversation_tree(root.id, user.id) |> Enum.map(& &1.id)

      assert root.id in ids
      assert child.id in ids
    end

    test "returns nothing for another tenant's conversation" do
      owner = insert_verified_user()
      other = insert_verified_user()
      conv = insert_conversation(user_id: owner.id)

      assert Conversations.get_conversation_tree(conv.id, other.id) == []
    end

    test "does not walk across a foreign parent link left in the data" do
      # Pre-existing rows can still carry a cross-tenant parent, written before
      # validation existed. The query must not follow it even so.
      victim = insert_verified_user()
      attacker = insert_verified_user()

      victim_root = insert_conversation(user_id: victim.id)

      victim_child =
        insert_conversation(user_id: victim.id, parent_conversation_id: victim_root.id)

      # Bypass the context to simulate legacy data.
      attacker_conv =
        insert_conversation(user_id: attacker.id, parent_conversation_id: victim_root.id)

      ids =
        Conversations.get_conversation_tree(attacker_conv.id, attacker.id) |> Enum.map(& &1.id)

      assert attacker_conv.id in ids
      refute victim_root.id in ids
      refute victim_child.id in ids
    end

    test "the victim's view does not show the attacker's grafted node" do
      victim = insert_verified_user()
      attacker = insert_verified_user()
      victim_root = insert_conversation(user_id: victim.id)

      attacker_conv =
        insert_conversation(user_id: attacker.id, parent_conversation_id: victim_root.id)

      ids = Conversations.get_conversation_tree(victim_root.id, victim.id) |> Enum.map(& &1.id)

      assert victim_root.id in ids
      refute attacker_conv.id in ids
    end

    test "a malformed id returns empty rather than raising" do
      user = insert_verified_user()
      assert Conversations.get_conversation_tree("not-a-uuid", user.id) == []
    end

    test "a deep chain terminates rather than running away" do
      # Parent links are client-supplied; the depth bound is what stops a cycle
      # from spinning the recursive CTE forever.
      user = insert_verified_user()

      root = insert_conversation(user_id: user.id)

      leaf =
        Enum.reduce(1..12, root, fn _, parent ->
          insert_conversation(user_id: user.id, parent_conversation_id: parent.id)
        end)

      tree = Conversations.get_conversation_tree(leaf.id, user.id)
      assert length(tree) == 13
    end
  end
end
