defmodule Fountain.Conversations.ForcedHomeFenceTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Conversations}
  alias Fountain.Conversations.ConversationServer

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)

    home =
      insert_sandbox(user_id: user.id, agent_id: agent.id, mode: "persistent", status: "ready")

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: home, status: "idle")
    %{user: user, agent: agent, home: home, conv: conv}
  end

  for capacity <- [1, :unbounded] do
    test "agent deletion fences #{inspect(capacity)} admission before provider deletion", ctx do
      expect(Managoat.Sandbox.Sprites, :destroy, fn handle ->
        assert handle.name == ctx.home.sprite_name
        refute Repo.in_transaction?()
        assert Repo.reload!(ctx.home).reset_requested_at
        assert Repo.reload!(ctx.home).status == "ready"
        assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 1
        assert {:error, :sandbox_unavailable} = admit(ctx, unquote(capacity))
        :ok
      end)

      assert {:ok, _} = Agents.delete_agent(ctx.agent)
      assert Repo.get(Agents.Agent, ctx.agent.id) == nil
      assert Repo.reload!(ctx.home).status == "terminated"
      assert Repo.reload!(ctx.conv).status == "terminated"
      assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 0

      assert Repo.aggregate(
               from(t in Conversations.Turn, where: t.conversation_id == ^ctx.conv.id),
               :count
             ) == 0
    end
  end

  test "the fence commits before existing conversation actors are stopped", ctx do
    expect(ConversationServer, :terminate_conversation, fn id, opts ->
      refute Repo.in_transaction?()
      assert id == ctx.conv.id
      assert Repo.reload!(ctx.home).reset_requested_at
      assert {:error, :sandbox_unavailable} = admit(ctx, :unbounded)
      Mimic.call_original(ConversationServer, :terminate_conversation, [id, opts])
    end)

    expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> :ok end)
    assert :ok = Conversations._unsafe_destroy_home(ctx.home)
    assert Repo.reload!(ctx.conv).status == "terminated"
  end

  for operation <- [:agent, :home] do
    test "an enclosing transaction refuses #{operation} teardown before any side effect", ctx do
      reject(Managoat.Sandbox.Sprites, :destroy, 1)
      reject(ConversationServer, :terminate_conversation, 2)

      assert {:ok, {:error, :provider_transaction_open}} =
               Repo.transaction(fn ->
                 case unquote(operation) do
                   :agent -> Agents.delete_agent(ctx.agent)
                   :home -> Conversations._unsafe_destroy_home(ctx.home)
                 end
               end)

      assert Repo.get(Agents.Agent, ctx.agent.id)
      refute Repo.reload!(ctx.home).reset_requested_at
      assert Repo.reload!(ctx.home).status == "ready"
      assert Repo.reload!(ctx.conv).status == "idle"
    end
  end

  defp admit(ctx, capacity) do
    Conversations._unsafe_create_turn_on_sandbox(
      %{
        conversation_id: ctx.conv.id,
        turn_number: 1,
        status: "running",
        prompt: "late"
      },
      ctx.home.id,
      capacity
    )
  end
end
