defmodule Fountain.Machines.LeaseTest do
  @moduledoc """
  The lease protocol of ADR 0058, stage 3.

  The cases that need two real connections run under `unboxed_run/2`, because
  the SQL sandbox puts every process on one transaction and a lock taken there
  is a lock the whole test already holds — contention could not be observed and
  a rollback would not release anything. Those tests commit, so each one
  deletes what it made.
  """
  use Fountain.DataCase, async: false

  alias Fountain.Accounts.User
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease

  # `Fountain.Conversations`' per-sandbox advisory namespace. The lease reuses
  # `with_sandbox_lock/2`, so a test that takes this key by hand blocks it.
  @sandbox_lock_namespace 4316

  @ttl_ms 60_000

  describe "on one connection" do
    setup do
      %{sandbox: insert_sandbox(status: "pending"), node: "fountain@test-a"}
    end

    test "a claim takes the next epoch and a release keeps it", ctx do
      assert {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)

      held = Repo.get!(Sandbox, ctx.sandbox.id)
      assert held.lease_epoch == 1
      assert held.lease_node == ctx.node
      assert held.lease_until

      assert :ok = Lease.release(ctx.sandbox.id, 1)

      released = Repo.get!(Sandbox, ctx.sandbox.id)
      assert released.lease_epoch == 1
      refute released.lease_node
      refute released.lease_until

      # Strictly higher, never reused: the released holder's writes must stay
      # dead even though it gave the lease up politely.
      assert {:ok, 2} = Lease.claim(ctx.sandbox.id, "fountain@test-b", @ttl_ms)
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, %{status: "failed"})
    end

    test "a claim on a row that is not there says so", ctx do
      assert {:error, :not_found} = Lease.claim(Ecto.UUID.generate(), ctx.node, @ttl_ms)
    end

    test "the owner writes state and finalizes a transition through its epoch", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)

      assert {:ok, parking} =
               Lease.cas_update(ctx.sandbox.id, epoch, %{
                 transition: "parking",
                 transition_reason: "idle"
               })

      assert parking.transition == "parking"
      assert parking.transition_reason == "idle"
      assert parking.status == "pending"

      assert {:ok, parked} =
               Lease.cas_update(ctx.sandbox.id, epoch, %{
                 status: "suspended",
                 transition: nil,
                 transition_reason: nil
               })

      assert parked.status == "suspended"
      refute parked.transition
      assert Repo.get!(Sandbox, ctx.sandbox.id).status == "suspended"
    end

    test "a stale epoch writes nothing at all", ctx do
      assert {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)
      before = Repo.get!(Sandbox, ctx.sandbox.id)

      # Epoch 0 is what every row starts at, so it is the epoch a caller that
      # never held the lease would quote.
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 0, %{status: "failed"})
      assert Repo.get!(Sandbox, ctx.sandbox.id) == before

      assert {:error, :lost} = Lease.renew(ctx.sandbox.id, 0, @ttl_ms)
      assert {:error, :lost} = Lease.release(ctx.sandbox.id, 0)
      assert Repo.get!(Sandbox, ctx.sandbox.id) == before
    end

    test "takeover waits for expiry and then supersedes the old holder", ctx do
      now = DateTime.utc_now()
      assert {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms, now)

      # A live lease is never taken, whatever the claimant believes about the
      # holder. Expiry is the only hand-over.
      assert {:error, {:held, node, until}} =
               Lease.take_over(ctx.sandbox.id, "fountain@test-b", @ttl_ms, now)

      assert node == ctx.node
      assert DateTime.compare(until, now) == :gt
      assert Repo.get!(Sandbox, ctx.sandbox.id).lease_node == ctx.node

      # The holder keeps it as long as it renews.
      midway = DateTime.add(now, div(@ttl_ms, 2), :millisecond)
      assert :ok = Lease.renew(ctx.sandbox.id, 1, @ttl_ms, midway)

      assert {:error, {:held, _, _}} =
               Lease.take_over(ctx.sandbox.id, "fountain@test-b", @ttl_ms, midway)

      expired = DateTime.add(midway, @ttl_ms + 1_000, :millisecond)
      assert {:ok, 2} = Lease.take_over(ctx.sandbox.id, "fountain@test-b", @ttl_ms, expired)

      # Everything the old holder does from here is invisible.
      assert {:error, :lost} = Lease.renew(ctx.sandbox.id, 1, @ttl_ms, expired)
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, %{status: "terminated"})
      assert Repo.get!(Sandbox, ctx.sandbox.id).status == "pending"
      assert Repo.get!(Sandbox, ctx.sandbox.id).lease_node == "fountain@test-b"
    end

    test "an expired lease still writes until somebody takes it over", ctx do
      now = DateTime.utc_now()
      assert {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms, now)
      expired = DateTime.add(now, @ttl_ms + 1_000, :millisecond)

      # The clock lapsed and nobody claimed. The epoch is still this holder's,
      # so the work it started still finishes — the CAS buys invisibility
      # after a takeover, not a deadline of its own. Pinned because a later
      # stage reading `lease_until` as an authorization would be wrong.
      assert {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, %{transition: "destroying"})
      assert :ok = Lease.renew(ctx.sandbox.id, 1, @ttl_ms, expired)

      # Once it really has expired and been taken, the same write is gone.
      later = DateTime.add(expired, 2 * @ttl_ms, :millisecond)
      assert {:ok, 2} = Lease.take_over(ctx.sandbox.id, "fountain@test-b", @ttl_ms, later)
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, %{transition: nil})
      assert Repo.get!(Sandbox, ctx.sandbox.id).transition == "destroying"
    end

    test "cas_update refuses a value or a key the owner may not write", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)
      before = Repo.get!(Sandbox, ctx.sandbox.id)

      refusals = [
        {%{status: "exploded"}, {:invalid, :status}},
        {%{status: nil}, {:invalid, :status}},
        {%{transition: "melting"}, {:invalid, :transition}},
        {%{transition_reason: 17}, {:invalid, :transition_reason}},
        {%{terminated_at: "whenever"}, {:invalid, :terminated_at}},
        # Not the owner's to write, however plausible the column.
        {%{mode: "persistent"}, {:invalid, :mode}},
        {%{lease_epoch: 99}, {:invalid, :lease_epoch}},
        {%{user_id: Ecto.UUID.generate()}, {:invalid, :user_id}},
        # An owner's write is built in code, never forwarded from a caller's map.
        {%{"status" => "ready"}, {:invalid, "status"}},
        {%{}, {:invalid, :attrs}}
      ]

      for {attrs, reason} <- refusals do
        assert Lease.cas_update(ctx.sandbox.id, epoch, attrs) == {:error, reason}
      end

      assert Repo.get!(Sandbox, ctx.sandbox.id) == before
    end

    test "an enclosing transaction is refused by every function", ctx do
      assert {:ok, :unchanged} =
               Repo.transaction(fn ->
                 assert {:error, :transaction_open} =
                          Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)

                 assert {:error, :transaction_open} =
                          Lease.take_over(ctx.sandbox.id, ctx.node, @ttl_ms)

                 assert {:error, :transaction_open} = Lease.renew(ctx.sandbox.id, 0, @ttl_ms)
                 assert {:error, :transaction_open} = Lease.release(ctx.sandbox.id, 0)

                 assert {:error, :transaction_open} =
                          Lease.cas_update(ctx.sandbox.id, 0, %{status: "ready"})

                 :unchanged
               end)

      assert Repo.get!(Sandbox, ctx.sandbox.id).lease_epoch == 0
    end
  end

  describe "across connections" do
    test "two claimants contend and exactly one takes the epoch" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()

        try do
          now = DateTime.utc_now()

          claimants =
            for node <- ["fountain@test-a", "fountain@test-b"] do
              independent(fn ->
                receive do
                  :go -> :ok
                after
                  10_000 -> raise "claim barrier timed out"
                end

                Lease.claim(tenant.sandbox.id, node, @ttl_ms, now)
              end)
            end

          try do
            # Both connections are open before either claims, so the winner is
            # decided by the lock rather than by task startup.
            for claimant <- claimants do
              assert_receive {:backend, pid, _backend}, 5_000
              assert pid in Enum.map(claimants, & &1.pid)
              _ = claimant
            end

            for claimant <- claimants, do: send(claimant.pid, :go)
            results = Enum.map(claimants, &Task.await(&1, 15_000))

            assert Enum.count(results, &match?({:ok, 1}, &1)) == 1
            assert Enum.count(results, &match?({:error, {:held, _, _}}, &1)) == 1

            # Advanced by exactly one: the loser saw the winner's row, not the
            # row as it was before the winner ran.
            assert Repo.get!(Sandbox, tenant.sandbox.id).lease_epoch == 1
          after
            for claimant <- claimants, do: Task.shutdown(claimant, :brutal_kill)
          end
        after
          discard(tenant)
        end
      end)
    end

    test "a claim waits on the per-sandbox advisory lock" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()
        owner = self()

        blocker =
          independent(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
                @sandbox_lock_namespace,
                :erlang.phash2(tenant.sandbox.id)
              ])

              send(owner, :locked)

              receive do
                :commit -> :ok
              after
                10_000 -> raise "advisory lock release timed out"
              end
            end)
          end)

        try do
          assert_receive {:backend, blocker_pid, _}, 5_000
          assert blocker_pid == blocker.pid
          assert_receive :locked, 5_000

          waiting =
            independent(fn -> Lease.claim(tenant.sandbox.id, "fountain@test-b", @ttl_ms) end)

          try do
            assert_receive {:backend, waiting_pid, waiting_backend}, 5_000
            assert waiting_pid == waiting.pid

            # Proof it serialized rather than merely finished second: PostgreSQL
            # reports the claim's backend waiting on another one.
            await_blocked(waiting_backend, System.monotonic_time(:millisecond) + 5_000)
            assert Task.yield(waiting, 0) == nil

            send(blocker.pid, :commit)
            assert {:ok, :ok} = Task.await(blocker, 15_000)
            assert {:ok, 1} = Task.await(waiting, 15_000)
          after
            Task.shutdown(waiting, :brutal_kill)
          end
        after
          Task.shutdown(blocker, :brutal_kill)
          discard(tenant)
        end
      end)
    end

    test "a database fault answers, and leaves no write and no lock behind" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()

        try do
          fault_on(tenant.sandbox.id)
          before = Repo.get!(Sandbox, tenant.sandbox.id)

          # A cancelled statement is an answer, not an exception the owner has
          # to rescue at every call site (the #2309 shape).
          assert {:error, {:database, code}} =
                   Lease.claim(tenant.sandbox.id, "fountain@test-a", @ttl_ms)

          assert code == :query_canceled
          assert Repo.get!(Sandbox, tenant.sandbox.id) == before

          drop_fault()

          # The advisory lock went back with the rollback. On another
          # connection this blocks forever if it did not.
          second =
            independent(fn -> Lease.claim(tenant.sandbox.id, "fountain@test-b", @ttl_ms) end)

          try do
            assert_receive {:backend, _, _}, 5_000
            assert {:ok, 1} = Task.await(second, 15_000)
          after
            Task.shutdown(second, :brutal_kill)
          end
        after
          drop_fault()
          discard(tenant)
        end
      end)
    end
  end

  # ── unboxed helpers ───────────────────────────────────────────────────────

  # A committed user and sandbox, kept as small as the foreign keys allow so
  # `discard/1` can take them all back out again.
  defp committed_tenant do
    user =
      Repo.insert!(%User{
        email: "machine-lease-#{Ecto.UUID.generate()}@example.test",
        credit_balance_cents: 0
      })

    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(%{
        machine_name: "lease-#{Ecto.UUID.generate()}",
        status: "pending",
        user_id: user.id
      })
      |> Repo.insert!()

    %{user: user, sandbox: sandbox}
  end

  defp discard(%{user: user, sandbox: sandbox}) do
    Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
    Repo.delete!(sandbox)
    Repo.delete!(user)
  end

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "no PostgreSQL advisory-lock wait observed"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end

  # Scoped to the one row: a trigger that raised for every sandbox would fail
  # whatever else the suite is doing to the table.
  defp fault_on(sandbox_id) do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION fountain_lease_fault() RETURNS trigger AS $fn$
    BEGIN
      IF NEW.id = '#{sandbox_id}'::uuid THEN
        RAISE EXCEPTION 'canceling statement due to statement timeout'
          USING ERRCODE = '57014';
      END IF;
      RETURN NEW;
    END;
    $fn$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER fountain_lease_fault BEFORE UPDATE ON sandboxes
    FOR EACH ROW EXECUTE FUNCTION fountain_lease_fault()
    """)
  end

  defp drop_fault do
    Repo.query!("DROP TRIGGER IF EXISTS fountain_lease_fault ON sandboxes")
    Repo.query!("DROP FUNCTION IF EXISTS fountain_lease_fault()")
  end
end
