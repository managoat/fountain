defmodule Fountain.Machines.DestroyEffectsTest do
  @moduledoc """
  What a terminal write owes besides the row (ADR 0058 stage 5).

  `Conversations.update_sandbox/2` runs `record_sandbox_usage/2` after its own
  transaction, and every conversation-side destroy used to go through it. The
  owner finalizes through `Fountain.Machines.Lease.cas_update/3` instead — a
  guarded `update_all`, which is what makes a superseded owner invisible and
  which runs no effect. Losing it is invisible: the row is right, the trail is
  right, and what goes missing is a usage row nobody reads until a provider
  bill is reconciled.

  So each of the three retargeted sites is checked for it, by driving the
  site rather than the protocol — the point is that no site lost them, not
  that the protocol has them.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Usage.Event, as: UsageEvent
  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.Termination
  alias Fountain.Machines.Machine
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    stub(Managoat.Sandbox, :destroy, fn %Handle{} -> :ok end)

    {:ok, user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  defp usage_events(ctx) do
    Repo.all(
      from e in UsageEvent,
        where: e.resource_id == ^ctx.sandbox.id,
        select: e.event_type,
        order_by: e.id
    )
  end

  defp assert_effects_ran(ctx) do
    assert "sandbox_terminated" in usage_events(ctx),
           "no sandbox_terminated usage row — a provider bill is reconciled against " <>
             "that row's duration_ms, and this destroy left no trace of itself in it"
  end

  test "the dead-server terminate runs the effect", ctx do
    # No server, which is what makes `retire_terminated_sandbox/2` the path
    # under test rather than the server's own half.
    assert ConversationServer.whereis(ctx.conv.id) == nil
    assert :ok = Termination.retire_terminated_sandbox(ctx.conv, actor: "ui")
    assert Repo.reload!(ctx.sandbox).status == "terminated"
    assert_effects_ran(ctx)
  end

  test "the reclaim runs the effect", ctx do
    assert :ok = Lifecycle.destroy(ctx.conv.id, ctx.sandbox.id, nil, :max_lifetime)
    assert Repo.reload!(ctx.sandbox).status == "terminated"
    assert_effects_ran(ctx)
  end

  test "a destroy through the owner runs the effect", ctx do
    # The live-server terminate's half, driven at the door rather than through
    # a `ConversationServer`: what is being checked is the protocol's finalize,
    # and the server adds nothing to it.
    assert {:ok, :destroyed} =
             Machine.destroy(ctx.sandbox.id,
               actor: "self",
               reason: :terminated,
               terminating_conversation_id: ctx.conv.id
             )

    assert_effects_ran(ctx)
  end

  test "a machine destroyed before it was ready records the failed provision too", ctx do
    # `record_sandbox_usage/2`'s other arm, and the reason the *previous* status
    # has to be the one the write saw: a `pending` row that is destroyed emits
    # `sandbox_provision_failed` as well, and a stale reload would read
    # `terminated` and emit neither.
    {:ok, _} = update_sandbox(ctx.sandbox, %{status: "pending"})

    assert {:ok, :destroyed} =
             Machine.destroy(ctx.sandbox.id, actor: "self", reason: :terminated)

    assert "sandbox_provision_failed" in usage_events(ctx)
    assert "sandbox_terminated" in usage_events(ctx)
  end

  test "a machine that was already terminal records nothing twice", ctx do
    {:ok, _} = update_sandbox(ctx.sandbox, %{status: "terminated"})
    before = usage_events(ctx)
    assert "sandbox_terminated" in before

    assert {:ok, :already_terminal} =
             Machine.destroy(ctx.sandbox.id, actor: "self", reason: :terminated)

    assert usage_events(ctx) == before, "the destroy double-counted a terminal machine"
  end
end
