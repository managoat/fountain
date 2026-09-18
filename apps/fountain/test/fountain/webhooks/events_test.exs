defmodule Fountain.Webhooks.EventsTest do
  @moduledoc """
  The catalogue against the code (#700, ADR 0024).

  The whole claim of hanging dispatch off `publish_stage/4` is that a new
  lifecycle outcome cannot be added without webhook subscribers seeing it.
  That claim is invisible to the compiler: add a `publish_stage(conv, "quota",
  "exceeded")` call and nothing breaks, the event is dispatched with a type
  nobody can subscribe to by name, and the docs page is quietly wrong.

  So this reads the call sites out of the source, the way `docs_test.go` reads
  the CLI tree, and fails when one produces a type the catalogue does not
  name. It is the same shape of guard as the audit guardrail: the rule is
  enforced rather than merely written down.
  """

  use ExUnit.Case, async: true

  alias Fountain.Webhooks.Events

  # Where publish_stage/4 is called from. A new file calling it belongs here.
  @sources [
    "lib/fountain/conversations.ex",
    "lib/fountain/conversations/conversation_server.ex",
    # The fresh arm of `handle_continue(:provision)` moved out of the server in
    # ADR 0058 stage 7b, and `provision/started` and `provision/done` went with
    # it. Nothing about the events changed; the file they are published from
    # did, and this list is by file.
    "lib/fountain/conversations/fresh_provision.ex",
    # Binding-aware status reports now own provision/failed (#2393).
    "lib/fountain/conversations/actor_status.ex",
    "lib/fountain/conversations/reapply.ex",
    "lib/fountain/conversations/checkpoints.ex",
    "lib/fountain/conversations/reattachment.ex",
    "lib/fountain/conversations/provisioning.ex",
    "lib/fountain/conversations/egress.ex",
    "lib/fountain/conversations/turn_machine.ex",
    "lib/fountain/conversations/pending.ex",
    "lib/fountain/conversations/lifecycle.ex",
    "lib/fountain/conversations/connection.ex",
    "lib/fountain/conversations/output.ex",
    "lib/fountain/conversations/home_checkpoint.ex"
  ]

  # publish_stage(<anything>, "<stage>", "<status>"
  @call_site ~r/publish_stage\(\s*[^,]+,\s*"([a-z_]+)",\s*"([a-z_]+)"/

  # The looser cousin of @call_site: it reads the stage only, so a call site
  # whose status is a variable or an expression — home_checkpoint.ex's
  # `publish(sandbox, state, meta)`, or turn_machine.ex's `if(...)` — still
  # shows up. It cannot tell us the status, only that the stage is live.
  @stage_only ~r/publish_stage\(\s*[^,]+,\s*"([a-z_]+)"/

  defp app_dir do
    Application.app_dir(:fountain) |> Path.join("../../../../apps/fountain") |> Path.expand()
  end

  defp published_pairs do
    for source <- @sources,
        path = Path.join(app_dir(), source),
        File.exists?(path),
        [_, stage, status] <- Regex.scan(@call_site, File.read!(path)),
        uniq: true,
        do: {stage, status}
  end

  defp stage_matches(regex, content) do
    Regex.scan(regex, content) |> Enum.map(fn [_, stage | _] -> stage end)
  end

  # Every call site whose status is not a literal string, named one at a
  # time: `{source, stage, regex}`. Each regex reads the actual
  # status-producing expression at that site, not just "the file mentions
  # this word somewhere" — a same-file substring check accepted
  # `row.status == "completed"` (turn_machine.ex) and `mode: "persistent"`
  # (home_checkpoint.ex) as if they were statuses, because both strings sit
  # in files that also have a computed `turn`/`checkpoint` call site. Every
  # entry here is checked against its file for real by
  # "every @computed_sites entry's regex resolves at least one status"
  # below, and "every computed call site is covered by @computed_sites"
  # proves the table has no fourth, unlisted entry to fall out of date.
  @computed_sites [
    # `publish(sandbox, "done", meta)` / `publish(sandbox, "failed", meta)` —
    # the private helper `HomeCheckpoint.publish/3` that every
    # `publish_stage(_, "checkpoint", state, _)` call site routes through.
    {"lib/fountain/conversations/home_checkpoint.ex", "checkpoint",
     ~r/publish\(\w+,\s*"([a-z_]+)"/},
    # `"turn",\n  # comment\n  if(row.status == "completed", do: "done", else: "failed")`.
    # Only the `do:`/`else:` branch values are captured; the `"completed"`
    # compared against is not one of them.
    {"lib/fountain/conversations/turn_machine.ex", "turn",
     ~r/"turn",\s*(?:#[^\n]*\n\s*)?if\(row\.status == "completed", do: "([a-z_]+)", else: "([a-z_]+)"\)/},
    # `status = if updated_turn.status == "failed", do: "failed", else: "interrupted"`,
    # bound just above `publish_stage(turn.conversation_id, "turn", status, metadata)`.
    {"lib/fountain/conversations.ex", "turn",
     ~r/status = if updated_turn\.status == "failed", do: "([a-z_]+)", else: "([a-z_]+)"/}
  ]

  # Every {stage, status} a @computed_sites entry's regex actually resolves,
  # by reading its file and taking every capture group of every match.
  defp computed_pairs do
    for {source, stage, regex} <- @computed_sites,
        path = Path.join(app_dir(), source),
        File.exists?(path),
        content = File.read!(path),
        match <- Regex.scan(regex, content),
        status <- Enum.drop(match, 1),
        do: {stage, status}
  end

  # {source, stage} pairs among @sources with a call site whose status
  # @call_site could not read literally, and no @computed_sites entry for
  # that exact file and stage. Non-empty means the table has fallen behind
  # the source: a new (or moved) computed-status call site would otherwise
  # widen nothing, silently — the pair it introduces just fails the stale
  # check below, same as any other unresolved status.
  defp uncovered_computed_call_sites do
    covered = MapSet.new(@computed_sites, fn {source, stage, _regex} -> {source, stage} end)

    for source <- @sources,
        path = Path.join(app_dir(), source),
        File.exists?(path),
        content = File.read!(path),
        literal = Enum.frequencies(stage_matches(@call_site, content)),
        all = Enum.frequencies(stage_matches(@stage_only, content)),
        {stage, count} <- all,
        count > Map.get(literal, stage, 0),
        not MapSet.member?(covered, {source, stage}),
        do: {source, stage}
  end

  # The stale-entry check as a pure function of the catalogue and the pairs
  # `published_pairs/0` found, so a test can hand it a deliberately mutated
  # catalogue without touching `Events` itself. No fallback: a catalogue
  # type must be an exact literal pair, or an exact pair resolved from
  # `@computed_sites`.
  defp stale_catalogue_entries(catalogue, published) do
    produced = MapSet.new(published ++ computed_pairs(), fn {s, st} -> Events.type(s, st) end)

    for {stage, statuses} <- catalogue,
        status <- statuses,
        type = Events.type(stage, status),
        not MapSet.member?(produced, type),
        do: type
  end

  # The independent, no-fixed-list version: every stage published anywhere
  # under lib/fountain/, found with the stage-only regex. Unlike
  # `published_pairs/0`, a brand new file calling `publish_stage/4` shows up
  # here without anyone adding it to @sources first.
  defp wildcard_stages do
    pattern = Path.join(app_dir(), "lib/fountain/**/*.ex")

    for path <- Path.wildcard(pattern),
        stage <- stage_matches(@stage_only, File.read!(path)),
        uniq: true,
        do: stage
  end

  test "the source actually reachable from here has publish_stage call sites" do
    # Guard the guard: a broken path or a changed call shape would make every
    # assertion below vacuously true.
    assert length(published_pairs()) > 20
  end

  test "guard the guard: the wildcard walk over lib/fountain/ finds stages too" do
    # Same reasoning as above, for the walk that does not depend on @sources.
    assert length(wildcard_stages()) > 10
  end

  defp retired_stages, do: MapSet.new(Events.retired(), fn {stage, _statuses} -> stage end)

  # The invariant once the last emitter is gone, and the one worth stating
  # directly: **retired means no publish sites at all**. The catalogue walk
  # below would not catch a returning emitter on its own — `Webhooks.dispatch`
  # derives the type and calls `Events.matches?/2` without consulting
  # `known?/1`, and a retired exact filter (and `*`) is still a valid
  # subscription, so a re-added `publish_stage(_, "caller_tool", _)` would
  # actually be delivered to a subscriber the retirement promised would never
  # hear from it again.
  test "nothing in the source publishes a retired stage" do
    retired = retired_stages()

    offenders =
      published_pairs()
      |> Enum.filter(fn {stage, _status} -> MapSet.member?(retired, stage) end)
      |> Enum.map(fn {stage, status} -> Events.type(stage, status) end)
      |> Enum.sort()

    assert offenders == [], """
    These retired stages still have `publish_stage/4` call sites:

      #{Enum.join(offenders, "\n  ")}

    A retired stage is never emitted — that is what retiring it means, and
    `Fountain.Webhooks` will deliver one to any endpoint whose filter still
    matches. Remove the call site, or take the stage out of `@retired` and put
    it back in the catalogue and the docs page.
    """
  end

  test "every stage transition in the source is in the catalogue" do
    missing =
      published_pairs()
      |> Enum.map(fn {stage, status} -> Events.type(stage, status) end)
      |> Enum.reject(&Events.known?/1)
      |> Enum.sort()

    assert missing == [], """
    These stage transitions are published but are not in the webhook
    catalogue, so nobody can subscribe to them by name and the docs page
    does not list them:

      #{Enum.join(missing, "\n  ")}

    Add them to `Fountain.Webhooks.Events`, and to the table in
    docs/reference/webhooks.md. If the stage is being retired instead, put it
    in `@retired` and mark it historical on the docs page.
    """
  end

  test "every stage the wildcard walk finds is a catalogue or retired stage" do
    # The independent net: a stage published anywhere under lib/fountain/,
    # regardless of whether @sources names its file or its status is a
    # literal. This is what would have caught `checkpoint` before anyone
    # added home_checkpoint.ex to @sources by hand.
    known = MapSet.new(Events.catalogue(), fn {stage, _statuses} -> stage end)
    retired = retired_stages()

    offenders =
      wildcard_stages()
      |> Enum.reject(&(MapSet.member?(known, &1) or MapSet.member?(retired, &1)))
      |> Enum.sort()

    assert offenders == [], """
    These stages are published somewhere under lib/fountain/ but are not in
    the webhook catalogue or the retired list:

      #{Enum.join(offenders, "\n  ")}

    A computed status kept them off the literal-pair walk above. Add them to
    `Fountain.Webhooks.Events`, and to the table in docs/reference/webhooks.md.
    """
  end

  test "the catalogue names nothing the source cannot produce" do
    # The other direction. A stale entry is a documented event that never
    # arrives, which is worse than an undocumented one.
    stale = stale_catalogue_entries(Events.catalogue(), published_pairs())

    assert stale == [],
           "these catalogue entries match no publish_stage call site: #{inspect(stale)}"
  end

  test "every computed-status call site is covered by a @computed_sites entry" do
    # Guards the table itself: a fourth computed-status call site (a new
    # file, or an existing one gaining a second) that nobody added an entry
    # for would otherwise just fail the stale check silently on whatever
    # status it happens to produce, indistinguishable from a real typo.
    uncovered = uncovered_computed_call_sites()

    assert uncovered == [], """
    These files have a publish_stage/4 call site whose status is not a
    literal, and no @computed_sites entry for that file and stage:

      #{Enum.map_join(uncovered, "\n  ", &inspect/1)}

    Add an entry to @computed_sites in this file whose regex captures every
    status that call site can actually produce.
    """
  end

  test "every @computed_sites entry's regex resolves at least one status" do
    # The other half: an entry whose regex stopped matching (the source
    # moved, a rename, reformatted code) would silently resolve nothing,
    # which is indistinguishable from the entry not existing — except that
    # `uncovered_computed_call_sites/0` above would no longer catch it,
    # since the {source, stage} pair still looks "covered".
    dead =
      for {source, stage, regex} <- @computed_sites,
          path = Path.join(app_dir(), source),
          content = File.exists?(path) && File.read!(path),
          matches = if(content, do: Regex.scan(regex, content), else: []),
          matches == [],
          do: {source, stage}

    assert dead == [], "these @computed_sites entries resolved no status: #{inspect(dead)}"
  end

  # Ways `stale_catalogue_entries/2` must not be fooled, run against the
  # real `published_pairs()` but a deliberately mutated catalogue, so none
  # of them touch `Fountain.Webhooks.Events` itself.
  describe "the stale-entry check does not over-forgive a computed status" do
    defp with_extra_status(stage, status) do
      Enum.map(Events.catalogue(), fn
        {^stage, statuses} -> {stage, statuses ++ [status]}
        other -> other
      end)
    end

    test "an extra status on a stage with a computed call site still fails" do
      # `turn` has two computed-status call sites (turn_machine.ex,
      # conversations.ex). Excusing the whole stage once any of its call
      # sites has a computed status — rather than the exact (stage, status)
      # pair — would let this made-up status through silently.
      catalogue = with_extra_status("turn", "never_emitted")

      assert stale_catalogue_entries(catalogue, published_pairs()) == [
               "conversation.turn.never_emitted"
             ]
    end

    test "an extra status on checkpoint, whose only call site is computed, still fails" do
      catalogue = with_extra_status("checkpoint", "bogus")

      assert stale_catalogue_entries(catalogue, published_pairs()) == [
               "conversation.checkpoint.bogus"
             ]
    end

    test "a wholly new stage with no call site at all still fails" do
      catalogue = [{"totally_bogus_stage_2294", ~w(done)} | Events.catalogue()]

      assert stale_catalogue_entries(catalogue, published_pairs()) == [
               "conversation.totally_bogus_stage_2294.done"
             ]
    end

    test "turn.completed still fails, even though the literal string sits in the emitter file" do
      # `row.status == "completed"` is the comparison, never the value
      # `publish_stage/4` is called with — the SAME-file substring check
      # this replaced would have let it through.
      catalogue = with_extra_status("turn", "completed")

      assert stale_catalogue_entries(catalogue, published_pairs()) == [
               "conversation.turn.completed"
             ]
    end

    test "checkpoint.persistent still fails, even though the literal string sits in the emitter file" do
      # `mode: "persistent"` is a sandbox mode guard in `on_park/1`, never a
      # status `publish_stage/4` is called with.
      catalogue = with_extra_status("checkpoint", "persistent")

      assert stale_catalogue_entries(catalogue, published_pairs()) == [
               "conversation.checkpoint.persistent"
             ]
    end
  end

  describe "filters" do
    test "an exact type matches only itself" do
      assert Events.matches?(["conversation.turn.done"], "conversation.turn.done")
      refute Events.matches?(["conversation.turn.done"], "conversation.turn.failed")
    end

    test "a stage wildcard matches every status of that stage" do
      filters = ["conversation.turn.*"]

      assert Events.matches?(filters, "conversation.turn.done")
      assert Events.matches?(filters, "conversation.turn.interrupted")
      refute Events.matches?(filters, "conversation.provision.done")
    end

    test "a bare star matches everything" do
      for type <- Events.types(), do: assert(Events.matches?(["*"], type))
    end

    test "an empty filter matches nothing" do
      refute Events.matches?([], "conversation.turn.done")
    end

    test "a typo is not a valid filter" do
      refute Events.valid_filter?("conversation.turn.finished")
      refute Events.valid_filter?("conversation.tunr.done")
      refute Events.valid_filter?("conversation.*")
      refute Events.valid_filter?("**")
      refute Events.valid_filter?(nil)
    end

    # ADR 0057 (#2252). A retired stage is NOT subscribable: an endpoint saved
    # against one would look fine and receive nothing, which is the failure
    # save-time validation exists to prevent. `retired_filter?/1` recognises it
    # only so `Webhooks.Endpoint` can grandfather a value already stored on a
    # row — see `webhooks_test.exs` for both halves of that.
    test "a retired type is not a valid filter" do
      for type <- [
            "conversation.caller_tool.started",
            "conversation.caller_tool.done",
            "conversation.caller_tool.*"
          ] do
        refute Events.valid_filter?(type)
        assert Events.retired_filter?(type)
      end
    end

    test "retired_filter?/1 recognises only retired stages" do
      refute Events.retired_filter?("conversation.turn.done")
      refute Events.retired_filter?("conversation.turn.*")
      refute Events.retired_filter?("conversation.caller_tool.finished")
      refute Events.retired_filter?("*")
      refute Events.retired_filter?(nil)
    end

    test "but a retired type is not emitted, and is not in the catalogue" do
      refute "conversation.caller_tool.started" in Events.types()
      refute "conversation.caller_tool.done" in Events.types()
      refute List.keymember?(Events.catalogue(), "caller_tool", 0)
      refute Events.known?("conversation.caller_tool.started")

      # It is a bare star's business too: `*` delivers what is emitted, and a
      # retired type is never emitted, so nothing reaches a subscriber.
      refute Enum.any?(Events.types(), &String.starts_with?(&1, "conversation.caller_tool."))

      # Guard the guard: the retired list is not simply empty.
      assert List.keymember?(Events.retired(), "caller_tool", 0)
    end

    test "a typo inside a retired stage is still refused" do
      refute Events.valid_filter?("conversation.caller_tool.finished")
      refute Events.valid_filter?("conversation.caller_tul.done")
    end

    test "the three shapes are valid filters" do
      assert Events.valid_filter?("*")
      assert Events.valid_filter?("conversation.turn.*")
      assert Events.valid_filter?("conversation.turn.done")
    end
  end

  test "the defaults are the three an integrator usually wants, and all real" do
    assert Events.defaults() == [
             "conversation.turn.done",
             "conversation.turn.failed",
             "conversation.provision.failed"
           ]

    for type <- Events.defaults(), do: assert(Events.known?(type))
  end
end
