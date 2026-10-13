defmodule Fountain.AsyncGlobalConfigGuardrailTest do
  use ExUnit.Case, async: true

  @moduledoc """
  An `async: true` test module must not write `Application.put_env(:fountain, ...)`.

  Application env is global. ExUnit runs async modules concurrently, so a
  module that writes config changes it for every test running beside it, for
  as long as the write is held. When production code reads that key on a hot
  path, the result is a failure in a *different* file, on some seeds only, and
  usually not on the machine of whoever has to explain it.

  Two of these were live in the suite before this guardrail:

    * `quotas_test.exs` held `:sandboxes` `fleet_ceiling` at 2, and
      `conversations_start_test.exs` lost its tenant-cap assertions to
      `{:error, :fleet_full}`.
    * `user_emails_test.exs` held `:public_url` at `fountain.example.com`, and
      every `og:url` assertion in the suite failed while it did.

  Both now live in sibling `async: false` modules. ExUnit runs every async
  module first and the sync ones one at a time afterwards, so a sync module
  cannot overlap an async one — which is the whole fix, and the reason the
  answer here is "move it", not "add a lock".

  The allowlist is not a blessing. Each entry writes a key no concurrent test
  has been shown to read; none has been proven safe. Moving one into an
  `async: false` module is always correct, and is what to do the moment one of
  them is suspected in a flake. The list only shrinks.
  """

  # Paths are relative to the umbrella root, the way CLAUDE.md names them.
  #
  # Not a blessing. Each entry writes a key that no concurrent test has been
  # shown to read, which is weaker than "safe": the two that were moved out
  # were only caught because a reader happened to assert on the key. The keys
  # to fear are the ones production reads on a hot path — `:public_url` on
  # every render, `:sandboxes` on every reservation.
  #
  # The list only shrinks. Moving a file into a sibling `async: false` module
  # is always correct.
  @allowed [
    # :broker_allow_unenforced — read while provisioning a brokered sandbox.
    "apps/fountain/test/fountain/conversations/provisioning_test.exs",
    # :retention_days — read only by the pruner under test.
    "apps/fountain/test/fountain/workers/retention_pruner_test.exs",
    # :callback_key_ttl_seconds — read when a callback key is minted.
    "apps/fountain/test/fountain_web/api_key_scope_test.exs",
    # :runners_enabled — read by the agent surfaces.
    "apps/fountain/test/fountain_web/live/agents_live_test.exs"
  ]

  # The module's own `use` line, not the words anywhere in the file: these
  # modules explain in a comment which async module they were moved out of,
  # and a substring match reads that as a declaration.
  @async_use ~r/^\s*use\s+[\w.]+,\s*async:\s*true/m

  test "no async test module writes global application env" do
    root = Path.expand("../../../..", __DIR__)

    files =
      Path.wildcard(Path.join([root, "apps/fountain/test", "**/*_test.exs"]))

    assert files != [], "the guardrail found no test files — it would pass over anything"

    self = Path.relative_to(Path.expand(__ENV__.file), root)

    offenders =
      files
      |> Enum.reject(&(Path.relative_to(&1, root) == self))
      |> Enum.filter(fn abs ->
        body = File.read!(abs)

        Regex.match?(@async_use, body) and writes_env?(body)
      end)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(&1 in @allowed))
      |> Enum.sort()

    assert offenders == [], """
    These async test modules write global application env:

    #{Enum.map_join(offenders, "\n", &"  #{&1}")}

    Move the tests that write config into a sibling `async: false` module —
    see quotas_fleet_ceiling_test.exs — or, if the key is genuinely read by
    nothing that runs concurrently, add the file to @allowed here with a
    comment naming the key.
    """
  end

  # A commented-out or quoted call is not a call. Comment lines are dropped
  # before the match, which is also what keeps the sibling modules' own
  # explanations from reading as offences.
  defp writes_env?(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.any?(&String.contains?(&1, "Application.put_env(:fountain,"))
  end
end
