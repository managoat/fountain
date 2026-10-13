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
      # Otherwise abandoned conversations would permanently fill the fleet.
      # Waking a suspended sandbox re-runs the gate (Machines.Resume).
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

  describe "check_fleet_ceiling/1" do
    test "passes below the ceiling" do
      fill_fleet(1)
      assert :ok = Quotas.check_fleet_ceiling()
    end

    test "refuses at the ceiling, whoever holds the slots" do
      fill_fleet()
      assert {:error, :fleet_full} = Quotas.check_fleet_ceiling()
    end

    test "exclude: lets a replacement through at exactly the ceiling" do
      [replacing | _] = fill_fleet()
      assert {:error, :fleet_full} = Quotas.check_fleet_ceiling()
      assert :ok = Quotas.check_fleet_ceiling(exclude: replacing.id)
    end

    test "a suspended sandbox holds no slot" do
      [parked | _] = fill_fleet()
      parked |> Ecto.Changeset.change(status: "suspended") |> Repo.update!()
      assert :ok = Quotas.check_fleet_ceiling()
    end
  end

  # A different ceiling lives in `quotas_fleet_ceiling_test.exs`, which is
  # `async: false`: the only way to test one is to write the global
  # `:sandboxes` config.

  describe "with_sandbox_reservation/2 (#330)" do
    # The cross-connection serialization itself rests on
    # pg_advisory_xact_lock and cannot be observed under the SQL sandbox
    # (every allowed process shares one transaction). What these pin is the
    # transactional composition: check + insert commit or roll back as one.

    alias Fountain.Quotas

    test "creates the row when below the ceiling" do
      user = insert_active_user()

      assert {:ok, sandbox} =
               Quotas.with_sandbox_reservation(fn ->
                 {:ok, insert_sandbox(user_id: user.id, status: "pending")}
               end)

      assert Quotas.active_sandbox_count(user.id) == 1
      assert sandbox.user_id == user.id
    end

    test "refuses at the ceiling and creates nothing" do
      fill_fleet()
      before = Quotas.fleet_count()

      assert {:error, :fleet_full} =
               Quotas.with_sandbox_reservation(fn ->
                 flunk("fun must not run once the ceiling refuses")
               end)

      assert Quotas.fleet_count() == before
    end

    test "a failure in fun rolls the reservation back" do
      user = insert_active_user()

      assert {:error, :boom} =
               Quotas.with_sandbox_reservation(fn ->
                 insert_sandbox(user_id: user.id, status: "pending")
                 {:error, :boom}
               end)

      # The row created inside the reservation is gone with it.
      assert Quotas.active_sandbox_count(user.id) == 0
    end

    test "honours the :exclude option the wake path needs" do
      user = insert_active_user()
      [replacing | _] = fill_fleet()

      assert {:ok, _} =
               Quotas.with_sandbox_reservation([exclude: replacing.id], fn ->
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
