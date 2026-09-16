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

  - `@row_writes` — direct writes to the sandbox row: `update_sandbox/2`,
    `update_sandbox_row/2` and `claim_sandbox/2` (`Fountain.Conversations`),
    called from anywhere other than their own definitions.
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
  @row_writes 21
  @provider_mutations 13

  @provider_verbs ~w(create_checkpoint create resume suspend destroy)

  @doc_block ~r/@(?:module)?doc\s+"""[\s\S]*?"""/
  @row_write_def ~r/^\s*(def|defp)\s+(update_sandbox_row|update_sandbox|claim_sandbox)\(/
  @row_write_spec ~r/^\s*@spec\s+(update_sandbox_row|update_sandbox|claim_sandbox)\(/
  @bare_alias ~r/^\s*alias Managoat\.Sandbox$/m

  @row_write_call ~r/\b(?:update_sandbox_row|update_sandbox|claim_sandbox)\(/
  @provider_verb_alt Enum.join(@provider_verbs, "|")

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
    @row_write_call |> Regex.scan(content) |> length()
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
