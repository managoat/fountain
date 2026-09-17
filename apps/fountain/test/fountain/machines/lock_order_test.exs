defmodule Fountain.Machines.LockOrderTest do
  @moduledoc """
  The one ordering between the quota lock and the machine lock (ADR 0058;
  #2309).

  Two advisory-lock namespaces are taken around a machine coming up. 4315 is
  `Fountain.Quotas.with_sandbox_reservation/3` — the fleet key, then a per-user
  key. 4316 is the per-sandbox lock every fence, every turn admission and
  `Fountain.Machines.Lease.claim/4` take. Two namespaces taken in opposite
  orders by two callers is a deadlock, which is what #2309 is about.

  **The rule, as it actually is: anyone holding 4315 may take 4316; nobody
  holding 4316 may take 4315.**

  Stage 7a's PR body first claimed no site held both, and that was wrong (round
  1, protocol review). `Launch.reserve_initial_conversation/4` holds 4315 across
  `reserve_inference/1` → `InferenceBinding.with_current/2`, which takes 4316 —
  so a 4315→4316 holder has existed since long before ADR 0058, and the
  ordering is not "never both" but "one direction".

  `Machines.Resume` is safe for a stronger reason than the rule requires: it
  holds neither across the other. 4316 lives and dies inside `Lease.claim/4`'s
  own short transaction, and the lease that outlives it is a row rather than a
  lock; 4315 is taken by the admission afterwards and released at its commit.
  `resume_test.exs` proves that across real connections with `pg_blocking_pids`.
  What this file proves is the *rule*, for every site rather than that one.

  **What this scan can and cannot see** (7a round 2, carried into 7b). It is
  lexical and one function deep: it chunks every `lib/` file into function
  bodies and fails a body that names both namespaces. An offence split across
  two functions — one that takes 4316 calling one that takes 4315 — passes it,
  and so does either lock taken through a helper the regexes do not name. It is
  a floor on the shapes this codebase actually writes, not a proof. The
  properties themselves are proved where they happen, with `pg_locks` and
  `pg_blocking_pids`, in `resume_test.exs` and `provision_test.exs`.

  `async: false` for the suite's convention around the machines directory; the
  scan itself reads the tree and touches no database.
  """

  use Fountain.DataCase, async: false

  # Every way a body reaches for the per-sandbox lock: the shared door, the lease
  # (which takes it through that door), and the sites that still write the
  # `pg_advisory_xact_lock` call themselves.
  #
  # Scoped to the *namespace* rather than to the call, because
  # `Quotas.with_sandbox_reservation/3` writes the same
  # `pg_advisory_xact_lock($1, $2)` for 4315 — a pattern matching the call alone
  # named that function its own offender.
  @takes_sandbox_lock ~r/with_sandbox_lock\(|Lease\.claim\(|Lease\.take_over\(|@sandbox_lock_namespace|pg_advisory_xact_lock\(\$1, \$2\)"\s*,\s*\[\s*4316/

  # The only way a body reaches for the quota lock.
  @takes_quota_lock ~r/with_sandbox_reservation\(/

  @function_head ~r/^\s*(?:def|defp)\s/

  describe "the rule" do
    test "no function that takes the machine lock reaches for the quota lock under it" do
      root = Path.expand("../../../../..", __DIR__)
      files = source_files(root)

      assert length(files) > 100, "the scan is broken; it proves nothing"

      # Guard the guard. A regex that stopped matching would make the assertion
      # below vacuous, so the scan has to be shown to find the sites that do
      # take each lock — one of each, named, so a rename fails here rather than
      # silently emptying the check.
      assert Enum.any?(bodies(files), &(&1 =~ @takes_sandbox_lock)),
             "the scan found nothing taking the sandbox lock"

      assert Enum.any?(bodies(files), &(&1 =~ @takes_quota_lock)),
             "the scan found nothing taking the quota lock"

      offenders =
        for file <- files,
            body <- bodies([file]),
            body =~ @takes_sandbox_lock,
            body =~ @takes_quota_lock,
            do: Path.relative_to(file, root)

      assert offenders == [],
             "these take advisory lock 4316 and then reach for 4315 under it, which is the " <>
               "opposite order from `Launch.reserve_initial_conversation/4` and the deadlock " <>
               "#2309 warns about: #{inspect(offenders)}"
    end

    test "the allowed direction exists, so the rule is a direction and not a prohibition" do
      # `Launch.reserve_initial_conversation/4` holds 4315 and takes 4316 under
      # it, through `reserve_inference/1`. Pinned because the PR body for stage
      # 7a claimed the opposite, and a rule nobody can point at an instance of
      # is a rule nobody checks.
      launch =
        Path.expand("../../../../../apps/fountain/lib/fountain/conversations/launch.ex", __DIR__)

      assert File.read!(launch) =~ "with_sandbox_reservation("

      binding =
        Path.expand(
          "../../../../../apps/fountain/lib/fountain/conversations/inference_binding.ex",
          __DIR__
        )

      assert File.read!(binding) =~ "pg_advisory_xact_lock",
             "InferenceBinding.with_current/2 no longer takes the machine lock; the 4315 -> " <>
               "4316 holder this rule is written around has moved"
    end
  end

  # **The resume's own half is not here**, and could not be: under the test SQL
  # sandbox every test is one transaction, so a transaction-scoped advisory lock
  # taken by a nested `Repo.transaction` is held until the test ends whatever
  # the code does — `Lease.claim/4` looks like it never releases 4316, and
  # `with_sandbox_reservation/3` like it never releases 4315. Reading `pg_locks`
  # here would prove the sandbox, not the protocol.
  #
  # `resume_test.exs`'s "a resume waiting on the quota lock is holding no
  # sandbox lock" is that half, across real connections, with
  # `pg_blocking_pids`. This file is the rule for every *other* site, which is a
  # question about the tree rather than about a connection.

  defp source_files(root) do
    ([Path.join(root, "apps/fountain/lib"), Path.join(root, "ee/lib")] ++
       Path.wildcard(Path.join(root, "apps/fountain_*/lib")))
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
  end

  # One chunk per function body, so a module that takes each lock in two
  # different functions — `launch.ex` does — is not read as taking them
  # together.
  defp bodies(files) do
    Enum.flat_map(files, fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.chunk_while(
        [],
        fn line, acc ->
          if String.match?(line, @function_head) and acc != [],
            do: {:cont, Enum.reverse(acc), [line]},
            else: {:cont, [line | acc]}
        end,
        fn acc -> {:cont, Enum.reverse(acc), []} end
      )
      |> Enum.map(&Enum.join(&1, "\n"))
    end)
  end
end
