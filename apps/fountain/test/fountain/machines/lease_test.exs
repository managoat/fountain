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

    test "live?/2 is what a claim decides on, read from the row", ctx do
      # The one definition of "somebody holds this machine" since stage 6a
      # (it replaced two SQL `where` clauses and an Elixir predicate). What
      # makes it trustworthy is that `claim/4` refuses exactly when this says
      # true, so the readers and the claimant cannot disagree.
      now = DateTime.utc_now()
      refute Lease.live?(Repo.get!(Sandbox, ctx.sandbox.id), now)

      {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms, now)
      held = Repo.get!(Sandbox, ctx.sandbox.id)

      assert Lease.live?(held, now)

      assert {:error, {:held, _, _}} =
               Lease.claim(ctx.sandbox.id, "fountain@test-b", @ttl_ms, now)

      # And exactly when it says false. Past the TTL both agree the lease is
      # gone, which is the only way a lease is ever handed over.
      later = DateTime.add(now, @ttl_ms + 1_000, :millisecond)
      refute Lease.live?(held, later)
      assert {:ok, 2} = Lease.claim(ctx.sandbox.id, "fountain@test-b", @ttl_ms, later)
    end

    test "live?/2 needs a holder, not only a deadline", ctx do
      # `release/2` clears both columns and keeps the epoch, so a released
      # lease reads as unheld. A `lease_until` with no `lease_node` is
      # unreachable through this module and still must not read as held — it
      # is the half the SQL copies of this rule had dropped.
      {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)
      :ok = Lease.release(ctx.sandbox.id, 1)
      refute Lease.live?(Repo.get!(Sandbox, ctx.sandbox.id))

      forged =
        Repo.get!(Sandbox, ctx.sandbox.id)
        |> Ecto.Changeset.change(
          lease_node: nil,
          lease_until: DateTime.add(DateTime.utc_now(), 60_000, :millisecond)
        )
        |> Repo.update!()

      refute Lease.live?(forged)
    end

    test "live?/2 refuses a map that is missing either column" do
      # Round 1, locks review. The first version matched `%{lease_node: nil}`
      # and `%{lease_until: nil}` in turn, so a map *missing* the holder key
      # fell through to the deadline clause and read as held on the deadline
      # alone — the drift this function exists to remove, back as a map shape,
      # and reachable through the `select` maps its callers hand-write.
      future = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)

      assert_raise FunctionClauseError, fn -> Lease.live?(%{lease_until: future}) end
      assert_raise FunctionClauseError, fn -> Lease.live?(%{lease_node: "fountain@a"}) end
      assert_raise FunctionClauseError, fn -> Lease.live?(%{}) end

      assert Lease.live?(%{lease_node: "fountain@a", lease_until: future})
      refute Lease.live?(%{lease_node: nil, lease_until: future})
    end

    test "live?/2 takes a selected map, not only a row", ctx do
      # `SandboxResetReconciler`'s sweep selects the two columns beside the id
      # rather than loading rows, and asks the same predicate.
      {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)

      selected =
        Repo.one(
          from s in Sandbox,
            where: s.id == ^ctx.sandbox.id,
            select: %{id: s.id, lease_node: s.lease_node, lease_until: s.lease_until}
        )

      assert Lease.live?(selected)
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

      # Epoch 0 is the default on every row and epoch 1 is the first a claim
      # ever hands out, so 0 is superseded here as well as never held. The
      # never-held half is its own test below; this one is the ordinary
      # overtaken-owner case.
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

    test "epoch 0 is not a lease anybody took", ctx do
      before = Repo.get!(Sandbox, ctx.sandbox.id)
      assert before.lease_epoch == 0

      # Every row starts at epoch 0 with no holder. If the epoch alone were the
      # guard, a caller that had never claimed could renew a lease into
      # existence — leaving `lease_until` set with `lease_node` nil, which
      # `live?/2` reads as held and which no node can then claim for a whole
      # TTL. Refused before the query: claims start at 1.
      assert {:error, :lost} = Lease.renew(ctx.sandbox.id, 0, @ttl_ms)
      assert {:error, :lost} = Lease.release(ctx.sandbox.id, 0)
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 0, %{status: "ready"})
      assert Repo.get!(Sandbox, ctx.sandbox.id) == before

      # And the machine is still claimable, which is the point.
      assert {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)
    end

    test "a release cannot be undone by a renew that lands after it", ctx do
      assert {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)
      assert :ok = Lease.release(ctx.sandbox.id, 1)

      # `release/2` keeps the epoch on purpose, so the epoch stays matchable.
      # A renew from the surrendered holder — stage 4's idle-stop racing its
      # own heartbeat — must not re-arm the lease it just gave up.
      assert {:error, :lost} = Lease.renew(ctx.sandbox.id, 1, @ttl_ms)
      assert {:error, :lost} = Lease.release(ctx.sandbox.id, 1)
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, %{status: "ready"})

      released = Repo.get!(Sandbox, ctx.sandbox.id)
      refute released.lease_until
      refute released.lease_node
      assert released.status == "pending"

      assert {:ok, 2} = Lease.claim(ctx.sandbox.id, "fountain@next", @ttl_ms)
    end

    test "cas_update does not revive a retired machine", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)
      assert {:ok, _} = Lease.cas_update(ctx.sandbox.id, epoch, %{status: "terminated"})

      # The same refusal `Conversations.update_sandbox/2` gets from
      # `prevent_sandbox_revival/1`. Holding the lease is not permission to
      # un-retire a row, and `:retired` says so rather than `:stale`, which
      # would send the owner looking for a takeover that never happened.
      assert {:error, :retired} = Lease.cas_update(ctx.sandbox.id, epoch, %{status: "ready"})
      assert Repo.get!(Sandbox, ctx.sandbox.id).status == "terminated"

      # Terminal to terminal still goes through, exactly as it does through
      # `update_sandbox/2`, and a write that never names a status is untouched
      # by this.
      assert {:ok, _} = Lease.cas_update(ctx.sandbox.id, epoch, %{status: "failed"})

      assert {:ok, reaped} =
               Lease.cas_update(ctx.sandbox.id, epoch, %{transition_reason: "reaped"})

      assert reaped.transition_reason == "reaped"
    end

    test "an epoch below 1 is refused even where a row somehow has a holder", ctx do
      # Unreachable through this module: `do_claim/5` is the only writer of the
      # holder columns and always moves the epoch to 1 or more. Forged straight
      # into the row so `taken_epoch?/1` is pinned on its own — `held_by/2`'s
      # holder columns mask it on every reachable row, which is exactly how a
      # defence-in-depth guard gets deleted in a refactor with nothing red.
      Repo.update_all(from(x in Sandbox, where: x.id == ^ctx.sandbox.id),
        set: [
          lease_epoch: 0,
          lease_node: "ghost@node",
          lease_until: DateTime.add(DateTime.utc_now(), @ttl_ms, :millisecond)
        ]
      )

      assert {:error, :lost} = Lease.renew(ctx.sandbox.id, 0, @ttl_ms)
      assert {:error, :lost} = Lease.release(ctx.sandbox.id, 0)
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 0, %{status: "ready"})
      assert Repo.get!(Sandbox, ctx.sandbox.id).status == "pending"
    end

    test "a terminal status carries its own terminated_at", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)

      # `Billing.SandboxUsage` reads `terminated_at` as the end of the billed
      # interval, and a writer that fails a machine never passes one. Without
      # this stamp `cas_update/3` would leave a retired sandbox reading as
      # still running, which is the bug `stamp_terminated_at/1` was written for.
      assert {:ok, live} = Lease.cas_update(ctx.sandbox.id, epoch, %{transition: "destroying"})
      refute live.terminated_at

      assert {:ok, terminated} = Lease.cas_update(ctx.sandbox.id, epoch, %{status: "terminated"})
      assert terminated.terminated_at

      # Stamped once. A second terminal write does not move the billed end.
      assert {:ok, failed} = Lease.cas_update(ctx.sandbox.id, epoch, %{status: "failed"})
      assert failed.terminated_at == terminated.terminated_at
    end

    test "a caller's own terminated_at wins over the stamp", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)
      theirs = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      assert {:ok, terminated} =
               Lease.cas_update(ctx.sandbox.id, epoch, %{
                 status: "failed",
                 terminated_at: theirs
               })

      assert terminated.terminated_at == theirs
    end

    test "a superseded epoch is stale even on a retired row", ctx do
      # Claimed with a clock far enough back that the lease has already
      # lapsed, so the takeover below needs no sleeping.
      lapsed = DateTime.add(DateTime.utc_now(), -2 * @ttl_ms, :millisecond)
      assert {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms, lapsed)
      assert {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, %{status: "terminated"})
      assert {:ok, 2} = Lease.take_over(ctx.sandbox.id, "fountain@test-b", @ttl_ms)

      # `:stale` beats `:retired`. A caller that no longer holds the machine is
      # told it lost the lease, not what the row's status happens to be.
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, %{status: "ready"})
      assert {:error, :retired} = Lease.cas_update(ctx.sandbox.id, 2, %{status: "ready"})
    end

    test "a caller's own bug is an answer, not a raise", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)
      before = Repo.get!(Sandbox, ctx.sandbox.id)

      # A duplicate key in a keyword list reaches Ecto as two `SET status =`
      # clauses and raises `Ecto.QueryError` from inside the transaction.
      assert {:error, {:invalid, :status}} =
               Lease.cas_update(ctx.sandbox.id, epoch, status: "failed", status: "suspended")

      # A struct is a map, so the spec and `is_map/1` both admit one and
      # `Enum.reduce_while/3` raises `Protocol.UndefinedError` on it.
      assert {:error, {:invalid, :attrs}} =
               Lease.cas_update(ctx.sandbox.id, epoch, %Sandbox{status: "ready"})

      # `is_binary/1` admits a string that is not a UUID; the query would raise
      # `Ecto.Query.CastError` on it. The raw 16-byte form passes
      # `Ecto.UUID.cast/1` and raises all the same, which is why the guard
      # checks the length too.
      {:ok, raw} = Ecto.UUID.dump(Ecto.UUID.generate())

      for id <- ["not-a-uuid", raw],
          call <- [
            fn id -> Lease.claim(id, ctx.node, @ttl_ms) end,
            fn id -> Lease.take_over(id, ctx.node, @ttl_ms) end,
            fn id -> Lease.renew(id, 1, @ttl_ms) end,
            fn id -> Lease.release(id, 1) end,
            fn id -> Lease.cas_update(id, 1, %{status: "ready"}) end
          ] do
        assert call.(id) == {:error, {:invalid, :sandbox_id}}
      end

      assert Repo.get!(Sandbox, ctx.sandbox.id) == before
    end

    test "a transition reason is free text, not a 255-byte column", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)
      reason = String.duplicate("why this machine went away, at length. ", 40)

      assert {:ok, written} =
               Lease.cas_update(ctx.sandbox.id, epoch, %{
                 transition: "destroying",
                 transition_reason: reason
               })

      assert written.transition_reason == reason
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

          # Worth little on its own — the trigger is BEFORE UPDATE, so the row
          # could not have changed either way. Kept because it would catch a
          # later rewrite that moves the fault after a first write.
          assert Repo.get!(Sandbox, tenant.sandbox.id) == before

          drop_fault()

          # This is the load-bearing assertion. The advisory lock went back with
          # the rollback; on another connection this blocks forever if it did
          # not, and `Task.await` fails rather than hanging the suite.
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
