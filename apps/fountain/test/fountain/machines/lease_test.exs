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

    test "an enclosing transaction is permitted where a caller opts in", ctx do
      # The one exception, and it has one caller: `Machines.Resume`'s admission
      # runs this inside `Quotas.with_sandbox_reservation/3`'s transaction so the
      # `resuming` stamp and the quota count that authorised it commit together.
      # `cas_update/4` takes no advisory lock, so the moduledoc's reason for the
      # guard does not reach it; what nesting *does* do — a rollback undoing the
      # write — is what a reservation wants.
      {:ok, epoch} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)

      assert {:ok, :rolled_back} =
               Repo.transaction(fn ->
                 assert {:ok, %Sandbox{transition: "resuming"}} =
                          Lease.cas_update(ctx.sandbox.id, epoch, [transition: "resuming"],
                            nest: true
                          )

                 :rolled_back
               end)

      # Committed, because the transaction above committed. The refusal half is
      # in `resume_test.exs`, where a quota that says no rolls the stamp back
      # with it.
      assert Repo.get!(Sandbox, ctx.sandbox.id).transition == "resuming"
    end

    test "opting in does not extend to the functions that take the lock", ctx do
      # `nest:` is `cas_update/4`'s alone. `claim/4` and its siblings hold
      # `pg_advisory_xact_lock(4316, …)`, and nesting one would hold that lock
      # until the *outer* commit — the thing the guard exists for.
      assert {:ok, :unchanged} =
               Repo.transaction(fn ->
                 assert {:error, :transaction_open} =
                          Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)

                 :unchanged
               end)
    end
  end

  describe "the callers that may nest" do
    test "cas_update/4's nest: option has exactly the call sites it is argued for" do
      # 5c's precedent for its own opt-outs: an option that relaxes a guard is
      # only as safe as the list of callers that pass it, and the list is
      # otherwise nowhere. Each one is argued in `cas_update/4`'s docstring.
      #
      #   `Machines.Resume`      the admission (7a): the `resuming` stamp and the
      #                          quota count that authorised it commit together,
      #                          so a refused quota leaves no stamp.
      #   `Machines.Provision`   `fail/2`'s `:before_write` (7b): the hook writes
      #                          the *conversation* and the compare-and-set writes
      #                          the machine, and `Launch.fail_initial_start/2`
      #                          needs both or neither — `main` held them in one
      #                          transaction under the sandbox lock.
      #
      # Neither takes an advisory lock, which is what makes nesting them safe;
      # the moduledoc's reason for the guard is about holding
      # `pg_advisory_xact_lock(4316, …)` open until an outer commit.
      root = Path.expand("../../../../..", __DIR__)

      files =
        ([Path.join(root, "apps/fountain/lib"), Path.join(root, "ee/lib")] ++
           Path.wildcard(Path.join(root, "apps/fountain_*/lib")))
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
        |> Enum.reject(&String.ends_with?(&1, "machines/lease.ex"))

      assert length(files) > 100, "the scan is broken; it proves nothing"

      callers =
        for file <- files,
            File.read!(file) =~ ~r/nest:\s*true/,
            do: Path.relative_to(file, root)

      assert callers == [
               "apps/fountain/lib/fountain/machines/provision.ex",
               "apps/fountain/lib/fountain/machines/resume.ex"
             ],
             "`nest: true` lets a caller write the machine's row inside its own transaction, " <>
               "which every other function here refuses. Adding one is a decision about " <>
               "transaction boundaries, not a call-site choice: #{inspect(callers)}"
    end
  end

  describe "the clock" do
    # Every SQL statement the repo runs while `fun` does. The only way to say
    # *who* computed a timestamp, as the first test explains.
    defp capture_queries(fun) do
      owner = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:fountain, :repo, :query],
        fn _event, _measure, %{query: query}, _config -> send(owner, {:query, query}) end,
        nil
      )

      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

      collect_queries([])
    end

    defp collect_queries(acc) do
      receive do
        {:query, query} -> collect_queries([query | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    setup do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "pending")
      {:ok, user: user, sandbox: sandbox, node: "fountain@test-a"}
    end

    test "a claim dates the lease from the database, not from this node", ctx do
      # The whole of stage 7a's clock change, and it has to be pinned on the
      # *statement* rather than on the value: a test host has one clock, so a
      # deadline written from `DateTime.utc_now()` and one written from
      # `statement_timestamp()` agree to the millisecond and no assertion on the
      # column could tell them apart. What can be told apart is who computed it,
      # which is what the SQL says.
      queries =
        capture_queries(fn -> {:ok, _} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms) end)

      write = Enum.find(queries, &(&1 =~ ~r/UPDATE "sandboxes".*lease_until/s))
      assert write, "no update of `lease_until` was issued at all:\n#{Enum.join(queries, "\n")}"

      assert write =~ "statement_timestamp()",
             "the deadline was computed on this node and sent as a parameter, which is the " <>
               "N-clocks arrangement stage 7a replaced:\n#{write}"

      # And it lands where the database says it should.
      until = Repo.get!(Sandbox, ctx.sandbox.id).lease_until
      drift = DateTime.diff(until, Lease.now(), :millisecond) - @ttl_ms
      assert abs(drift) < 2_000
    end

    test "a renewal is computed by the database too", ctx do
      {:ok, epoch} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)
      queries = capture_queries(fn -> :ok = Lease.renew(ctx.sandbox.id, epoch, @ttl_ms) end)

      write = Enum.find(queries, &(&1 =~ ~r/UPDATE "sandboxes".*lease_until/s))
      assert write
      assert write =~ "statement_timestamp()"
    end

    test "liveness is judged against the database's clock", ctx do
      # `live?/2`'s default, and with it every reader that lets it default:
      # `Machine.busy?/2`, and through that the wake, the attach and the
      # rehydrator. Same reason as the claim above — a value cannot tell the two
      # clocks apart on one host, so the assertion is that a query happened at
      # all.
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms)
      held = Repo.get!(Sandbox, ctx.sandbox.id)

      queries = capture_queries(fn -> assert Lease.live?(held) end)

      assert Enum.any?(queries, &(&1 =~ "statement_timestamp()")),
             "live?/2 judged a database-written deadline against this node's clock"

      # …and an injected clock still costs nothing, which is what lets a sweep
      # judge a page of rows against one instant.
      assert capture_queries(fn -> assert Lease.live?(held, Lease.now()) end)
             |> Enum.reject(&(&1 =~ "statement_timestamp()")) == []
    end

    test "a BEAM clock skewed by minutes does not change liveness", ctx do
      # The failure this closes: a node whose clock runs fast reads every lease
      # as expired and takes live operations over; one running slow leaves dead
      # ones held. Both were possible while `live?/2` compared a
      # database-written column against `DateTime.utc_now()`.
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id, ctx.node, 60_000)
      held = Repo.get!(Sandbox, ctx.sandbox.id)

      assert Lease.live?(held), "a lease claimed a moment ago is not live"

      # There is no way to skew the BEAM clock inside a test, so this asserts
      # the property that makes skew irrelevant: the default clock is the
      # database's, and a *deliberately* skewed one only applies where a caller
      # passes it. Ten minutes fast reads the lease as expired; the default
      # still reads it as live, from the same row, in the same breath.
      fast = DateTime.add(DateTime.utc_now(), 600, :second)
      refute Lease.live?(held, fast)
      assert Lease.live?(held), "the injected clock leaked into the default"
    end

    test "a renewal moves the deadline on the database's clock too", ctx do
      {:ok, epoch} = Lease.claim(ctx.sandbox.id, ctx.node, 1_000)
      first = Repo.get!(Sandbox, ctx.sandbox.id).lease_until

      :ok = Lease.renew(ctx.sandbox.id, epoch, 60_000)
      second = Repo.get!(Sandbox, ctx.sandbox.id).lease_until

      assert DateTime.compare(second, first) == :gt
      drift = DateTime.diff(second, Lease.now(), :millisecond) - 60_000
      assert abs(drift) < 2_000
    end

    test "now/0 advances inside a transaction", ctx do
      # `statement_timestamp()` rather than `now()`, and this is why: `now()` is
      # `transaction_timestamp()` and would be frozen for the whole of an
      # enclosing transaction, so a lease written inside one could never expire
      # to a reader inside the same one — which under the test SQL sandbox, where
      # every test *is* one transaction, means never at all.
      _ = ctx
      first = Lease.now()
      Process.sleep(10)
      second = Lease.now()

      assert DateTime.compare(second, first) == :gt,
             "the database clock is frozen; a lease can never expire to a reader here"
    end

    test "a lease whose TTL has run out is claimable, without an injected clock", ctx do
      # End to end on the real clock: claim for a few milliseconds, wait, claim
      # again. Nothing passes a `now`, so this is exactly what a reaper does.
      {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, 20)
      Process.sleep(60)

      refute Lease.live?(Repo.get!(Sandbox, ctx.sandbox.id))
      assert {:ok, 2} = Lease.take_over(ctx.sandbox.id, "fountain@test-b", @ttl_ms)
    end

    test "a hostile session TimeZone does not change what a lease means", ctx do
      # Round 1, behaviour review. `lease_until` is `timestamp without time
      # zone` and `statement_timestamp()` is a `timestamptz`, so assigning one
      # to the other casts through the **session's** `TimeZone`. Without
      # `AT TIME ZONE 'UTC'` a connection running in `America/New_York` writes a
      # deadline four hours behind the UTC instants Elixir compares it against:
      # every live lease reads dead, `busy?/2` answers false for every operation
      # in flight, and `claim/4` refuses nobody.
      Repo.query!("SET LOCAL TimeZone = 'America/New_York'")

      {:ok, epoch} = Lease.claim(ctx.sandbox.id, ctx.node, 60_000)
      held = Repo.get!(Sandbox, ctx.sandbox.id)

      assert Lease.live?(held),
             "a lease claimed a moment ago reads dead under a non-UTC session TimeZone"

      assert {:error, {:held, _, _}} = Lease.claim(ctx.sandbox.id, "somebody@else", 60_000)

      # The renewal writes through the same cast.
      :ok = Lease.renew(ctx.sandbox.id, epoch, 60_000)
      assert Lease.live?(Repo.get!(Sandbox, ctx.sandbox.id))

      # And the deadline itself is the UTC one, within the TTL rather than four
      # hours off it.
      until = Repo.get!(Sandbox, ctx.sandbox.id).lease_until
      drift = DateTime.diff(until, Lease.now(), :millisecond) - 60_000
      assert abs(drift) < 2_000, "the deadline is #{drift}ms from where it should be"
    end

    test "the quota's own copy of the rule survives the same TimeZone", ctx do
      # `Quotas.active_sandboxes/0` renders `live?/2` in SQL — the one copy that
      # had to be — and compares the same two column types, so it takes the same
      # cast. A machine on its way up that stopped counting on a non-UTC
      # connection would let a tenant past their cap.
      # **Ahead of UTC, and the direction is the test.** The two casts fail in
      # opposite directions and no single zone catches both. On the *write*
      # (above) a zone behind UTC stamps the deadline too early and the lease
      # reads dead — `America/New_York`. Here the write is fine and the
      # comparison is the suspect: a bare `statement_timestamp()` is a
      # `timestamptz`, so Postgres casts `lease_until` *up* using the session
      # zone, and only a zone ahead of UTC moves it far enough back to read
      # expired. A zone behind UTC would make this pass with the cast missing,
      # which is the shape of a test that proves nothing.
      Repo.query!("SET LOCAL TimeZone = 'Pacific/Kiritimati'")

      # `suspended`, not this describe's `pending` fixture: `pending` is in
      # `Quotas.active_statuses/0`, so the first arm of `active_sandboxes/0`
      # would count the row whatever the third arm decided and the assertion
      # below would hold with the cast missing.
      machine = insert_sandbox(user_id: ctx.user.id, status: "suspended")
      assert Fountain.Quotas.active_sandbox_count(ctx.user.id, exclude: ctx.sandbox.id) == 0

      {:ok, epoch} = Lease.claim(machine.id, ctx.node, 60_000)
      {:ok, _} = Lease.cas_update(machine.id, epoch, transition: "resuming")

      assert Fountain.Quotas.active_sandbox_count(ctx.user.id, exclude: ctx.sandbox.id) == 1
    end

    test "the injected clock is still the seam, and still writes what it is given", ctx do
      # Kept so a test that needs to reach an expired lease without sleeping
      # still can — and so the seam's semantics are pinned rather than assumed:
      # an injected `now` dates the deadline as well as judging the old one.
      lapsed = DateTime.add(DateTime.utc_now(), -2 * @ttl_ms, :millisecond)
      {:ok, 1} = Lease.claim(ctx.sandbox.id, ctx.node, @ttl_ms, lapsed)

      until = Repo.get!(Sandbox, ctx.sandbox.id).lease_until
      assert DateTime.compare(until, DateTime.utc_now()) == :lt

      # And the database's clock, which nothing skewed, reads it as expired.
      refute Lease.live?(Repo.get!(Sandbox, ctx.sandbox.id))
      assert {:ok, 2} = Lease.claim(ctx.sandbox.id, "fountain@test-b", @ttl_ms)
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
