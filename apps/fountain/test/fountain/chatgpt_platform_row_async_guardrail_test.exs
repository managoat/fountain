defmodule Fountain.ChatGPTPlatformRowAsyncGuardrailTest do
  use ExUnit.Case, async: true

  @moduledoc """
  An `async: true` test module must not write the deployment's ChatGPT grant.

  Writing the null-owner row fires `fountain_lock_inference_source()`, which
  takes `'inference:platform'` exclusive for the transaction, and in the SQL
  sandbox the transaction is the whole test. Every concurrently running test
  that reaches `InferenceCredentials.lock_source/1` takes that key shared
  and parks until the writer's test ends, and the writer waits for every
  shared holder's test first. The cost lands as a slow suite or a query
  timeout in an unrelated file.

  ExUnit runs the sync modules one at a time after the async ones, so
  `async: false` is the whole fix. A user's grant row takes only its owner's
  key and is not covered here.
  """

  @async_use ~r/^\s*use\s+[\w.]+,\s*async:\s*true/m

  # `connect!/1` is `Fountain.ChatGPTFixtures`'; the second is every admin
  # connect in `Fountain.ChatGPTAccounts`; the third is a null-owner struct
  # piped into a changeset.
  @writes ["connect!(", "platform_connect_", "%Account{} |>"]

  test "no async test module writes the platform ChatGPT row" do
    root = Path.expand("../../../..", __DIR__)

    files =
      ["apps/fountain/test", "ee/test"]
      |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**/*_test.exs"])))

    assert files != [], "the guardrail found no test files — it would pass over anything"

    self = Path.relative_to(Path.expand(__ENV__.file), root)

    offenders =
      files
      |> Enum.reject(&(Path.relative_to(&1, root) == self))
      |> Enum.filter(fn abs ->
        body = File.read!(abs)
        Regex.match?(@async_use, body) and writes_platform_row?(body)
      end)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    assert offenders == [], """
    These async test modules write the platform ChatGPT grant row, which
    holds 'inference:platform' exclusive until the test ends:

    #{Enum.map_join(offenders, "\n", &"  #{&1}")}

    Make the module `async: false`, as every other module that connects the
    platform grant is.
    """
  end

  defp writes_platform_row?(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.any?(fn line -> Enum.any?(@writes, &String.contains?(line, &1)) end)
  end
end
