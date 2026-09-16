defmodule Fountain.Machines.DestroyForcedTest do
  @moduledoc """
  The forced-teardown side of the destroy protocol (ADR 0058 stage 5b).

  Four sites stopped destroying the provider machine and writing the terminal
  row themselves and now ask `Fountain.Machines.Machine.destroy/2` for it:
  `Termination.destroy_home/2` (deleting an agent), `Accounts.Deletion`,
  `SandboxReaper`'s expiry of an abandoned machine, and
  `Termination.reap_sandbox/2`'s dead-server arm.

  What makes them *forced* is one option, and it is the only thing that could
  quietly break all four at once: they pass `terminating_conversation_id: nil`,
  so `Lifecycle.fence_sandbox_for_teardown/2` has no conversation to keep the
  machine *for* and `{:ok, :kept}` is unreachable. Stage 5a's review found the
  opposite mistake — a conversation id handed to a fence that had already
  decided — and what it costs is a machine fenced, live and billing that
  nothing will ever collect. So every site here is driven against both shapes
  the fence would otherwise keep: a persistent home, and a machine a second
  conversation still holds. One bound conversation naming *itself* is the one
  shape the fence does not keep, so a test with a single conversation on the
  machine proves nothing about this and is not the coverage.

  The protocol itself is `destroy_test.exs`; its two post-finalize effects are
  `destroy_effects_test.exs`. This file is about the four callers: what each one
  asks for, what the trail says afterwards, and what each does when the destroy
  is refused — because none of these callers may be stopped by one machine.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Accounts.Deletion
  alias Fountain.Agents
  alias Fountain.Audit
  alias Fountain.Billing.UsageEvent
  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.Termination
  alias Fountain.Machines.Destroy
  alias Fountain.Workers.SandboxReaper

  defmodule OkProbe do
    @moduledoc false
    use GenServer
    def init(state), do: {:ok, state}
    def handle_call(_message, _from, state), do: {:reply, :ok, state}
  end

  setup :set_mimic_global

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    {:ok, user: user, agent: agent}
  end

  # ── shared helpers ────────────────────────────────────────────────────────

  # The provider, stubbed at the adapter rather than the `Managoat.Sandbox`
  # facade, so the handle the protocol builds from the row is really built and
  # the name it carries is the one asserted on.
  defp capture_provider do
    test = self()

    stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      send(test, {:destroyed, handle.name})
      :ok
    end)
  end

  defp destroyed_names do
    receive do
      {:destroyed, name} -> [name | destroyed_names()]
    after
      0 -> []
    end
  end

  # The order that matters, checked from inside the provider call itself: the
  # fence and the intent are on the row before the machine is touched, and the
  # row is still in a live status, so a finalize that never lands leaves
  # something `SandboxReaper.sweep_fenced_teardowns/0` can find.
  defp expect_provider_sees_the_intent(sandbox) do
    test = self()

    expect(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      row = Repo.reload!(sandbox)

      send(
        test,
        {:at_provider, handle.name, row.status, row.transition, row.teardown_requested_at}
      )

      :ok
    end)
  end

  defp events(user_id, action) do
    user_id
    |> Audit.list_recent_for_user(200)
    |> Enum.filter(&(&1.action == action))
  end

  defp usage_events(sandbox_id) do
    Repo.all(from e in UsageEvent, where: e.resource_id == ^sandbox_id, select: e.event_type)
  end

  defp no_servers, do: stub(ConversationServer, :whereis, fn _ -> nil end)

  # A destroy nobody can run right now: the protocol's own `:machine_busy`,
  # which `Machine.destroy/2` renders as `:sandbox_unavailable`. Stubbed rather
  # than produced with a real held lease, because a real one costs the caller
  # `Destroy.busy_wait_ms/0` — five seconds — and no call site may shorten that
  # (`machine_bounds_test.exs`).
  defp refuse_destroy_of(sandbox_id) do
    stub(Destroy, :run, fn
      ^sandbox_id, _opts -> {:error, :machine_busy}
      other, opts -> Mimic.call_original(Destroy, :run, [other, opts])
    end)
  end

  defp age(sandbox, conv, minutes) do
    at = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
      set: [inserted_at: at, updated_at: at]
    )

    if conv do
      Repo.update_all(
        from(c in Conversations.Conversation, where: c.id == ^conv.id),
        set: [inserted_at: at, updated_at: at]
      )
    end

    Repo.reload!(sandbox)
  end

  defp with_bounds(pairs, fun) do
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  # ── site 1: destroy_home/2, the agent's homes ─────────────────────────────

  describe "deleting an agent destroys its homes through the owner" do
    setup ctx do
      home =
        insert_sandbox(
          user_id: ctx.user.id,
          agent_id: ctx.agent.id,
          mode: "persistent",
          status: "ready"
        )

      conv =
        insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: home, status: "idle")

      no_servers()
      {:ok, home: home, conv: conv}
    end

    test "the machine is destroyed, and the row is fenced and live when it is", ctx do
      expect_provider_sees_the_intent(ctx.home)

      assert :ok = Termination.destroy_home(ctx.home, actor: "ui")

      assert_received {:at_provider, name, status, transition, fenced_at}
      assert name == ctx.home.machine_name

      assert status == "ready",
             "the row went terminal before the machine was destroyed; a finalize lost " <>
               "here would leave a terminal row and a machine nobody can find"

      assert transition == "destroying"
      assert fenced_at, "the fence had not committed before the provider call"

      assert Repo.reload!(ctx.home).status == "terminated"
      assert Repo.reload!(ctx.home).transition == nil
      assert Repo.reload!(ctx.conv).status == "terminated"
    end

    test "both machine events are recorded, and they agree on what happened", ctx do
      capture_provider()
      assert :ok = Termination.destroy_home(ctx.home, actor: "ui")

      assert [requested] = events(ctx.user.id, "sandbox.teardown_requested")
      assert requested.metadata["reason"] == "agent_deleted"

      assert [destroyed] = events(ctx.user.id, "sandbox.destroyed")
      assert destroyed.resource_id == ctx.home.id
      assert destroyed.metadata["reason"] == "home_destroyed"
      assert destroyed.metadata["sprite_name"] == ctx.home.machine_name
      assert destroyed.metadata["provider"] == ctx.home.provider

      # One operation, one actor. ADR 0013 §2 keeps `system:<worker>` matched to
      # the module doing the work and there is no HomeReset module; the cascade
      # is said by `reason`, which both events carry. The conversations on the
      # home are still terminated as `system:home_reset` — that is a different
      # event about a different resource.
      assert destroyed.actor == "ui"
      assert requested.actor == "ui"
      assert destroyed.actor == requested.actor
    end

    test "the finalize's two effects still run", ctx do
      capture_provider()
      assert :ok = Termination.destroy_home(ctx.home, actor: "ui")
      assert "sandbox_terminated" in usage_events(ctx.home.id)
    end

    test "a home with idle conversations still bound is destroyed, not kept", ctx do
      # The `:kept` shape twice over — a persistent home *and* a conversation
      # bound to it — and the one that must not happen here. The agent is gone,
      # so the identity the home was built for is gone with it (ADR 0023 step
      # 5); keeping it would leave a machine with nothing that could ever reach
      # it, billing until somebody noticed.
      capture_provider()
      assert :ok = Termination.destroy_home(ctx.home, actor: "ui")

      assert destroyed_names() == [ctx.home.machine_name]
      assert Repo.reload!(ctx.home).status == "terminated"
    end

    test "a live co-tenant is stopped first, and the machine still goes", ctx do
      other =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.home,
          status: "running"
        )

      {:ok, probe} = GenServer.start_link(OkProbe, %{})
      stub(ConversationServer, :whereis, fn id -> if id == other.id, do: probe, else: nil end)
      test = self()

      stub(Termination, :terminate_conversation, fn id, opts ->
        # Every non-terminal conversation on the home is ended, live server or
        # not: the home is going away, so nothing on it can keep running.
        assert id in [ctx.conv.id, other.id]
        assert opts[:actor] == "system:home_reset"

        # The fence is already committed when the conversations are stopped, so
        # nothing can attach to the home while their servers shut down.
        send(test, {:terminating, id, Repo.reload!(ctx.home).teardown_requested_at})
        Mimic.call_original(Termination, :terminate_conversation, [id, opts])
      end)

      capture_provider()
      assert :ok = Termination.destroy_home(ctx.home, actor: "ui")

      assert_received {:terminating, _id, fenced_at}
      assert fenced_at
      assert_received {:terminating, _other_id, _}
      assert destroyed_names() == [ctx.home.machine_name]
      assert Repo.reload!(ctx.home).status == "terminated"
    end

    test "a provider error still retires the row and still records the destroy", ctx do
      expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :unavailable} end)

      log = capture_log(fn -> assert :ok = Termination.destroy_home(ctx.home, actor: "ui") end)

      assert log =~ "provider destroy failed"
      assert Repo.reload!(ctx.home).status == "terminated"
      assert [_] = events(ctx.user.id, "sandbox.destroyed")
    end

    test "a refused destroy does not stop the agent from being deleted", ctx do
      refuse_destroy_of(ctx.home.id)
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      log = capture_log(fn -> assert {:ok, _} = Agents.delete_agent(ctx.agent, actor: "ui") end)

      assert log =~ "destroy refused"
      refute Repo.get(Agents.Agent, ctx.agent.id)

      # Fenced and live: closed to new attachments, and the shape
      # `SandboxReaper.sweep_fenced_teardowns/0` exists to finish.
      home = Repo.reload!(ctx.home)
      assert home.status == "ready"
      assert home.teardown_requested_at
      assert events(ctx.user.id, "sandbox.destroyed") == []
    end
  end

  # ── site 2: account deletion ──────────────────────────────────────────────

  describe "account deletion destroys a tenant's machines through the owner" do
    setup ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: sandbox,
          status: "idle"
        )

      no_servers()
      {:ok, sandbox: sandbox, conv: conv}
    end

    test "the machine is destroyed and the row ends terminal for the reaper", ctx do
      expect_provider_sees_the_intent(ctx.sandbox)

      capture_log(fn ->
        assert {:ok, %{sprites_destroyed: 1}} = Deletion.delete_user(ctx.user)
      end)

      assert_received {:at_provider, name, status, transition, fenced_at}
      assert name == ctx.sandbox.machine_name
      assert status == "ready"
      assert transition == "destroying"
      assert fenced_at

      assert Repo.reload!(ctx.sandbox).status == "terminated"
    end

    test "a shared machine and a home are both destroyed, never kept", ctx do
      # Both shapes the fence would answer `:sandbox_kept` for if this path
      # named a terminating conversation: a machine a second conversation still
      # holds, and a persistent home. Either one left standing is exactly the
      # leak `@non_terminal` in `Accounts.Deletion` exists to prevent — a
      # machine owned by an account that no longer exists, with `user_id`
      # nilified seconds later so nothing could ever find it again.
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox: ctx.sandbox,
        status: "idle"
      )

      home =
        insert_sandbox(
          user_id: ctx.user.id,
          agent_id: ctx.agent.id,
          mode: "persistent",
          status: "ready"
        )

      insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: home, status: "idle")

      capture_provider()

      capture_log(fn ->
        assert {:ok, %{sprites_destroyed: 2}} = Deletion.delete_user(ctx.user)
      end)

      assert Enum.sort(destroyed_names()) ==
               Enum.sort([ctx.sandbox.machine_name, home.machine_name])

      assert Repo.reload!(ctx.sandbox).status == "terminated"
      assert Repo.reload!(ctx.sandbox).user_id == nil
      assert Repo.reload!(home).status == "terminated"
    end

    test "no per-machine sandbox.destroyed survives the delete", ctx do
      # The stage 5b decision on #2344. `audit_events.user_id` is nilified by
      # the delete, so a per-machine row would outlive its subject as an
      # anonymous event describing a cascade; `account.deleted` carries the
      # identity in its own metadata. The fence's intent is *not* suppressed —
      # it is written before this path can say anything about it, and a
      # teardown that was requested did happen.
      capture_provider()
      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(ctx.user) end)

      destroyed =
        Repo.all(from e in Audit.Event, where: e.action == "sandbox.destroyed", select: e.id)

      assert destroyed == []

      assert [_] =
               Repo.all(
                 from e in Audit.Event,
                   where:
                     e.action == "sandbox.teardown_requested" and e.resource_id == ^ctx.sandbox.id
               )
    end

    test "no sandbox.destroyed survives the delete on the live-server path either", ctx do
      # The describe's other suppression test runs under `no_servers()`, which
      # is the path `audit: false` always reached. This is the other one: a
      # conversation with a live server is terminated through it, the server
      # destroys the machine, and until this review round the flag was dropped
      # by `terminate_conversation/2`'s `Keyword.take` before the server saw
      # it — so exactly one orphaned `sandbox.destroyed` per deleted account
      # that still had a server, with `user_id` nilified seconds later.
      {:ok, probe} = GenServer.start_link(OkProbe, %{})
      stub(ConversationServer, :whereis, fn id -> if id == ctx.conv.id, do: probe, else: nil end)
      capture_provider()

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(ctx.user) end)

      assert Repo.all(from e in Audit.Event, where: e.action == "sandbox.destroyed") == []
    end

    test "stopping a principal's compute keeps its rows, so it records the destroy", ctx do
      # The other caller of `destroy_sprites/2` (ADR 0044). Nothing is deleted
      # here, `user_id` survives, and a machine torn down is worth an event —
      # which is why the suppression is `delete_user/2`'s and not this module's.
      capture_provider()

      capture_log(fn ->
        assert 1 ==
                 Deletion.destroy_sprites(ctx.user,
                   reason: "principal_closed",
                   actor: "system:principal_sweep"
                 )
      end)

      assert [destroyed] = events(ctx.user.id, "sandbox.destroyed")
      assert destroyed.actor == "system:principal_sweep"
      assert destroyed.metadata["reason"] == "principal_closed"
    end

    test "a provider error does not abort the deletion", ctx do
      expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :unavailable} end)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(ctx.user) end)

      refute Repo.get(Fountain.Accounts.User, ctx.user.id)
      assert Repo.reload!(ctx.sandbox).status == "terminated"
    end

    test "a refused destroy does not abort the deletion", ctx do
      refuse_destroy_of(ctx.sandbox.id)

      log =
        capture_log(fn ->
          assert {:ok, %{sprites_destroyed: 0}} = Deletion.delete_user(ctx.user)
        end)

      assert log =~ "refused"
      refute Repo.get(Fountain.Accounts.User, ctx.user.id)
      assert Repo.reload!(ctx.sandbox).status == "ready"
      assert Repo.reload!(ctx.sandbox).teardown_requested_at
    end

    test "an enclosing transaction is still refused before any teardown", ctx do
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      assert {:ok, {:error, :provider_transaction_open}} =
               Repo.transaction(fn -> Deletion.delete_user(ctx.user) end)

      assert Repo.reload!(ctx.sandbox).status == "ready"
      refute Repo.reload!(ctx.sandbox).teardown_requested_at
    end
  end

  # ── site 3: the reaper's expiry ───────────────────────────────────────────

  describe "the reaper expires an abandoned machine through the owner" do
    setup ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: sandbox,
          status: "idle"
        )

      no_servers()
      {:ok, sandbox: age(sandbox, conv, 60 * 24 * 83), conv: conv}
    end

    defp sweep(fun) do
      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fun)
      end)
    end

    test "the machine dies in the same pass, with the row fenced and live when it does", ctx do
      expect_provider_sees_the_intent(ctx.sandbox)

      sweep(fn -> assert {0, 1, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert_received {:at_provider, name, status, transition, fenced_at}
      assert name == ctx.sandbox.machine_name
      assert status == "ready"
      assert transition == "destroying"
      assert fenced_at

      assert Repo.reload!(ctx.sandbox).status == "terminated"

      # The thread survives a reclaimed machine; the next prompt provisions a
      # fresh one (decisions/0017).
      assert Repo.reload!(ctx.conv).status == "idle"
    end

    test "an abandoned row with idle conversations bound is expired, never kept", ctx do
      # The failure this test exists for. An abandoned `ready` row still has
      # its conversations bound — that is what makes it abandoned rather than
      # empty — so a `terminating_conversation_id` on this path would answer
      # `:sandbox_kept` for every machine the ceiling was written to bound, and
      # each one would bill forever with nothing able to expire it. Two of
      # them, because one bound conversation naming *itself* is the one shape
      # the fence does not keep: it takes a co-tenant, or a home.
      second =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "idle"
        )

      capture_provider()
      sweep(fn -> assert {0, 1, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert destroyed_names() == [ctx.sandbox.machine_name]
      assert Repo.reload!(ctx.sandbox).status == "terminated"
      assert Repo.reload!(second).status == "idle"
    end

    test "a persistent home past its ceiling is expired too", ctx do
      # Aged in place rather than switched with `update_sandbox/2`, which moves
      # `updated_at` and would put the row back inside the abandoned sweep's
      # grace window.
      Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id),
        set: [mode: "persistent"]
      )

      capture_provider()
      sweep(fn -> assert {0, 1, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert destroyed_names() == [ctx.sandbox.machine_name]
      assert Repo.reload!(ctx.sandbox).status == "terminated"
      assert Repo.reload!(ctx.sandbox).mode == "persistent"
    end

    test "both the reaper's own event and the protocol's are recorded", ctx do
      capture_provider()
      sweep(fn -> assert {0, 1, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert [expired] = events(ctx.user.id, "sandbox.expired")
      assert expired.actor == "system:sandbox_reaper"
      assert expired.metadata["reason"] == "past max lifetime"

      assert [destroyed] = events(ctx.user.id, "sandbox.destroyed")
      assert destroyed.actor == "system:sandbox_reaper"
      assert destroyed.metadata["reason"] == "max_lifetime"
    end

    test "a provider error still retires the row", ctx do
      expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :unavailable} end)

      sweep(fn -> assert {0, 1, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert Repo.reload!(ctx.sandbox).status == "terminated"
      assert [_] = events(ctx.user.id, "sandbox.expired")
    end

    test "the idle arm on a provider that cannot park expires through the owner too", ctx do
      # `idle_sweep/1`'s first `expire/3` arm, which had no test before this
      # round: a provider whose `idle_action/1` is `:destroy` has no park to
      # offer, so an idle machine is reclaimed rather than suspended.
      # Past the idle bound but under the ceiling, so the verdict is
      # `{:expired, :idle}` and reaches `idle_sweep/2` — the describe's own
      # fixture is 83 days old and goes down the max-lifetime arm.
      sandbox = age(ctx.sandbox, ctx.conv, 60 * 5)
      stub(Lifecycle, :idle_action, fn _provider -> :destroy end)
      capture_provider()

      sweep(fn -> assert {0, 1, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert destroyed_names() == [sandbox.machine_name]
      assert Repo.reload!(sandbox).status == "terminated"
      assert [expired] = events(ctx.user.id, "sandbox.expired")
      assert expired.metadata["reason"] == "idle on a provider without suspend"
      assert [destroyed] = events(ctx.user.id, "sandbox.destroyed")
      assert destroyed.metadata["reason"] == "idle"
    end

    test "the idle arm whose suspend call fails expires through the owner too", ctx do
      # The second arm, and the one that matters for load: a provider whose
      # suspend is down sends every idle row down the destroy path at once,
      # which is why `@destroy_limit` now covers pass 1 (below).
      sandbox = age(ctx.sandbox, ctx.conv, 60 * 5)
      stub(Lifecycle, :idle_action, fn _provider -> :suspend end)
      stub(Managoat.Sandbox.Sprites, :suspend, fn _handle -> {:error, :unavailable} end)
      capture_provider()

      sweep(fn -> assert {0, 1, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert destroyed_names() == [sandbox.machine_name]
      assert Repo.reload!(sandbox).status == "terminated"
      assert [expired] = events(ctx.user.id, "sandbox.expired")
      assert expired.metadata["reason"] == "idle; suspend call failed"
    end

    test "a run spends at most @destroy_limit provider destroys across both passes", ctx do
      # Before stage 5b the cap sat on pass 2, which made every provider
      # destroy the reaper made. Pass 1 now destroys in the call, so an
      # uncapped sweep would fire one per abandoned row — the burst the
      # constraint was written against.
      limit = 25

      extra =
        for _ <- 1..limit do
          s = insert_sandbox(user_id: ctx.user.id, status: "ready")
          c = insert_conversation(user_id: ctx.user.id, sandbox: s, status: "idle")
          age(s, c, 60 * 24 * 83)
        end

      capture_provider()

      # 26 rows past the ceiling, 25 destroys, one deferred to the next run and
      # counted as neither expired nor refused.
      sweep(fn -> assert {0, ^limit, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert length(destroyed_names()) == limit

      all = [ctx.sandbox | extra]
      terminal = Enum.count(all, &(Repo.reload!(&1).status == "terminated"))
      assert terminal == limit
      assert Enum.count(all, &(Repo.reload!(&1).status == "ready")) == 1
    end

    test "a refused destroy records nothing and does not stop the sweep", ctx do
      other = insert_sandbox(user_id: ctx.user.id, status: "ready")
      other_conv = insert_conversation(user_id: ctx.user.id, sandbox: other, status: "idle")
      other = age(other, other_conv, 60 * 24 * 83)

      refuse_destroy_of(ctx.sandbox.id)
      capture_provider()

      # One reclaimed and one refused, counted apart. `expired` is graphed on
      # the finance board as "rows expired by the reaper", so a machine that is
      # still `ready`, still at the provider and still billing must not be in
      # it — otherwise an outage that refuses every destroy reports healthy
      # reclamation while nothing is reclaimed.
      sweep(fn -> assert {0, 1, 1} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert destroyed_names() == [other.machine_name]
      assert Repo.reload!(other).status == "terminated"

      # The refused one is untouched — the refusal here stands in for one the
      # protocol makes before it fences — and records no `sandbox.expired`,
      # because nothing happened to this tenant's machine. The next pass tries
      # again; a refusal that happened *after* the fence is
      # `sweep_fenced_teardowns/0`'s case.
      refused = Repo.reload!(ctx.sandbox)
      assert refused.status == "ready"
      assert Enum.map(events(ctx.user.id, "sandbox.expired"), & &1.resource_id) == [other.id]
    end
  end

  # ── site 4: the admin reap ────────────────────────────────────────────────

  describe "reaping a machine with no live server destroys it through the owner" do
    setup ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: sandbox,
          status: "idle"
        )

      no_servers()
      {:ok, sandbox: sandbox, conv: conv}
    end

    test "the machine dies in this call, and the thread stays resumable", ctx do
      expect_provider_sees_the_intent(ctx.sandbox)

      assert {:ok, :released} = Termination.reap_sandbox(ctx.sandbox.id)

      assert_received {:at_provider, name, status, transition, fenced_at}
      assert name == ctx.sandbox.machine_name
      assert status == "ready"
      assert transition == "destroying"
      assert fenced_at

      assert Repo.reload!(ctx.sandbox).status == "terminated"
      assert Repo.reload!(ctx.conv).status == "idle"
    end

    test "idle conversations bound to it do not make the reap a no-op", ctx do
      # A reap an operator clicked, or a suspension, on a machine whose
      # conversations are idle and serverless. That is the ordinary shape of a
      # runaway machine, and `:kept` would make /admin/sandboxes' Reap button
      # do nothing at all. Two conversations, for the same reason as the
      # reaper's case above: a co-tenant is what the fence keeps a machine for.
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox: ctx.sandbox,
        status: "idle"
      )

      capture_provider()
      assert {:ok, :released} = Termination.reap_sandbox(ctx.sandbox.id)
      assert destroyed_names() == [ctx.sandbox.machine_name]
      assert Repo.reload!(ctx.sandbox).status == "terminated"
    end

    test "a persistent home is reaped like anything else", ctx do
      {:ok, _} = Conversations.update_sandbox(ctx.sandbox, %{mode: "persistent"})
      capture_provider()

      assert {:ok, :released} = Termination.reap_sandbox(ctx.sandbox.id)
      assert destroyed_names() == [ctx.sandbox.machine_name]
      assert Repo.reload!(ctx.sandbox).status == "terminated"
    end

    test "an admin's id folds to `admin` on both machine events, and is kept on the admin one",
         ctx do
      admin = insert_verified_user()
      capture_provider()

      assert {:ok, :released} =
               Termination.reap_sandbox(ctx.sandbox.id, admin_user_id: admin.id)

      assert [requested] = events(ctx.user.id, "sandbox.teardown_requested")
      assert [destroyed] = events(ctx.user.id, "sandbox.destroyed")

      # ADR 0013 reserves `admin:<operator_id>` for account deletion; the
      # operator's identity is in `admin.sandbox.reaped`, which stays the one
      # place it is recorded (#2255 decision 4).
      assert requested.actor == "admin"
      assert destroyed.actor == "admin"
      assert destroyed.metadata["reason"] == "admin_reap"

      admin_events =
        Audit._unsafe_list_recent_admin(50)
        |> Enum.filter(&(&1.event_type == "admin.sandbox.reaped"))

      assert [event] = admin_events
      assert event.actor_user_id == admin.id
      assert event.metadata["outcome"] == "released"
    end

    test "a suspension's reaps stay the reaper's own work and leave no admin event", ctx do
      capture_provider()

      assert 1 = Termination.reap_all_for_user(ctx.user.id)

      assert [destroyed] = events(ctx.user.id, "sandbox.destroyed")
      assert destroyed.actor == "system:sandbox_reaper"

      assert Audit._unsafe_list_recent_admin(50)
             |> Enum.filter(&(&1.event_type == "admin.sandbox.reaped")) == []
    end

    test "a machine with a live server still goes through that server", ctx do
      # Unchanged by this stage and asserted so it stays that way: the reap of
      # a live conversation is a terminate through its server, which has gone
      # through the owner since 5a. `reap_sandbox/2` calls
      # `terminate_conversation/2` locally, so Mimic cannot stand in front of
      # it; the server is a probe that answers the call the way a real one does.
      {:ok, probe} = GenServer.start_link(OkProbe, %{})
      stub(ConversationServer, :whereis, fn id -> if id == ctx.conv.id, do: probe, else: nil end)
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      assert {:ok, :terminated} = Termination.reap_sandbox(ctx.sandbox.id)
      assert Repo.reload!(ctx.sandbox).status == "ready"
    end

    test "a refused destroy is reported and is not counted by a suspension sweep", ctx do
      other = insert_sandbox(user_id: ctx.user.id, status: "ready")
      refuse_destroy_of(ctx.sandbox.id)
      capture_provider()

      capture_log(fn ->
        assert {:error, :sandbox_unavailable} = Termination.reap_sandbox(ctx.sandbox.id)
        assert 1 = Termination.reap_all_for_user(ctx.user.id)
      end)

      assert destroyed_names() == [other.machine_name]
      assert Repo.reload!(ctx.sandbox).status == "ready"

      # Nothing succeeded, so nothing was recorded — `audit_reap/3`'s rule,
      # unchanged.
      assert Audit._unsafe_list_recent_admin(50)
             |> Enum.filter(&(&1.event_type == "admin.sandbox.reaped")) == []
    end
  end

  # ── two forced teardowns, one machine ─────────────────────────────────────

  describe "two of these sites racing for one machine" do
    test "an admin reap and a reaper expiry destroy it once between them", ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")
      conv = insert_conversation(user_id: ctx.user.id, sandbox: sandbox, status: "idle")
      no_servers()
      test = self()

      # The winner holds its lease across the provider call for long enough
      # that the loser is certainly inside `Destroy`'s wait when it finishes —
      # well under the five-second bound, so the loser answers from the row
      # rather than timing out.
      stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
        send(test, {:destroyed, handle.name})
        Process.sleep(300)
        :ok
      end)

      capture_log(fn ->
        reap = Task.async(fn -> Termination.reap_sandbox(sandbox.id) end)

        expiry =
          Task.async(fn ->
            Termination._unsafe_destroy_machine(sandbox.id,
              actor: "system:sandbox_reaper",
              destroy_reason: :max_lifetime,
              reason: "sandbox_expired",
              terminating_conversation_id: nil
            )
          end)

        assert {:ok, _} = Task.await(reap, 15_000)
        assert {:ok, _} = Task.await(expiry, 15_000)
      end)

      # The thread is not part of the race, only of the shape: a machine two
      # forced teardowns arrive at is normally one that still has conversations
      # on it.
      assert Repo.reload!(conv).status == "idle"

      assert destroyed_names() == [sandbox.machine_name],
             "the machine was destroyed more than once: the lease did not serialize " <>
               "two forced teardowns of one machine"

      assert [_one] = events(ctx.user.id, "sandbox.destroyed")
      assert Repo.reload!(sandbox).status == "terminated"
      assert Repo.reload!(sandbox).transition == nil
    end
  end
end
