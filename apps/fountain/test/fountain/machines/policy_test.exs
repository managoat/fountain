defmodule Fountain.Machines.PolicyTest do
  @moduledoc """
  What the two sandbox modes mean (ADR 0058 stage 7a; ADR 0023 step 5).

  These state the table rather than re-testing the five call sites, which keep
  their own suites (`lifecycle_actions_test.exs`, `conversation_server_lifetime_test.exs`,
  `sandbox_reaper_test.exs`, `termination_test.exs`, `conversations_start_test.exs`)
  and pass unchanged — that is what makes stage 7a's gathering a move rather
  than a change.

  The last test is the one that matters most: it pins that the delegations are
  delegations, so a site that quietly grew its own copy of the rule fails here
  rather than drifting.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Agents.Agent
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Machines.Policy

  # The provider vocabulary this table is written in: one that can park with the
  # disk kept, and one that cannot. Which real adapter is which is
  # `Managoat.Sandbox`'s business and is asserted in its own conformance suite;
  # stubbing the capability is what keeps this file about the decision.
  defp can_park, do: stub(Managoat.Sandbox, :supports?, fn _p, cap -> cap == :suspend end)
  defp cannot_park, do: stub(Managoat.Sandbox, :supports?, fn _p, _cap -> false end)

  describe "default_mode/1" do
    test "an agent that has never said which gets ephemeral" do
      for stored <- [nil, ""] do
        assert Policy.default_mode(%Agent{sandbox_mode: stored}) == "ephemeral"
      end
    end

    test "an agent that has said keeps what it said" do
      for stored <- ["ephemeral", "persistent"] do
        assert Policy.default_mode(%Agent{sandbox_mode: stored}) == stored
      end
    end
  end

  describe "idle_action/1" do
    test "a provider that can park, parks" do
      can_park()
      assert Policy.idle_action(:sprites) == :suspend
    end

    test "a provider that cannot, destroys — the cost control wins" do
      cannot_park()
      assert Policy.idle_action(:sprites) == :destroy
    end
  end

  describe "reclaim_action/3 — ADR 0023 step 5 as a table" do
    # | Bound          | Home? | Can park | Cannot park |
    # |----------------|-------|----------|-------------|
    # | :idle          | yes   | :park    | :destroy    |
    # | :idle          | no    | :park    | :destroy    |
    # | :max_lifetime  | yes   | :park    | :destroy    |
    # | :max_lifetime  | no    | :destroy | :destroy    |
    @table [
      {:idle, true, :park, :destroy},
      {:idle, false, :park, :destroy},
      {:max_lifetime, true, :park, :destroy},
      {:max_lifetime, false, :destroy, :destroy}
    ]

    for {bound, home?, parkable, unparkable} <- @table do
      test "#{bound}, home?=#{home?}, on a provider that can park" do
        can_park()

        assert Policy.reclaim_action(unquote(bound), :sprites, unquote(home?)) ==
                 unquote(parkable)
      end

      test "#{bound}, home?=#{home?}, on a provider that cannot" do
        cannot_park()

        assert Policy.reclaim_action(unquote(bound), :sprites, unquote(home?)) ==
                 unquote(unparkable)
      end
    end

    test "the idle bound does not care whether the machine is a home" do
      # Stated on its own because the table makes it easy to miss: the disk is
      # the agent's memory whatever the mode (#649), so an idle *ephemeral*
      # machine is parked too. What `persistent` buys is the ceiling row above
      # and the last-detach rule below.
      can_park()
      assert Policy.reclaim_action(:idle, :sprites, true) == :park
      assert Policy.reclaim_action(:idle, :sprites, false) == :park
    end

    test "the ceiling is where the modes part" do
      can_park()
      assert Policy.reclaim_action(:max_lifetime, :sprites, true) == :park
      assert Policy.reclaim_action(:max_lifetime, :sprites, false) == :destroy
    end
  end

  describe "keep_on_last_detach?/2" do
    test "a home outlives the conversation that is ending" do
      assert Policy.keep_on_last_detach?("persistent", false)
      assert Policy.keep_on_last_detach?("persistent", true)
    end

    test "an ephemeral machine is kept only while somebody else is on it" do
      assert Policy.keep_on_last_detach?("ephemeral", true)
      refute Policy.keep_on_last_detach?("ephemeral", false)
    end

    test "a row with no mode is not a home" do
      refute Policy.keep_on_last_detach?(nil, false)
    end
  end

  describe "home?/1" do
    test "reads the mode off a row the caller has already read" do
      assert Policy.home?(%{mode: "persistent"})
      refute Policy.home?(%{mode: "ephemeral"})
      refute Policy.home?(%{mode: nil})
      refute Policy.home?(nil)
    end
  end

  # `mode == "persistent" or …` — the keep rule, as opposed to the many queries
  # that merely *find* a home.
  @last_detach_rule ~r/mode\s*==\s*"persistent"\s*or\b/

  describe "the call sites delegate" do
    setup do
      user = insert_verified_user()
      {:ok, user: user}
    end

    test "Lifecycle.idle_action/1 is this one" do
      cannot_park()
      assert Lifecycle.idle_action(:sprites) == Policy.idle_action(:sprites)
      assert Lifecycle.idle_action(:sprites) == :destroy
    end

    test "Lifecycle.idle_machine_action/1 is reclaim_action(:idle, …)" do
      can_park()
      handle = Managoat.Sandbox.build_handle(:sprites, "whatever")

      assert Lifecycle.idle_machine_action(handle) ==
               Policy.reclaim_action(:idle, :sprites, false)

      assert Lifecycle.idle_machine_action(handle) == :park
    end

    test "Lifecycle.max_lifetime_action/2 is reclaim_action(:max_lifetime, …) over home?", ctx do
      can_park()
      handle = Managoat.Sandbox.build_handle(:sprites, "whatever")

      home = insert_sandbox(user_id: ctx.user.id, status: "ready", mode: "persistent")
      ephemeral = insert_sandbox(user_id: ctx.user.id, status: "ready", mode: "ephemeral")

      assert Lifecycle.max_lifetime_action(home.id, handle) ==
               Policy.reclaim_action(:max_lifetime, :sprites, true)

      assert Lifecycle.max_lifetime_action(ephemeral.id, handle) ==
               Policy.reclaim_action(:max_lifetime, :sprites, false)

      assert Lifecycle.max_lifetime_action(home.id, handle) == :park
      assert Lifecycle.max_lifetime_action(ephemeral.id, handle) == :destroy
    end

    test "Lifecycle.home?/1 is Policy.home?/1 over the row it reads", ctx do
      home = insert_sandbox(user_id: ctx.user.id, status: "ready", mode: "persistent")
      ephemeral = insert_sandbox(user_id: ctx.user.id, status: "ready", mode: "ephemeral")

      assert Lifecycle.home?(home.id)
      refute Lifecycle.home?(ephemeral.id)
      refute Lifecycle.home?(nil)
      refute Lifecycle.home?(Ecto.UUID.generate())
    end

    test "nothing outside this module writes the last-detach rule again" do
      # The drift check, and it is deliberately narrow. Stage 6a found three
      # renderings of "is this machine held" that had already disagreed; this is
      # the same guard one layer up, scoped to the one shape that *is* the rule:
      # `mode == "persistent" or <somebody else is here>`.
      #
      # A bare `mode == "persistent"` is not scanned, because most of them are a
      # different question — `where: s.mode == "persistent"` finds an identity's
      # home in the index, which is a uniqueness rule rather than a decision
      # about what the mode means, and `Launch.home_or_new/5` is named in the
      # moduledoc as staying put for exactly that reason.
      root = Path.expand("../../../../..", __DIR__)

      files =
        ([Path.join(root, "apps/fountain/lib"), Path.join(root, "ee/lib")] ++
           Path.wildcard(Path.join(root, "apps/fountain_*/lib")))
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
        |> Enum.reject(&String.ends_with?(&1, "machines/policy.ex"))

      assert length(files) > 100, "the scan is broken; it proves nothing"

      # Guard the guard, against a sample rather than against `policy.ex`: this
      # module spells the rule as a function head now (`keep_on_last_detach?(
      # "persistent", _)`), so pointing the regex at it would couple the check to
      # how `Policy` happens to be written rather than to what a *copy* would
      # look like. What a copy looks like is `main`'s line, which is this:
      assert ~s|if mode == "persistent" or held_by_other?(id, ending) do| =~ @last_detach_rule,
             "the pattern no longer matches the shape it was written to find"

      refute ~s|where: s.mode == "persistent" and s.status not in ["terminated"]| =~
               @last_detach_rule,
             "the pattern matches an identity-index query, which is a different question"

      offenders =
        for file <- files,
            strip_comments(File.read!(file)) =~ @last_detach_rule,
            do: Path.relative_to(file, root)

      assert offenders == [],
             "these decide the last detach themselves rather than through " <>
               "`Fountain.Machines.Policy.keep_on_last_detach?/2` (ADR 0058): " <>
               inspect(offenders)
    end
  end

  # Whole-line comments only, blanked in place: a `mode == "persistent"` written
  # in prose about the rule is not a second copy of it.
  defp strip_comments(source) do
    source
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> if String.match?(line, ~r/^\s*#/), do: "", else: line end)
  end
end
