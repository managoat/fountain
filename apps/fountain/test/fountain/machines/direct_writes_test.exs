defmodule Fountain.Machines.DirectWritesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Direct machine writes only go down.

  ADR 0058 ("The machine has one owner", `decisions/0058-the-machine-has-one-owner.md`)
  gives a sandbox one owner, `Fountain.Machines.Machine`, and moves every
  direct write to the `sandboxes` row and every call into the provider behind
  it. Stages 3-8 (tracker #2344) move call sites out of the rest of the tree
  and into `lib/fountain/machines/`, one PR at a time. This test is the
  ratchet for that move: it counts every call site the owner has not yet
  absorbed, in two groups, and fails if either count rises above its pin.

  - `@row_writes` — direct writes to the sandbox row, in three shapes:
    `update_sandbox/2`, `update_sandbox_row/2` and `claim_sandbox/2`
    (`Fountain.Conversations`), called from anywhere other than their own
    definitions; a `Repo.update_all/3` whose source is the `sandboxes` table;
    and a `Repo.insert`/`insert!`/`update`/`update!` whose changeset is a
    sandbox's. The last two were added by stage 6b (see the pin comment)
    because writes had begun leaving the context through shapes the scan could
    not see — and, once it could see them, because four writes that had never
    been in any count turned out to be there all along.
  - `@provider_mutations` — direct calls into the provider:
    `Managoat.Sandbox.create/2`, `resume/1`, `suspend/1`, `destroy/1` and
    `create_checkpoint/1`, including calls through a bare
    `alias Managoat.Sandbox` (several callers use one).

  **The pin only shrinks.** It is not a target, it is a record of how many
  direct writes exist outside `lib/fountain/machines/` on `main` right now.
  A stage that moves a call site into the owner lowers the pin to match in
  the same PR; nothing else moves it. If this test fails, the fix is to
  finish moving the write behind `Fountain.Machines.*` (ADR 0058, #2344),
  not to raise `@row_writes` or `@provider_mutations`.

  **A stack in flight does not move it**, the same rule
  `ConversationServerSizeTest` applies to the server's line count: the pin
  is the count on `main`, and a branch mid-stack is not evidence the count
  should change.

  ## What the scan does and does not see

  This is a plain-text scan of every `.ex` file under `apps/fountain/lib`,
  `ee/lib` (when present) and `apps/fountain_*/lib`, excluding anything
  under `lib/fountain/machines/` (the owner's own namespace, exempted from
  `UnsafeCallOwnership` in `.credo.exs` for the same reason). No compilation,
  no `mix xref`, no database — it is a `String.split` and a handful of
  regexes, the same shape as `ConversationServerSizeTest`.

  - `@moduledoc`/`@doc` heredocs are stripped before counting, so a call
    mentioned in prose (one does appear, in `SandboxReaper`'s moduledoc)
    is not counted. Whole-line `#` comments are stripped the same way.
    Inline trailing `# comments` are not stripped — none of the matched
    patterns currently occur after one — because doing that correctly
    around string interpolation (`#{}`) is not simple, and the brief said
    to keep this simple.
  - A row-write definition line (`def`/`defp`/`@spec` for `update_sandbox`,
    `update_sandbox_row` or `claim_sandbox`) is excluded; a call to one of
    them from inside `Fountain.Conversations` itself still counts (e.g.
    `claim_sandbox/2` calling `update_sandbox/2`).
  - An `update_all` counts when the *source* of its query is `Sandbox` — a
    `from`-clause binding on `Sandbox`, `Conversations.Sandbox` or the bare
    `"sandboxes"` table, found in the ten lines around the call so the query
    may be built on a line of its own or piped in. A query that merely
    *joins* `Sandbox` to write some other table does not count, and one does:
    `MachineEvents` updates `conversations` with a join on `sandboxes`.
  - A `Repo.insert`, `Repo.insert!`, `Repo.update` or `Repo.update!` counts
    when the changeset it is given is a sandbox's. That is decided per
    **function body**: a body that names the schema (`in Sandbox`,
    `%Sandbox{}`) has each of its `Repo` writes attributed to the nearest
    changeset expression above it, and the write counts when that expression
    is `Sandbox.changeset(` or a bare `Ecto.Changeset.change(`. A body that
    does not name the schema is skipped entirely.

    Both halves are load-bearing. Attribution is what keeps
    `Launch.fail_initial_start/2` at one rather than two — it writes a
    conversation and a sandbox in the same locked body, through
    `Conversation.changeset(` and `Sandbox.changeset(` — and the bare
    `Ecto.Changeset.change(` clause is what sees the three writes that build
    no schema changeset at all: the teardown fence, the reset front door and
    `SandboxIdentity`. Scoping to the body rather than to a window of lines
    is what makes that safe: `Conversations.do_update_sandbox/2` puts fifteen
    lines of guards between its changeset and its `Repo.update/1`.
  - The row-write match is word-bounded so `reclaim_sandbox(` (a local,
    unrelated function on `ConversationServer`) does not match
    `claim_sandbox(`.
  - The provider match resolves the one alias pattern this codebase uses:
    a file with a bare `alias Managoat.Sandbox` line also counts bare
    `Sandbox.create(` etc. as the qualified call it is (`Provisioning` does
    this once, for `create_checkpoint/1`). It does not resolve `as:` aliases
    or renamed imports; none exist for `Managoat.Sandbox` today.
  """

  # Measured against `main` on this branch, 2026-09-16. See the per-file
  # breakdown this test prints on failure for what makes up each number.
  #
  # 28 -> 25 and 17 -> 15: ADR 0058 stage 5a moved the three conversation-side
  # destroys behind `Fountain.Machines.Destroy`. Gone from the count are the
  # terminal writes in `Lifecycle.do_destroy/4`,
  # `ConversationServer.terminate_machine/2` and
  # `Termination.retire_terminated_sandbox/2`, and the two
  # `Managoat.Sandbox.destroy/1` calls the first two of those made. The third
  # never called the provider at all — it now does, through the owner, which is
  # a call this ratchet does not see because `lib/fountain/machines/` is
  # exempt.
  #
  # 25 -> 21 and 15 -> 13: stage 5b moved the forced-teardown side. Four
  # terminal writes went — `Termination._unsafe_retire_home/1` (deleted) and
  # `Termination.reap_sandbox/2`'s dead-server arm, `Accounts.Deletion`'s
  # `destroy_sprite/1` and `SandboxReaper.expire/2` — and the two
  # `Managoat.Sandbox.destroy/1` calls the first and third of those made. The
  # reaper's expiry, like the dead-server terminate before it, had no provider
  # call of its own to remove: it left the machine for pass 2, and now destroys
  # it through the owner. Stage 5c takes the reset family.
  #
  # 13 -> 11: stage 5c moved the reset family. Both
  # `Managoat.Sandbox.destroy/1` calls in `Conversations.confirm_reset_deletion/2`
  # are gone — the probe's and the plain one — and the reset's provider call is
  # the protocol's now. `Managoat.Sandbox.get/1`, the probe itself, stays and
  # was never counted: this ratchet counts *mutations*, and asking a provider
  # what it has is not one.
  #
  # `@row_writes` stayed at 21 through stage 5c. The write the reset finalize
  # used to make went through `update_sandbox_if/3` — a private function this
  # scan did not count, since it counted `update_sandbox(`,
  # `update_sandbox_row(` and `claim_sandbox(` — so a real write left
  # `lib/fountain/conversations.ex` for `Fountain.Machines.Lease.cas_update/3`
  # without the number moving. Stage 6a then added a write the scan could not
  # see either: `Conversations.register_server/2`'s `woken_at` marker, an
  # `update_all` on the primary key, declared in that PR's body as an honest
  # gap.
  #
  # 21 -> 25: stage 6b widened the scan rather than leave the gap, because a
  # ratchet that only counts one spelling of a write teaches the next stage to
  # use another. The four it can now see, all of them pre-existing:
  #
  #   1  conversations.ex   `register_server/2`'s `woken_at` marker (6a)
  #   1  conversations.ex   `create_sandbox/1`'s insert
  #   1  conversations.ex   `do_update_sandbox/2`'s own `Repo.update/1`
  #   1  launch.ex          `fail_initial_start/2`'s locked failure write
  #
  # The pin is still a floor on what the scan can see rather than a census —
  # `Repo.query!`, an `Ecto.Multi` or a raw `execute` would all pass it — and
  # the three shapes it does see are the three this codebase writes the row
  # with.
  #
  # 25 -> 29: the widening above, corrected. Counting `Sandbox.changeset(` and
  # calling that "the write" found three of the seven writes that exist, and
  # the missing four are not obscure: the teardown fence
  # (`Lifecycle.do_fence_sandbox_for_teardown/2`), the reset fence
  # (`Conversations.do_reset_sandbox/2`), `SandboxIdentity.bind/2`'s
  # `provider_instance_id` and `InferenceBinding.compatible_machine/2`'s
  # `codex_inference_source` all build their changeset with
  # `Ecto.Changeset.change/2` and never name the schema at the write. Three of
  # the four are columns ADR 0058 stage 9 deletes outright; the point of a
  # ratchet is that it knows they are there in the meantime.
  #
  # 29 -> 26 and 11 -> 9: stage 6b's park moved three row writes and two
  # provider calls behind `Fountain.Machines.Park`.
  #
  #   gone  `lifecycle.ex`        `park_row/1`'s `claim_sandbox/2` and
  #                               `Lifecycle.suspend/1`'s `Managoat.Sandbox.suspend/1`
  #   gone  `sandbox_reaper.ex`   `park/1`'s `update_sandbox/2` and
  #                               `idle_sweep/2`'s `Managoat.Sandbox.suspend/1`
  #   gone  `home_checkpoint.ex`  `record/2`'s `update_sandbox/2`, now
  #                               `Lease.cas_update/3` under the park's own epoch
  #
  # `home_checkpoint.ex` keeps its `create_checkpoint/1`: the park protocol
  # calls `on_park/2`, not the provider, so the checkpoint is still that
  # module's to take and this ratchet still counts it. It leaves with the
  # checkpoint itself, whenever that moves.
  #
  # 26 -> 25 and 9 -> 8: stage 7a's resume moved one row write and one provider
  # call behind `Fountain.Machines.Resume`.
  #
  #   gone  `wake.ex`   `resume_and_wake/1`'s `update_sandbox/2` and its
  #                     `Managoat.Sandbox.resume/1` — the whole function, with
  #                     `wake_suspended_sandbox/2`'s quota-reservation wrapper
  #                     around it
  #
  # One, not two, and the difference is worth naming so the next stage does not
  # budget against a number that was never there. `wake.ex` keeps
  # `mark_old_sandbox_terminated/1`'s `update_sandbox/2`, which retires the row
  # a *replacement* machine supersedes: a destroy-shaped terminal write the
  # stage 6 decisions list for stage 7 alongside `conversation_server.ex`'s
  # reattach-not-found arm, and both belong to 7b's provision bracket rather
  # than to the resume. The nine calls left in `conversation_server.ex` and the
  # five in `provisioning.ex`/`provision_watchdog.ex` are that same bracket and
  # stage 8's binding work.
  @row_writes 25
  @provider_mutations 8

  @provider_verbs ~w(create_checkpoint create resume suspend destroy)

  @doc_block ~r/@(?:module)?doc\s+"""[\s\S]*?"""/
  @row_write_def ~r/^\s*(def|defp)\s+(update_sandbox_row|update_sandbox|claim_sandbox)\(/
  @row_write_spec ~r/^\s*@spec\s+(update_sandbox_row|update_sandbox|claim_sandbox)\(/
  @bare_alias ~r/^\s*alias Managoat\.Sandbox$/m

  @row_write_call ~r/\b(?:update_sandbox_row|update_sandbox|claim_sandbox)\(/
  @provider_verb_alt Enum.join(@provider_verbs, "|")

  # The two shapes stage 6b taught the scan. `@sandbox_update_all` finds the
  # call; `@sandbox_source` decides, over the window around it, whether the
  # thing being written is the `sandboxes` table. `Managoat.Sandbox` has no
  # `changeset/2`, so the changeset pattern cannot pick the provider client up
  # by mistake.
  @sandbox_update_all ~r/\bRepo\.update_all\(/
  @sandbox_source ~r/\bfrom\s*\(?\s*\w+\s+in\s+(?:(?:[A-Za-z_]\w*\.)*Sandbox\b|"sandboxes")/

  # The schema named anywhere in a function body: a query binding on it, or a
  # struct literal. Either says "this body is about a sandbox row".
  # No leading `\b` on the alternation: `%` is not a word character, so a
  # boundary before it never matches after whitespace and `%Sandbox{}` was
  # invisible. The `in` branch keeps its own.
  @sandbox_schema ~r/(?:\bin\s+(?:[A-Za-z_]\w*\.)*Sandbox\b|%(?:[A-Za-z_]\w*\.)*Sandbox\{)/
  @function_head ~r/^\s*(?:def|defp)\s/
  @repo_write ~r/\bRepo\.(?:update|insert)!?\(/
  @schema_changeset ~r/\b([A-Z][A-Za-z_0-9]*)\.changeset\(/
  @bare_changeset ~r/\bEcto\.Changeset\.change\(/

  # How far either side of a `Repo.update_all(` the source may be written.
  # Wide enough for a query built on the preceding lines and piped in, narrow
  # enough that the next call's query is not in view.
  @source_window 5

  test "direct machine writes outside lib/fountain/machines/ only go down" do
    root = Path.expand("../../../../..", __DIR__)
    files = source_files(root)

    row_write_counts = Enum.map(files, &{&1, count_row_writes(&1)})
    provider_counts = Enum.map(files, &{&1, count_provider_mutations(&1)})

    row_writes = row_write_counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    provider_mutations = provider_counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    assert row_writes <= @row_writes,
           "direct sandbox row writes are #{row_writes}, over the pin of " <>
             "#{@row_writes}. The pin only shrinks (ADR 0058, #2344): move the " <>
             "write behind Fountain.Machines.* rather than raising it.\n" <>
             breakdown(row_write_counts, root)

    assert provider_mutations <= @provider_mutations,
           "direct provider mutations are #{provider_mutations}, over the pin " <>
             "of #{@provider_mutations}. The pin only shrinks (ADR 0058, " <>
             "#2344): move the call behind Fountain.Machines.* rather than " <>
             "raising it.\n" <> breakdown(provider_counts, root)
  end

  # What each of the two widened shapes is supposed to find, by file. A
  # ratchet is only as good as its scan, and a regex that matched nothing
  # would pass the count above forever — the failure mode round 2 of stage 5a
  # found in `machine_bounds_test.exs`. So the shapes are pinned where they
  # are, and a stage that moves one of these writes behind the owner edits
  # this list along with the number.
  @sandbox_update_all_files ["apps/fountain/lib/fountain/conversations.ex"]
  @sandbox_write_files [
    # `create_sandbox/1`'s insert, `do_update_sandbox/2`'s own `Repo.update/1`,
    # and `do_reset_sandbox/2`'s reset fence.
    "apps/fountain/lib/fountain/conversations.ex",
    "apps/fountain/lib/fountain/conversations.ex",
    "apps/fountain/lib/fountain/conversations.ex",
    # `do_fence_sandbox_for_teardown/2` — the teardown fence.
    "apps/fountain/lib/fountain/conversations/lifecycle.ex",
    # `fail_initial_start/2`'s locked failure write — one, not two: the
    # conversation it fails in the same body goes through
    # `Conversation.changeset(` and is attributed away.
    "apps/fountain/lib/fountain/conversations/launch.ex",
    # `bind/2` stamping `provider_instance_id` on first binding.
    "apps/fountain/lib/fountain/conversations/sandbox_identity.ex",
    # `compatible_machine/2` stamping `codex_inference_source`.
    "apps/fountain/lib/fountain/conversations/inference_binding.ex"
  ]

  test "the widened scan sees the row writes that are not calls to the context" do
    root = Path.expand("../../../../..", __DIR__)
    files = source_files(root)

    update_alls =
      for file <- files,
          count = count_sandbox_update_all(strip_docs_and_comments(File.read!(file))),
          _ <- 1..count//1,
          do: Path.relative_to(file, root)

    writes =
      for file <- files,
          count = count_sandbox_writes(strip_docs_and_comments(File.read!(file))),
          _ <- 1..count//1,
          do: Path.relative_to(file, root)

    assert Enum.sort(update_alls) == Enum.sort(@sandbox_update_all_files),
           "`Repo.update_all` on the sandboxes table is written in:\n  " <>
             Enum.join(Enum.sort(update_alls), "\n  ") <>
             "\n\nEach one writes the machine's row without going through " <>
             "`Fountain.Conversations` or the owner (ADR 0058, #2344)."

    assert Enum.sort(writes) == Enum.sort(@sandbox_write_files),
           "`Repo.update`/`insert` of a sandbox changeset happens in:\n  " <>
             Enum.join(Enum.sort(writes), "\n  ") <>
             "\n\nEach one writes the machine's row without going through the owner " <>
             "(ADR 0058, #2344). A change to this list is a change to who writes " <>
             "`sandboxes`, not a refactor."
  end

  # A join is not a source. `MachineEvents.machine_gone/6` updates
  # `conversations` with a join on `sandboxes`, and counting it would make the
  # ratchet unlowerable by anything a park or a destroy does — it writes no
  # machine state at all.
  test "an update_all that only joins the sandboxes table is not a row write" do
    joined = """
    {matched, _} =
      Repo.update_all(
        from(c in Conversations.Conversation,
          join: s in Conversations.Sandbox,
          on: s.id == c.sandbox_id,
          where: s.status == "terminated"
        ),
        set: [status: "idle"]
      )
    """

    sourced = """
    Repo.update_all(
      from(s in Sandbox, where: s.id == ^sandbox_id),
      set: [woken_at: DateTime.utc_now()]
    )
    """

    assert count_sandbox_update_all(joined) == 0
    assert count_sandbox_update_all(sourced) == 1
  end

  # The three options stage 5c added to `Fountain.Machines.Destroy` each turn a
  # rule of the protocol off, and each is safe only because of something the
  # *caller* guarantees. `fence: :held_by_caller` asserts `reset_requested_at`
  # and nothing narrower, and that timestamp is shared with the teardown fence
  # (`Lifecycle.do_fence_sandbox_for_teardown/2` writes
  # `reset_requested_at: current.reset_requested_at || now` beside
  # `teardown_requested_at`), so the assertion says "a fence", not "the reset's
  # fence". What keeps it exact is that exactly one caller passes the option,
  # and that caller re-reads the row under the reset's own rules first.
  #
  # `on_provider_error: :refuse` leaves a fenced row live on a provider error,
  # which is a leak for anything whose fence is not retryable; `provider:
  # :already_gone` skips the provider call on a caller's word.
  #
  # So the "exactly one caller" claim is load-bearing, and stage 6 is about to
  # add park's own fence. This pins it the way `@provider_mutations` above pins
  # the call-site count: by file, so a new caller has to come here and say why.
  @reset_option_files ["apps/fountain/lib/fountain/conversations.ex"]
  @forwarding_files ["apps/fountain/lib/fountain/conversations/termination.ex"]

  # The literal option values, plus the key that only these callers use. Not
  # `provider:` on its own — `provider: "sprites"` is everywhere — and not
  # `fence:` on its own, for the same reason.
  @reset_option_markers [":held_by_caller", ":already_gone", "on_provider_error"]

  test "only the reset family turns off a rule of the destroy protocol" do
    root = Path.expand("../../../../..", __DIR__)
    files = source_files(root)

    # The scan has to be shown to reach the two files that legitimately name
    # these options, or a broken climb would pass by finding nothing — the
    # failure mode `machine_bounds_test.exs` was written with in round 2 of 5a.
    relative = MapSet.new(files, &Path.relative_to(&1, root))

    for expected <- @reset_option_files ++ @forwarding_files do
      assert expected in relative,
             "the scan missed #{expected} (#{MapSet.size(relative)} files seen); it cannot " <>
               "pin who passes the protocol's opt-outs if it does not read them"
    end

    named =
      files
      |> Enum.filter(fn file ->
        content = file |> File.read!() |> strip_docs_and_comments()
        Enum.any?(@reset_option_markers, &String.contains?(content, &1))
      end)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    assert named == Enum.sort(@reset_option_files ++ @forwarding_files),
           "the destroy protocol's opt-outs (#{Enum.join(@reset_option_markers, ", ")}) are " <>
             "named outside `lib/fountain/machines/` by:\n  " <>
             Enum.join(named, "\n  ") <>
             "\n\nEach one turns off a rule the protocol otherwise enforces, and each is " <>
             "safe only because of what its caller already did (ADR 0058 stage 5c, #2344). " <>
             "A new caller is a decision, not a refactor: add it here with the reason."
  end

  defp source_files(root) do
    top_level =
      ["apps/fountain/lib", "ee/lib"]
      |> Enum.map(&Path.join(root, &1))
      |> Enum.filter(&File.dir?/1)

    buzz = root |> Path.join("apps/fountain_*/lib") |> Path.wildcard()

    (top_level ++ buzz)
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
    |> Enum.reject(&String.contains?(&1, "/lib/fountain/machines/"))
    |> Enum.sort()
  end

  defp count_row_writes(file) do
    content = file |> File.read!() |> strip_docs_and_comments() |> strip_row_write_defs()

    (@row_write_call |> Regex.scan(content) |> length()) +
      count_sandbox_writes(content) +
      count_sandbox_update_all(content)
  end

  # `Repo.update`/`insert` calls whose changeset is a sandbox's, attributed
  # per function body. See the moduledoc for why the body, and not a window of
  # lines, is the unit.
  defp count_sandbox_writes(content) do
    content
    |> function_bodies()
    |> Enum.filter(&Regex.match?(@sandbox_schema, &1))
    |> Enum.map(&count_attributed_writes/1)
    |> Enum.sum()
  end

  defp function_bodies(content) do
    content
    |> String.split("\n")
    |> Enum.chunk_while(
      [],
      fn line, acc ->
        if Regex.match?(@function_head, line) and acc != [],
          do: {:cont, Enum.reverse(acc), [line]},
          else: {:cont, [line | acc]}
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.map(&Enum.join(&1, "\n"))
  end

  # Walks the body keeping the changeset most recently built, and counts a
  # write only when that one is the sandbox's. `nil` — a write with no
  # changeset expression above it in this body — is not counted: this scan
  # will not guess about a changeset built somewhere else and passed in, and
  # the per-file test below is what fails if one ever is.
  defp count_attributed_writes(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({nil, 0}, fn line, {subject, count} ->
      subject = subject_of(line) || subject

      if Regex.match?(@repo_write, line) and sandbox?(subject),
        do: {subject, count + 1},
        else: {subject, count}
    end)
    |> elem(1)
  end

  defp subject_of(line) do
    case Regex.run(@schema_changeset, line) do
      [_, schema] -> schema
      nil -> if Regex.match?(@bare_changeset, line), do: :change, else: nil
    end
  end

  defp sandbox?(:change), do: true
  defp sandbox?("Sandbox"), do: true
  defp sandbox?(_other), do: false

  # An `update_all` whose source is the `sandboxes` table. The lines are kept
  # rather than the raw text so the window is the same however the query is
  # laid out, and `strip_docs_and_comments/1` has already blanked comment
  # lines in place, which is what keeps the line numbering honest.
  defp count_sandbox_update_all(content) do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _index} -> Regex.match?(@sandbox_update_all, line) end)
    |> Enum.count(fn {_line, index} ->
      lines
      |> Enum.slice(max(index - @source_window, 0), 2 * @source_window + 1)
      |> Enum.join("\n")
      |> then(&Regex.match?(@sandbox_source, &1))
    end)
  end

  defp count_provider_mutations(file) do
    content = file |> File.read!() |> strip_docs_and_comments()

    prefix =
      if Regex.match?(@bare_alias, content),
        do: "(?:Managoat\\.)?Sandbox",
        else: "Managoat\\.Sandbox"

    pattern = Regex.compile!("\\b#{prefix}\\.(?:#{@provider_verb_alt})\\(")

    pattern |> Regex.scan(content) |> length()
  end

  defp strip_docs_and_comments(content) do
    content
    |> then(&Regex.replace(@doc_block, &1, ""))
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      if String.trim_leading(line) |> String.starts_with?("#"), do: "", else: line
    end)
  end

  defp strip_row_write_defs(content) do
    content
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      if Regex.match?(@row_write_def, line) or Regex.match?(@row_write_spec, line) do
        ""
      else
        line
      end
    end)
  end

  defp breakdown(counts, root) do
    counts
    |> Enum.filter(fn {_file, count} -> count > 0 end)
    |> Enum.sort_by(fn {_file, count} -> -count end)
    |> Enum.map_join("\n", fn {file, count} -> "  #{count}\t#{Path.relative_to(file, root)}" end)
  end
end
