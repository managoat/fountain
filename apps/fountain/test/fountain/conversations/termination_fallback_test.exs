defmodule Fountain.Conversations.TerminationFallbackTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Audit, Conversations}
  alias Fountain.Conversations.ConversationServer

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    assert ConversationServer.whereis(conv.id) == nil
    %{user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  test "fences attachments before retiring the row and attributes the intent", ctx do
    expect(Conversations, :update_sandbox, fn sandbox, attrs ->
      refute Repo.in_transaction?()
      assert Repo.reload!(sandbox).reset_requested_at
      assert {:error, :sandbox_reset_pending} = attach(ctx)
      Mimic.call_original(Conversations, :update_sandbox, [sandbox, attrs])
    end)

    assert :ok = terminate(ctx)
    assert Repo.reload!(ctx.sandbox).status == "terminated"
    assert Repo.reload!(ctx.conv).status == "terminated"
    assert [intent] = events(ctx, "sandbox.teardown_requested")
    assert intent.actor == "ui"
    assert intent.request_ip == "192.0.2.5"
    assert intent.metadata["reason"] == "conversation_terminated"
    assert [_] = events(ctx, "conversation.terminated")
  end

  test "an attachment that wins before the fence keeps the sandbox", ctx do
    expect(Conversations, :_unsafe_fence_sandbox_for_teardown, fn sandbox, opts ->
      assert {:ok, successor} = attach(ctx)
      assert successor.sandbox_id == sandbox.id
      Mimic.call_original(Conversations, :_unsafe_fence_sandbox_for_teardown, [sandbox, opts])
    end)

    assert :ok = terminate(ctx)
    assert Repo.reload!(ctx.conv).status == "terminated"
    assert Repo.reload!(ctx.sandbox).status == "ready"
    refute Repo.reload!(ctx.sandbox).reset_requested_at
    assert events(ctx, "sandbox.teardown_requested") == []
  end

  test "a fence refusal leaves the machine available and records no completed termination", ctx do
    expect(Conversations, :_unsafe_fence_sandbox_for_teardown, fn _, _ ->
      {:error, :sandbox_unavailable}
    end)

    assert {:error, :sandbox_unavailable} = terminate(ctx)
    assert Repo.reload!(ctx.conv).status == "terminated"
    assert Repo.reload!(ctx.sandbox).status == "ready"
    assert events(ctx, "conversation.terminated") == []
  end

  test "a retirement write error is returned with the admission fence intact", ctx do
    expect(Conversations, :update_sandbox, fn _, _ -> {:error, :write_refused} end)
    assert {:error, :write_refused} = terminate(ctx)
    assert Repo.reload!(ctx.sandbox).status == "ready"
    assert Repo.reload!(ctx.sandbox).reset_requested_at
    assert [_] = events(ctx, "sandbox.teardown_requested")
    assert events(ctx, "conversation.terminated") == []
  end

  test "a persistent machine remains available without a teardown intent", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.sandbox, mode: "persistent"))
    assert :ok = terminate(ctx)
    assert Repo.reload!(ctx.sandbox).status == "ready"
    refute Repo.reload!(ctx.sandbox).reset_requested_at
    assert events(ctx, "sandbox.teardown_requested") == []
  end

  test "an already failed sandbox keeps its terminal state", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.sandbox, status: "failed"))
    assert :ok = terminate(ctx)
    assert Repo.reload!(ctx.conv).status == "terminated"
    assert Repo.reload!(ctx.sandbox).status == "failed"
    assert events(ctx, "sandbox.teardown_requested") == []
  end

  defp terminate(ctx),
    do:
      ConversationServer.terminate_conversation(ctx.conv.id, actor: "ui", request_ip: "192.0.2.5")

  defp attach(ctx) do
    Conversations.start_conversation(%{
      "user_id" => ctx.user.id,
      "agent_id" => ctx.agent.id,
      "sandbox_id" => ctx.sandbox.id
    })
  end

  defp events(ctx, action), do: Audit.list_for_user(ctx.user.id, action_prefix: action)
end
