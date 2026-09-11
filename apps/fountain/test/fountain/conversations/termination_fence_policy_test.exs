defmodule Fountain.Conversations.TerminationFencePolicyTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Audit, Conversations}

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    %{user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  test "a persistent home stays available when its only conversation ends", ctx do
    ctx.sandbox |> Ecto.Changeset.change(mode: "persistent") |> Repo.update!()
    assert {:error, :sandbox_kept} = fence(ctx)
    refute Repo.reload!(ctx.sandbox).reset_requested_at
    assert events(ctx) == []
  end

  test "another live conversation keeps an ephemeral machine available", ctx do
    insert_conversation(
      user_id: ctx.user.id,
      agent: ctx.agent,
      sandbox: ctx.sandbox,
      status: "idle"
    )

    assert {:error, :sandbox_kept} = fence(ctx)
    refute Repo.reload!(ctx.sandbox).reset_requested_at
    assert events(ctx) == []
  end

  test "terminal co-tenants do not keep the last conversation's machine", ctx do
    insert_conversation(
      user_id: ctx.user.id,
      agent: ctx.agent,
      sandbox: ctx.sandbox,
      status: "terminated"
    )

    insert_conversation(
      user_id: ctx.user.id,
      agent: ctx.agent,
      sandbox: ctx.sandbox,
      status: "failed"
    )

    assert {:ok, fenced} = fence(ctx)
    assert fenced.reset_requested_at
    assert fenced.status == "ready"
    assert [event] = events(ctx)
    assert event.actor == "ui"
    assert event.metadata["reason"] == "conversation_terminated"

    assert {:error, :sandbox_unavailable} =
             Conversations._unsafe_create_turn_on_sandbox(
               %{conversation_id: ctx.conv.id, turn_number: 1, status: "running", prompt: "late"},
               ctx.sandbox.id,
               :unbounded
             )
  end

  test "a stale actor cannot fence a conversation that moved to another machine", ctx do
    replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")
    {:ok, _} = Conversations.update_conversation(ctx.conv, %{sandbox_id: replacement.id})
    assert {:error, :sandbox_unavailable} = fence(ctx)
    refute Repo.reload!(ctx.sandbox).reset_requested_at
    refute Repo.reload!(replacement).reset_requested_at
    assert events(ctx) == []
  end

  test "a different tenant's conversation cannot authorize this conditional fence", ctx do
    other = insert_verified_user()
    foreign = insert_conversation(user_id: other.id)
    assert {:error, :sandbox_unavailable} = fence(%{ctx | conv: foreign})
    refute Repo.reload!(ctx.sandbox).reset_requested_at
    assert events(ctx) == []
  end

  test "a missing terminating conversation refuses without mutation", ctx do
    Repo.delete!(ctx.conv)
    assert {:error, :sandbox_unavailable} = fence(ctx)
    refute Repo.reload!(ctx.sandbox).reset_requested_at
    assert events(ctx) == []
  end

  defp fence(ctx) do
    Conversations._unsafe_fence_sandbox_for_teardown(ctx.sandbox,
      terminating_conversation_id: ctx.conv.id,
      actor: "ui",
      reason: "conversation_terminated"
    )
  end

  defp events(ctx),
    do: Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.teardown_requested")
end
