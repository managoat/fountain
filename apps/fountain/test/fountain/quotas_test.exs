defmodule Fountain.QuotasTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Quotas

  describe "active_sandbox_count/2" do
    test "counts only the given tenant's sandboxes" do
      user = insert_active_user()
      other = insert_active_user()

      insert_sandbox(user_id: user.id, status: "ready")
      insert_sandbox(user_id: user.id, status: "pending")
      insert_sandbox(user_id: other.id, status: "ready")

      assert Quotas.active_sandbox_count(user.id) == 2
      assert Quotas.active_sandbox_count(other.id) == 1
    end

    test "pending and starting count — a sprite bills from provisioning, not from ready" do
      user = insert_active_user()

      for status <- ~w(pending starting ready) do
        insert_sandbox(user_id: user.id, status: status)
      end

      assert Quotas.active_sandbox_count(user.id) == 3
    end

    test "terminated and failed do not count" do
      user = insert_active_user()

      insert_sandbox(user_id: user.id, status: "ready")
      insert_sandbox(user_id: user.id, status: "terminated")
      insert_sandbox(user_id: user.id, status: "failed")

      assert Quotas.active_sandbox_count(user.id) == 1
    end

    test "suspended does not count — a parked sprite is not compute (0017)" do
      # Otherwise five abandoned conversations would permanently lock a
      # default-cap tenant out of starting anything. Waking a suspended
      # sandbox re-runs the gate (Conversations.wake_suspended_sandbox/2).
      user = insert_active_user()

      insert_sandbox(user_id: user.id, status: "ready")
      insert_sandbox(user_id: user.id, status: "suspended")

      assert Quotas.active_sandbox_count(user.id) == 1
    end

    test "exclude: leaves the named sandbox out" do
      user = insert_active_user()
      keep = insert_sandbox(user_id: user.id, status: "ready")
      insert_sandbox(user_id: user.id, status: "ready")

      assert Quotas.active_sandbox_count(user.id) == 2
      assert Quotas.active_sandbox_count(user.id, exclude: keep.id) == 1
    end

    test "is zero for a tenant with no sandboxes" do
      assert Quotas.active_sandbox_count(insert_active_user().id) == 0
    end
  end

  describe "sandbox_limit/1" do
    # The balance rule (ADR 0031): clamp(balance / reserve, floor, ceiling),
    # with reserve $2, floor 2 and ceiling 20 in test config.
    defp with_balance(user, cents) do
      {:ok, _} =
        Fountain.Credits.grant(user.id, cents, "purchase", idempotency_key: "q-#{user.id}")

      user
    end

    # Every verified account holds the $5 opening grant: the floor. Spent to
    # nothing, it funds nothing — the gate refuses first, so the cap is never
    # the answer that account hears.
    test "the opening grant funds the floor; nothing at all funds nothing" do
      user = insert_active_user()
      assert Quotas.sandbox_limit(user.id) == 2

      {:ok, _} =
        Fountain.Credits.debit(user.id, 1_000, "burn_turn", idempotency_key: "drain-#{user.id}")

      assert Quotas.sandbox_limit(user.id) == 0
    end

    test "the cap follows the balance, one sandbox per reserve" do
      assert Quotas.sandbox_limit(with_balance(insert_active_user(), 1_000).id) == 7
      assert Quotas.sandbox_limit(with_balance(insert_active_user(), 1_199).id) == 8
      assert Quotas.sandbox_limit(with_balance(insert_active_user(), 100).id) == 3
    end

    test "the ceiling bounds it however large the balance" do
      assert Quotas.sandbox_limit(with_balance(insert_active_user(), 100_000).id) == 20
    end

    # Billing off is covered in credits_enforcement_test (async: false): it
    # flips global config, which an async module must not do.
    test "a comped account gets the ceiling" do
      {:ok, comped} = Fountain.Billing.comp_account(insert_active_user())
      assert Quotas.sandbox_limit(comped.id) == 20
    end

    test "an override beats the balance, in either direction" do
      up = insert_active_user()
      {:ok, up} = Fountain.Accounts.update_sandbox_limit(up, 25)
      assert Quotas.sandbox_limit(up.id) == 25

      down = with_balance(insert_active_user(), 100_000)
      {:ok, down} = Fountain.Accounts.update_sandbox_limit(down, 1)
      assert Quotas.sandbox_limit(down.id) == 1
    end

    test "an override of zero is an override, not an absent one" do
      user = with_balance(insert_active_user(), 100_000)
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 0)
      assert Quotas.sandbox_limit(user.id) == 0
    end

    test "clearing the override hands the cap back to the balance" do
      user = with_balance(insert_active_user(), 1_000)
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 1)
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, nil)
      assert Quotas.sandbox_limit(user.id) == 7
    end

    test "an unknown user funds nothing rather than being unlimited" do
      assert Quotas.sandbox_limit(Ecto.UUID.generate()) == 0
    end
  end

  # The fleet ceiling lives in `quotas_fleet_ceiling_test.exs`, which is
  # `async: false`. It has to be: the only way to test a different ceiling is
  # to write the global `:sandboxes` config, and an async module that does
  # that changes the ceiling for every test running beside it.

  describe "sandbox_limit_for/1" do
    # The admin table renders it per row and must not query per row, so it has
    # to agree with the querying version for every combination that matters.
    test "agrees with sandbox_limit/1 without touching the database" do
      for cents <- [0, 1_000, 5_000, 100_000],
          override <- [nil, 0, 25] do
        user = insert_active_user()

        if cents > 0,
          do:
            {:ok, _} =
              Fountain.Credits.grant(user.id, cents, "purchase", idempotency_key: "q-#{user.id}")

        {:ok, user} =
          Fountain.Accounts.update_sandbox_limit(Fountain.Repo.reload!(user), override)

        assert Quotas.sandbox_limit_for(user) == Quotas.sandbox_limit(user.id),
               "cents=#{cents} override=#{inspect(override)}"
      end
    end

    test "an unfunded account is 0 on both, not the floor (#1127)" do
      user = insert_active_user()

      {:ok, _} =
        Fountain.Credits.debit(user.id, 1_000, "burn_turn", idempotency_key: "drain-#{user.id}")

      user = Fountain.Repo.reload!(user)
      assert Quotas.sandbox_limit_for(user) == 0
      assert Quotas.sandbox_limit(user.id) == 0

      {:ok, comped} = Fountain.Billing.comp_account(user)
      assert Quotas.sandbox_limit_for(comped) == Quotas.sandbox_limit(comped.id)

      {:ok, overridden} = Fountain.Accounts.update_sandbox_limit(user, 3)
      assert Quotas.sandbox_limit_for(overridden) == 3
    end
  end

  describe "check_sandbox_quota/2" do
    test "passes below the cap" do
      user = insert_active_user()
      insert_sandbox(user_id: user.id, status: "ready")

      assert :ok = Quotas.check_sandbox_quota(user.id)
    end

    # Unlike the block above, these derive the cap rather than writing it out:
    # what is under test is the counting and the exclusion, not which number
    # the catalog holds. Pinning it here only makes every future cap change
    # break six unrelated tests.
    test "denies at the cap" do
      user = insert_active_user()
      limit = Quotas.sandbox_limit(user.id)
      for _ <- 1..limit, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, {:sandbox_quota_exceeded, %{count: ^limit, limit: ^limit}}} =
               Quotas.check_sandbox_quota(user.id)
    end

    test "denies above the cap" do
      user = insert_active_user()
      limit = Quotas.sandbox_limit(user.id)
      over = limit + 2
      for _ <- 1..over, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, {:sandbox_quota_exceeded, %{count: ^over, limit: ^limit}}} =
               Quotas.check_sandbox_quota(user.id)
    end

    test "one tenant at its cap does not affect another" do
      user = insert_active_user()
      other = insert_active_user()

      for _ <- 1..Quotas.sandbox_limit(user.id),
          do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, _} = Quotas.check_sandbox_quota(user.id)
      assert :ok = Quotas.check_sandbox_quota(other.id)
    end

    test "exclude: lets a replacement through at exactly the cap" do
      user = insert_active_user()

      [replacing | _] =
        for _ <- 1..Quotas.sandbox_limit(user.id),
            do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, _} = Quotas.check_sandbox_quota(user.id)
      assert :ok = Quotas.check_sandbox_quota(user.id, exclude: replacing.id)
    end

    test "a raised cap admits more" do
      user = insert_active_user()
      limit = Quotas.sandbox_limit(user.id)
      for _ <- 1..limit, do: insert_sandbox(user_id: user.id, status: "ready")
      assert {:error, _} = Quotas.check_sandbox_quota(user.id)

      {:ok, _} = Fountain.Accounts.update_sandbox_limit(user, limit + 5)
      assert :ok = Quotas.check_sandbox_quota(user.id)
    end

    test "a cap of zero denies everything — the lever for shutting off abuse" do
      user = insert_active_user()
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 0)

      assert {:error, {:sandbox_quota_exceeded, %{count: 0, limit: 0}}} =
               Quotas.check_sandbox_quota(user.id)
    end
  end

  describe "with_sandbox_reservation/3 (#330)" do
    # The cross-connection serialization itself rests on
    # pg_advisory_xact_lock and cannot be observed under the SQL sandbox
    # (every allowed process shares one transaction). What these pin is the
    # transactional composition: check + insert commit or roll back as one.

    alias Fountain.Quotas

    test "creates the row when below the cap" do
      user = insert_active_user()

      assert {:ok, sandbox} =
               Quotas.with_sandbox_reservation(user.id, fn ->
                 {:ok, insert_sandbox(user_id: user.id, status: "pending")}
               end)

      assert Quotas.active_sandbox_count(user.id) == 1
      assert sandbox.user_id == user.id
    end

    test "refuses at the cap and creates nothing" do
      user = insert_active_user()
      limit = Quotas.sandbox_limit(user.id)
      for _ <- 1..limit, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, {:sandbox_quota_exceeded, %{count: ^limit, limit: ^limit}}} =
               Quotas.with_sandbox_reservation(user.id, fn ->
                 flunk("fun must not run once the quota refuses")
               end)

      assert Quotas.active_sandbox_count(user.id) == limit
    end

    test "a failure in fun rolls the reservation back" do
      user = insert_active_user()

      assert {:error, :boom} =
               Quotas.with_sandbox_reservation(user.id, fn ->
                 insert_sandbox(user_id: user.id, status: "pending")
                 {:error, :boom}
               end)

      # The row created inside the reservation is gone with it.
      assert Quotas.active_sandbox_count(user.id) == 0
    end

    test "honours the :exclude option the wake path needs" do
      user = insert_active_user()

      sandboxes =
        for _ <- 1..Quotas.sandbox_limit(user.id),
            do: insert_sandbox(user_id: user.id, status: "ready")

      replacing = hd(sandboxes)

      assert {:ok, _} =
               Quotas.with_sandbox_reservation(user.id, [exclude: replacing.id], fn ->
                 {:ok, insert_sandbox(user_id: user.id, status: "pending")}
               end)
    end
  end

  describe "a machine on its way up (ADR 0058 stage 7a)" do
    # `active_sandboxes/0` renders `Machines.Lease.live?/2` in SQL — the one
    # copy of that rule outside the predicate, because this is a `count(*)`
    # under an advisory lock and folding a predicate over every candidate row
    # would turn a counter into a scan. `quotas.ex` says this file pins the two
    # halves against the predicate so the copy cannot drift the way stage 6a's
    # three copies had; until round 1 of #2368 it said so and did not.
    setup do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "suspended")
      {:ok, epoch} = Lease.claim(sandbox.id, "fountain@test", 60_000)
      {:ok, user: user, sandbox: sandbox, epoch: epoch}
    end

    defp stamp_resuming(ctx),
      do: Lease.cas_update(ctx.sandbox.id, ctx.epoch, transition: "resuming")

    test "counts while the reservation's lease is live", ctx do
      assert Quotas.active_sandbox_count(ctx.user.id) == 0
      {:ok, _} = stamp_resuming(ctx)

      assert Quotas.active_sandbox_count(ctx.user.id) == 1
      assert Quotas.fleet_count() >= 1
    end

    test "and stops the moment that lease lapses, exactly as live?/2 decides", ctx do
      {:ok, _} = stamp_resuming(ctx)

      Repo.update_all(
        from(s in Sandbox, where: s.id == ^ctx.sandbox.id),
        set: [lease_until: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      # The two answers are asserted against each other, not against a literal:
      # that is what makes this a pin on the copy rather than a second opinion.
      refute Lease.live?(Repo.reload!(ctx.sandbox))
      assert Quotas.active_sandbox_count(ctx.user.id) == 0
    end

    test "a holder-less deadline is not a lease, here either", ctx do
      {:ok, _} = stamp_resuming(ctx)

      Repo.update_all(
        from(s in Sandbox, where: s.id == ^ctx.sandbox.id),
        set: [lease_node: nil]
      )

      refute Lease.live?(Repo.reload!(ctx.sandbox))
      assert Quotas.active_sandbox_count(ctx.user.id) == 0
    end

    test "a suspended row with no stamp counts for nothing", ctx do
      refute Quotas.active_sandbox_count(ctx.user.id) == 1
      assert Quotas.active_sandbox_count(ctx.user.id) == 0
    end
  end
end
