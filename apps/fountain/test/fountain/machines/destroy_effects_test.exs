defmodule Fountain.Machines.DestroyEffectsTest do
  @moduledoc """
  The two things a terminal write owes besides the row (ADR 0058 stage 5).

  `Conversations.update_sandbox/2` runs `record_sandbox_usage/2` and
  `maybe_poke_sandbox_queue/2` after its own transaction, and every
  conversation-side destroy used to go through it. The owner finalizes through
  `Fountain.Machines.Lease.cas_update/3` instead — a guarded `update_all`,
  which is what makes a superseded owner invisible and which runs neither
  effect. Losing them is invisible: the row is right, the trail is right, and
  the two things that go missing are a usage row nobody reads until a provider
  bill is reconciled, and a queue poke nobody notices until a tenant at their
  cap waits five minutes for the cron instead of a second for the drain.

  So each of the three retargeted sites is checked for both, by driving the
  site rather than the protocol — the point is that no site lost them, not
  that the protocol has them.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Billing.UsageEvent
  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.Termination
  alias Fountain.Machines.Machine
  alias Fountain.Workers.SandboxQueueDrainer
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    stub(Managoat.Sandbox, :destroy, fn %Handle{} -> :ok end)

    # A queued request somewhere in the fleet is what makes the poke fire at
    # all: `maybe_poke_sandbox_queue/2` probes `any_active_requests?/0` first,
    # and almost every real call finds an empty queue.
    {:ok, _request} =
      Fountain.SandboxQueue.enqueue(%{
        user_id: user.id,
        agent_id: agent.id,
        kind: "start",
        attrs: %{"prompt" => "queued work"}
      })

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

  defp drain_jobs, do: all_enqueued(worker: SandboxQueueDrainer)

  defp assert_effects_ran(ctx) do
    assert "sandbox_terminated" in usage_events(ctx),
           "no sandbox_terminated usage row — a provider bill is reconciled against " <>
             "that row's duration_ms, and this destroy left no trace of itself in it"

    assert drain_jobs() != [],
           "the sandbox queue was not poked — this tenant's freed slot now waits for " <>
             "the five-minute cron instead of draining at once (ADR 0042 decision 5)"
  end

  test "the dead-server terminate runs both", ctx do
    # No server, which is what makes `retire_terminated_sandbox/2` the path
    # under test rather than the server's own half.
    assert ConversationServer.whereis(ctx.conv.id) == nil
    assert :ok = Termination.retire_terminated_sandbox(ctx.conv, actor: "ui")
    assert Repo.reload!(ctx.sandbox).status == "terminated"
    assert_effects_ran(ctx)
  end

  test "the reclaim runs both", ctx do
    assert :ok = Lifecycle.destroy(ctx.conv.id, ctx.sandbox.id, nil, :max_lifetime)
    assert Repo.reload!(ctx.sandbox).status == "terminated"
    assert_effects_ran(ctx)
  end

  test "a destroy through the owner runs both", ctx do
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
    {:ok, _} = Conversations.update_sandbox(ctx.sandbox, %{status: "pending"})

    assert {:ok, :destroyed} =
             Machine.destroy(ctx.sandbox.id, actor: "self", reason: :terminated)

    assert "sandbox_provision_failed" in usage_events(ctx)
    assert "sandbox_terminated" in usage_events(ctx)
  end

  test "a machine that was already terminal records nothing twice", ctx do
    {:ok, _} = Conversations.update_sandbox(ctx.sandbox, %{status: "terminated"})
    before = usage_events(ctx)
    assert "sandbox_terminated" in before

    assert {:ok, :already_terminal} =
             Machine.destroy(ctx.sandbox.id, actor: "self", reason: :terminated)

    assert usage_events(ctx) == before, "the destroy double-counted a terminal machine"
  end
end
