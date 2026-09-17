defmodule Fountain.Conversations.ForcedHomeFenceTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Conversations}
  alias Fountain.Conversations.Termination

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)

    home =
      insert_sandbox(user_id: user.id, agent_id: agent.id, mode: "persistent", status: "ready")

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: home, status: "idle")
    %{user: user, agent: agent, home: home, conv: conv}
  end

  # One test, not one per capacity: since ADR 0058 stage 8a the bound is the
  # conversation's runtime, read by the owner under the lock, so a caller has no
  # capacity to pass and the fence is checked before any count is made.
  test "agent deletion fences admission before provider deletion", ctx do
    expect(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      assert handle.name == ctx.home.machine_name
      refute Repo.in_transaction?()
      assert Repo.reload!(ctx.home).reset_requested_at
      assert Repo.reload!(ctx.home).status == "ready"
      assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 1
      assert {:error, :sandbox_unavailable} = admit(ctx)
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

  test "the fence commits before existing conversation actors are stopped", ctx do
    expect(Termination, :terminate_conversation, fn id, opts ->
      refute Repo.in_transaction?()
      assert id == ctx.conv.id
      assert Repo.reload!(ctx.home).reset_requested_at
      assert {:error, :sandbox_unavailable} = admit(ctx)
      Mimic.call_original(Termination, :terminate_conversation, [id, opts])
    end)

    expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> :ok end)
    assert :ok = Termination.destroy_home(ctx.home)
    assert Repo.reload!(ctx.conv).status == "terminated"
  end

  for operation <- [:agent, :home] do
    test "an enclosing transaction refuses #{operation} teardown before any side effect", ctx do
      reject(Managoat.Sandbox.Sprites, :destroy, 1)
      reject(Termination, :terminate_conversation, 2)

      assert {:ok, {:error, :provider_transaction_open}} =
               Repo.transaction(fn ->
                 case unquote(operation) do
                   :agent -> Agents.delete_agent(ctx.agent)
                   :home -> Termination.destroy_home(ctx.home)
                 end
               end)

      assert Repo.get(Agents.Agent, ctx.agent.id)
      refute Repo.reload!(ctx.home).reset_requested_at
      assert Repo.reload!(ctx.home).status == "ready"
      assert Repo.reload!(ctx.conv).status == "idle"
    end
  end

  defp admit(ctx) do
    Conversations._unsafe_create_turn_on_sandbox(
      %{
        conversation_id: ctx.conv.id,
        turn_number: 1,
        status: "running",
        prompt: "late"
      },
      ctx.home.id
    )
  end
end
