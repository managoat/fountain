defmodule Fountain.Machines.DestroyResetTest do
  @moduledoc """
  The reset family through the destroy protocol (ADR 0058 stage 5c).

  A reset is a destroy, and it was the last one outside the owner. What makes
  it unlike the seven sites 5a and 5b moved is that it arrives *already
  fenced*: `Conversations.reset_sandbox/2` commits `reset_requested_at` under
  the per-sandbox advisory lock, refuses a mid-turn or execution-fenced
  machine, drops every runtime session on it, and records
  `sandbox.reset_requested` — all before anything goes near a provider. Its
  front door is untouched by this stage and is covered by
  `conversations/sandbox_reset_test.exs`.

  Three protocol options carry the difference, and this file exists to hold
  each of them to what it claims:

    * `fence: :held_by_caller` — the teardown fence is *not* written.
      `teardown_requested_at` means something else in this tree
      (`SandboxReaper.sweep_fenced_teardowns/0` finishes rows wearing it after
      15 minutes), and a reset that has not been confirmed is not an abandoned
      teardown. The option asserts the caller's fence rather than trusting it.
    * `on_provider_error: :refuse` — an unconfirmed delete writes nothing. Every
      other caller retires the fenced row anyway; this one holds the fence and
      the tenant's quota slot until a provider says the machine is gone, which
      is what makes the reset retryable and what `sandbox.reset` attests to.
    * `provider: :already_gone` — the admin retry probes first (`reprobe: true`)
      and a machine the provider does not name is retired without a delete
      against a name that is no longer its own.

  And two the reset does not use: `audit_destroy: false`, because
  `record_reset_completed/3`'s `sandbox.reset` is the completion event, and no
  `:notify`, because the reset's own cotenant cast says something a reclaim's
  does not — the transcript survives and the next prompt builds a fresh
  machine.

  The protocol itself is `destroy_test.exs`; the forced teardowns are
  `destroy_forced_test.exs`; the two post-finalize effects are
  `destroy_effects_test.exs`.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Billing.UsageEvent
  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.Termination
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Quotas
  alias Fountain.Workers.SandboxQueueDrainer
  alias Fountain.Workers.SandboxResetReconciler

  setup do
    previous = Application.get_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, token: "test")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, previous),
        else: Application.delete_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    end)

    user = insert_verified_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    home =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        mode: "persistent",
        agent_id: agent.id,
        environment_id: env.id,
        provider: "sprites"
      )

    # Two conversations: the reset's notice goes to every holder, and a machine
    # with one conversation on it cannot tell a per-holder cast from a
    # per-machine one.
    a = insert_conversation(user_id: user.id, agent: agent, sandbox: home, status: "idle")
    b = insert_conversation(user_id: user.id, agent: agent, sandbox: home, status: "idle")

    {:ok, user: user, agent: agent, home: home, a: a, b: b}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp capture_provider do
    test = self()

    stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      send(test, {:destroyed, handle.name, Repo.reload!(%Sandbox{id: handle_id(handle)})})
      :ok
    end)
  end

  # The stub sees a handle, not a row, and what the assertions want is the row
  # *as it stood during the provider call*. The machine name is unique per
  # fixture, so one lookup bridges them.
  defp handle_id(handle) do
    Repo.one!(from s in Sandbox, where: s.machine_name == ^handle.name, select: s.id)
  end

  defp destroyed do
    receive do
      {:destroyed, name, row} -> [{name, row} | destroyed()]
    after
      0 -> []
    end
  end

  defp events(user_id, action) do
    user_id
    |> Audit.list_recent_for_user(200)
    |> Enum.filter(&(&1.action == action))
  end

  defp stage_events(conversation_id) do
    conversation_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.stage == "sandbox"))
  end

  defp usage_events(sandbox_id) do
    Repo.all(
      from e in UsageEvent,
        where: e.resource_id == ^sandbox_id,
        select: e.event_type,
        order_by: e.id
    )
  end

  # A fenced row with nobody working on it: what a lost caller leaves behind,
  # and what every retry path is written for.
  defp fence(ctx) do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, {:unavailable, :timeout}} end)

    capture_log(fn ->
      assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(ctx.home)
    end)

    Repo.reload!(ctx.home)
  end

  # A lease held by somebody else, without a real holder to hold it. `Lease`
  # only ever writes these three together, so a forged one writes all three.
  defp hold_lease(sandbox, ttl_ms \\ 60_000) do
    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
      set: [
        lease_epoch: sandbox.lease_epoch + 1,
        lease_node: "another@node",
        lease_until: DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)
      ]
    )

    Repo.reload!(sandbox)
  end

  # ── the reset through the owner ───────────────────────────────────────────

  describe "a reset destroys through the owner" do
    test "the intent is on the row before the provider call and cleared after", ctx do
      capture_provider()

      assert {:ok, %Sandbox{} = completed} = Conversations.reset_sandbox(ctx.home, actor: "api")

      assert [{name, mid}] = destroyed()
      assert name == ctx.home.machine_name

      # Mid-flight: the machine's owner has stamped its intent and the row is
      # still in a live status, so a reader sees a destroy in progress rather
      # than racing it.
      assert mid.transition == "destroying"
      assert mid.transition_reason == "reset"
      assert mid.status == "ready"
      assert mid.reset_requested_at

      # After: terminal, the stamp cleared, `terminated_at` filled in by the
      # lease's own `COALESCE`, and the fence timestamp kept — an operator
      # reading the row still sees that this was a reset.
      assert completed.status == "terminated"
      assert completed.terminated_at
      assert completed.transition == nil
      assert completed.transition_reason == nil
      assert completed.reset_requested_at == Repo.reload!(ctx.home).reset_requested_at
    end

    test "the teardown fence is not written on top of the reset's own", ctx do
      capture_provider()
      assert {:ok, %Sandbox{}} = Conversations.reset_sandbox(ctx.home)

      # The whole point of `fence: :held_by_caller`. A reset is not a forced
      # teardown: `teardown_requested_at` would put this row in front of
      # `SandboxReaper.sweep_fenced_teardowns/0`, which terminates what it
      # finds after 15 minutes, and a reset that is merely unconfirmed must
      # stay the reconciler's to retry.
      assert [{_name, mid}] = destroyed()
      assert is_nil(mid.teardown_requested_at)
      assert is_nil(Repo.reload!(ctx.home).teardown_requested_at)

      # And no second intent event: the reset's own `sandbox.reset_requested`
      # is the one that was recorded.
      assert events(ctx.user.id, "sandbox.teardown_requested") == []
      assert [_] = events(ctx.user.id, "sandbox.reset_requested")
    end

    test "sandbox.reset is the completion event and no sandbox.destroyed joins it", ctx do
      capture_provider()
      assert {:ok, %Sandbox{}} = Conversations.reset_sandbox(ctx.home, actor: "api")

      assert [reset] = events(ctx.user.id, "sandbox.reset")
      assert reset.actor == "api"
      assert reset.metadata["conversations"] == 2

      assert events(ctx.user.id, "sandbox.destroyed") == [],
             "a reset recorded `sandbox.destroyed` beside its own `sandbox.reset`; " <>
               "both describe the same act and the trail would say it twice"
    end

    test "the holders are told the machine was reset, once each", ctx do
      capture_provider()
      assert {:ok, %Sandbox{}} = Conversations.reset_sandbox(ctx.home)

      # The reset's own notice, not the reclaim's `{:machine_gone, …}`: what a
      # holder needs to know is that its transcript survives and its next
      # prompt builds a fresh machine. `:notify` is deliberately not passed to
      # the protocol, so `MachineEvents.tell_cotenants/5` sends nothing.
      for conv <- [ctx.a, ctx.b] do
        assert [event] = stage_events(conv.id)
        assert %{"event" => "reset", "reason" => "home_reset"} = Jason.decode!(event.data)
      end
    end

    test "the finalize runs the metering and the queue poke, once", ctx do
      {:ok, _request} =
        Fountain.SandboxQueue.enqueue(%{
          user_id: ctx.user.id,
          agent_id: ctx.agent.id,
          kind: "start",
          attrs: %{"prompt" => "queued work"}
        })

      capture_provider()
      assert {:ok, %Sandbox{}} = Conversations.reset_sandbox(ctx.home)

      # `update_sandbox_if/3` ran both of these for the reset before this
      # stage; `Lease.cas_update/3` is a guarded `update_all` and runs neither,
      # so the protocol calls `Conversations.sandbox_status_effects/2` itself.
      # Losing them is invisible until a provider bill is reconciled against a
      # usage row that is not there, or a tenant at their cap waits out the
      # five-minute cron.
      assert usage_events(ctx.home.id) == ["sandbox_terminated"]
      assert all_enqueued(worker: SandboxQueueDrainer) != []
    end

    test "capacity is held until the provider confirms, and released when it does", ctx do
      fenced = fence(ctx)
      assert fenced.status == "ready"
      assert Quotas.active_sandbox_count(ctx.user.id) == 1
      assert events(ctx.user.id, "sandbox.reset") == []
      assert usage_events(ctx.home.id) == []

      # `on_provider_error: :refuse`: nothing was written, so the machine is
      # still counted, still fenced, and the reconciler's to retry. Every other
      # caller of the protocol would have retired this row.
      assert fenced.transition == "destroying"
      assert is_nil(fenced.terminated_at)

      capture_provider()
      assert {:ok, %Sandbox{}} = Conversations.retry_pending_sandbox_reset(fenced)
      assert Quotas.active_sandbox_count(ctx.user.id) == 0
      assert [_] = events(ctx.user.id, "sandbox.reset")
    end
  end

  # ── the fence the caller holds ────────────────────────────────────────────

  describe "fence: :held_by_caller" do
    test "an unfenced row is refused rather than destroyed", ctx do
      reject(Managoat.Sandbox.Sprites, :destroy, 1)

      # The option says the caller holds a durable fence. A row with no
      # `reset_requested_at` is open to admission on every node in the fleet,
      # so destroying it because a caller *said* it was fenced is exactly the
      # bypass the assertion exists to refuse.
      assert capture_log(fn ->
               assert {:error, :not_fenced} =
                        Machine.destroy(ctx.home.id,
                          actor: "self",
                          reason: :reset,
                          fence: :held_by_caller,
                          terminating_conversation_id: nil
                        )
             end) =~ "caller-held fence"

      current = Repo.reload!(ctx.home)
      assert current.status == "ready"
      assert is_nil(current.transition)
      assert is_nil(current.reset_requested_at)
      assert Quotas.active_sandbox_count(ctx.user.id) == 1
    end

    test "a row somebody else already retired is skipped, not destroyed twice", ctx do
      fenced = fence(ctx)

      # The state another destroy's finalize leaves: terminal, `transition`
      # cleared, the reset's fence timestamp still on the row. Written directly
      # because what matters is the shape, and because the two neighbouring
      # shapes are already covered elsewhere — a terminal row *still* stamped
      # `destroying` is answered by `under_lease/3`'s first clause
      # (`destroy_test.exs`), and a live row is the ordinary path.
      Repo.update_all(from(s in Sandbox, where: s.id == ^fenced.id),
        set: [
          status: "terminated",
          transition: nil,
          transition_reason: nil,
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )

      before = usage_events(ctx.home.id)
      reject(Managoat.Sandbox.Sprites, :destroy, 1)

      # Driven at the protocol rather than through `retry_pending_sandbox_reset/2`
      # on purpose. That function's eligibility read excludes a terminal row
      # before any lease is claimed, so it cannot reach this clause and a test
      # written through it would pass with the clause deleted — which is how
      # this test was first written and what the revert probe caught.
      #
      # The window the clause is for is the one the read cannot close: a retry
      # reads a `ready` row, another destroy of the same machine finishes while
      # it waits for the lease, and by the time it holds the lease the row is
      # terminal with its `transition` already cleared by that destroy's own
      # finalize. `fence_sandbox_for_teardown/2` answers this shape for every
      # other caller by returning the terminal row unchanged; a caller that
      # skips the fence has to answer it here.
      #
      # Without the clause the row goes back through the provider and gets
      # written `terminated` over `terminated` — `Lease.cas_update/3` permits
      # that, it is not a revival — which meters the machine a second time and
      # would let a losing caller publish a second completion.
      assert {:ok, :already_terminal} =
               Termination._unsafe_destroy_machine(fenced.id,
                 actor: "self",
                 destroy_reason: :reset,
                 fence: :held_by_caller,
                 on_provider_error: :refuse,
                 audit_destroy: false,
                 terminating_conversation_id: nil
               )

      assert usage_events(ctx.home.id) == before
      assert events(ctx.user.id, "sandbox.reset") == []
      assert events(ctx.user.id, "sandbox.destroyed") == []

      # And the caller's own read, which is the cheaper of the two guards and
      # the one that catches this in practice: a terminal row is `:skipped`
      # without a lease being claimed at all.
      assert {:ok, :skipped} = Conversations.retry_pending_sandbox_reset(fenced)
    end
  end

  # ── the probe ─────────────────────────────────────────────────────────────

  describe "provider: :already_gone" do
    test "a confirmed-missing machine is retired without a delete", ctx do
      fenced = fence(ctx)

      expect(Managoat.Sandbox, :get, fn handle ->
        assert handle.name == ctx.home.machine_name
        {:error, :not_found}
      end)

      # The observable the admin retry has always had: an operator
      # reconciling a fence probes first, and a machine the provider does not
      # name gets no delete issued against its name. The row is retired all
      # the same, through the same finalize as any other destroy.
      reject(Managoat.Sandbox, :destroy, 1)
      reject(Managoat.Sandbox.Sprites, :destroy, 1)

      assert {:ok, %Sandbox{status: "terminated"}} =
               Conversations.retry_pending_sandbox_reset(fenced,
                 reprobe: true,
                 actor: "admin"
               )

      assert Quotas.active_sandbox_count(ctx.user.id) == 0
      assert [_] = events(ctx.user.id, "sandbox.reset")
    end

    test "a machine the probe still finds is deleted, once", ctx do
      fenced = fence(ctx)
      expect(Managoat.Sandbox, :get, fn handle -> {:ok, handle} end)
      capture_provider()

      assert {:ok, %Sandbox{status: "terminated"}} =
               Conversations.retry_pending_sandbox_reset(fenced, reprobe: true, actor: "admin")

      assert [{name, _row}] = destroyed()
      assert name == ctx.home.machine_name
    end

    test "an uncertain probe keeps the fence and calls nothing", ctx do
      fenced = fence(ctx)
      expect(Managoat.Sandbox, :get, fn _ -> {:error, {:unavailable, :timeout}} end)
      reject(Managoat.Sandbox, :destroy, 1)
      reject(Managoat.Sandbox.Sprites, :destroy, 1)

      assert {:error, :sandbox_reset_pending} =
               Conversations.retry_pending_sandbox_reset(fenced, reprobe: true)

      assert Repo.reload!(ctx.home).status == "ready"
      assert Quotas.active_sandbox_count(ctx.user.id) == 1
    end
  end

  # ── the lease, and who stands off ─────────────────────────────────────────

  describe "the reconciler honours the machine's lease" do
    test "a row whose owner holds a live lease is neither swept nor retried", ctx do
      fenced = ctx |> fence() |> hold_lease()
      reject(Managoat.Sandbox.Sprites, :destroy, 1)

      # The sweep: no job is enqueued for a machine somebody is working on.
      assert :ok = perform_job(SandboxResetReconciler, %{})
      assert all_enqueued(worker: SandboxResetReconciler) == []

      # And the door, for a job enqueued before the lease was taken.
      assert {:error, :sandbox_unavailable} =
               Conversations.retry_pending_sandbox_reset(fenced)

      # A snooze, not an error. The job made no provider call and has nothing
      # to reconcile yet, so spending one of `max_attempts: 10` on it would let
      # contention alone discard a job that has never once asked a provider
      # anything — and stage 6 makes contention ordinary.
      assert {:snooze, 60} = perform_job(SandboxResetReconciler, %{sandbox_id: fenced.id})

      assert Repo.reload!(ctx.home).status == "ready"
    end

    test "the same row is swept and retried once the lease has expired", ctx do
      fenced = ctx |> fence() |> hold_lease(-1_000)
      capture_provider()

      assert :ok = perform_job(SandboxResetReconciler, %{})
      assert [job] = all_enqueued(worker: SandboxResetReconciler)
      assert job.args == %{"sandbox_id" => fenced.id}
      assert :ok = perform_job(SandboxResetReconciler, job.args)

      assert Repo.reload!(ctx.home).status == "terminated"
      assert [{name, _}] = destroyed()
      assert name == ctx.home.machine_name
    end

    test "a forced destroy mid-flight is not joined by the reconciler", ctx do
      # The 5b review's finding, made concrete: a forced teardown stamps
      # `reset_requested_at` too (the teardown fence reuses the reset fence),
      # so a machine being destroyed outright matches the reconciler's sweep
      # exactly. Forged rather than raced, because what is under test is the
      # predicate, not the timing: a row mid-destroy, at the provider, with its
      # owner's lease live.
      fenced = fence(ctx)

      {:ok, epoch} = Lease.claim(fenced.id, "another@node", 60_000)

      {:ok, _} =
        Lease.cas_update(fenced.id, epoch,
          transition: "destroying",
          transition_reason: "account_deleted"
        )

      # The teardown fence the forced destroy would have written. Not a
      # `Lease` write — `teardown_requested_at` is not one of its writable
      # columns, because the fence is `Lifecycle`'s.
      Repo.update_all(from(s in Sandbox, where: s.id == ^fenced.id),
        set: [teardown_requested_at: DateTime.utc_now()]
      )

      # Observed rather than rejected, and on purpose: the second half of this
      # test needs the provider to work, and a `reject` set here would still be
      # in force then — Mimic's expectations replace one another, they do not
      # take turns. So the provider is captured once and the standoff is "it
      # was never called".
      capture_provider()
      assert :ok = perform_job(SandboxResetReconciler, %{})
      assert all_enqueued(worker: SandboxResetReconciler) == []

      assert {:snooze, 60} = perform_job(SandboxResetReconciler, %{sandbox_id: fenced.id})

      assert destroyed() == [],
             "the reconciler called the provider on a machine another destroy was " <>
               "halfway through deleting"

      # Once the owner is gone, the row is an interrupted destroy like any
      # other and the protocol's takeover finishes it — from the provider call,
      # with no second fence and no second intent event.
      Repo.update_all(from(s in Sandbox, where: s.id == ^fenced.id),
        set: [lease_until: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert :ok = perform_job(SandboxResetReconciler, %{sandbox_id: fenced.id})
      assert [{_name, _row}] = destroyed()
      assert Repo.reload!(ctx.home).status == "terminated"
    end
  end

  # ── the refusal, at the two surfaces that can see it ──────────────────────

  test "a busy machine is a retryable refusal, not an unconfirmed deletion", ctx do
    fenced = ctx |> fence() |> hold_lease()
    reject(Managoat.Sandbox.Sprites, :destroy, 1)

    # The distinction the API renders as 503-with-retry-after versus 409: one
    # says come back, the other says the fence is standing and Fountain is
    # retrying. `reset_sandbox/2`'s own front door never reaches this — a
    # fenced row is `:sandbox_reset_pending` before any lease is claimed — so
    # the door that can answer it is the retry.
    assert {:error, :sandbox_unavailable} = Conversations.retry_pending_sandbox_reset(fenced)

    # And through the protocol, which is where the word comes from — driven
    # directly, with its own short wait, because no call site in `lib/` may
    # override the bounds (`machine_bounds_test.exs`) and waiting out the real
    # five seconds here would buy nothing.
    assert capture_log(fn ->
             assert {:error, :machine_busy} =
                      Destroy.run(fenced.id,
                        actor: "self",
                        reason: :reset,
                        fence: :held_by_caller,
                        on_provider_error: :refuse,
                        audit: false,
                        busy_wait_ms: 10
                      )
           end) =~ "lease held by another@node"

    assert Repo.reload!(ctx.home).status == "ready"
    assert Quotas.active_sandbox_count(ctx.user.id) == 1
  end
end
