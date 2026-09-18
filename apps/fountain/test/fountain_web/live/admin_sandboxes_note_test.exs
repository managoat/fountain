defmodule FountainWeb.AdminSandboxesNoteTest do
  @moduledoc """
  What the admin table says about a machine's transition (ADR 0058 stage 9a).

  Its own module, and `async: false`, for one reason worth writing down.
  `FountainWeb.AdminLive.Sandboxes.lease_less_note/2` asks
  `Fountain.Machines.Machine.busy?/2`, `Machine` is Mimic-copied, and a module
  that runs `set_mimic_global` makes its stubs visible to every process — so an
  async test of this rule passes alone and fails in a full suite, depending on
  what happens to be running beside it. That is not a flake to re-run; it is a
  test reading another test's stub.

  Driven through the function rather than the rendered page, which is the other
  half of the same idea: a page-level assertion can only match strings across
  the whole document, so it reads every other row in the table and says nothing
  about the machine under test.
  """
  use ExUnit.Case, async: false
  use Mimic

  # `Fountain.Machines.Machine` is Mimic-copied in `test_helper.exs`, so a
  # process that has not declared Mimic does not reliably fall through to the
  # real `busy?/2` — this module read `false` for a live lease until it did.

  alias FountainWeb.AdminLive.Sandboxes

  # No clock is read. `lease_less_note/2` forwards whatever it is given to
  # `Lease.live?/2`, which takes a `DateTime`, so the rule under test — the
  # lease first, then the stamp — is driven without touching the database.
  @now ~U[2026-09-17 12:00:00.000000Z]

  defp at(seconds), do: DateTime.add(@now, seconds, :second)

  defp row(transition, lease_seconds),
    do: %{transition: transition, lease_node: "live@node", lease_until: at(lease_seconds)}

  test "a destroy in flight is not called unfinished" do
    # Surfaces S2. `destroying` reads differently from the other transitions
    # when its lease is dead — nothing clears it, so "abandoned" would be wrong
    # — but the lease still has to be asked *first*. A live lease means an owner
    # is working on the machine right now, the amber badge beside this note says
    # so, and the Reap button answers 503 busy. A row that rendered "an owner is
    # working" next to a word meaning "nobody is" would be the page
    # contradicting itself.
    assert Sandboxes.lease_less_note(row("destroying", 60), @now) == ""
    assert Sandboxes.lease_less_note(row("destroying", -60), @now) == " (unfinished)"
  end

  test "the abandonable transitions keep their word, with the same ordering" do
    for transition <- ~w(parking resuming provisioning retargeting) do
      assert Sandboxes.lease_less_note(row(transition, 60), @now) == ""
      assert Sandboxes.lease_less_note(row(transition, -60), @now) == " (abandoned)"
    end
  end

  test "a machine with no holder is never busy, whatever the deadline says" do
    # `Lease.live?/2` wants a holder *and* a deadline; a future `lease_until`
    # with no `lease_node` is a row nobody holds. Without this the two cases
    # above would both pass on a deadline check alone.
    nobody = %{transition: "destroying", lease_node: nil, lease_until: at(60)}

    assert Sandboxes.lease_less_note(nobody, @now) == " (unfinished)"
  end
end
