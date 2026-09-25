defmodule Fountain.Agents.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Fountain.Agents.Agent
  alias Fountain.Agents.ModelCatalog
  alias Fountain.RefusedModels

  # The suggestion list is Fountain's product data; the parser it is built on
  # is the library's (`Managoat.Runtimes.Model`, tested there). What is pinned
  # here is that the list and the changeset agree.

  test "providers/0 is the library's set, which is exactly what InferenceCredentials holds" do
    # The provider half is gated because this set is closed: it mirrors the
    # per-provider credential columns on InferenceCredentials.Credential
    # (anthropic_api_key / openai_api_key / gemini_api_key). Adding a provider
    # without a credential to export for it would put the old #554 bug back —
    # a sprite spawned with no inference key at all.
    assert ModelCatalog.providers() == ~w(anthropic openai google)
    assert ModelCatalog.providers() == Managoat.Runtimes.Model.providers()
  end

  test "suggestions/1 offers only the runtime's own provider" do
    for {runtime, provider} <- [
          {"claude", "anthropic"},
          {"codex", "openai"},
          {"gemini", "google"}
        ] do
      suggestions = ModelCatalog.suggestions(runtime)
      refute suggestions == []

      assert Enum.all?(suggestions, &String.starts_with?(&1, provider <> "/")),
             "#{runtime} was offered a foreign provider: #{inspect(suggestions)}"
    end
  end

  test "suggestions/1 offers every provider to opencode" do
    suggestions = ModelCatalog.suggestions("opencode")

    for provider <- ModelCatalog.providers() do
      assert Enum.any?(suggestions, &String.starts_with?(&1, provider <> "/"))
    end
  end

  test "every suggestion is a model the changeset accepts for its runtime" do
    for runtime <- Agent.runtimes(), model <- ModelCatalog.suggestions(runtime) do
      changeset =
        Agent.changeset(%Agent{}, %{name: "a", runtime: runtime, model: model})

      assert changeset.valid?,
             "#{runtime} suggestion #{model} is rejected: #{inspect(changeset.errors)}"
    end
  end

  # The registry lives in `Fountain.RefusedModels` so every surface that names
  # a model reads one list — see its moduledoc for why that matters.
  test "no suggestion is an id the pinned adapters are known to refuse" do
    suggested =
      Agent.runtimes() |> Enum.flat_map(&ModelCatalog.suggestions/1) |> MapSet.new()

    for {model, observed} <- RefusedModels.all() do
      refute MapSet.member?(suggested, model),
             """
             #{model} is suggested again, but the pinned ACP adapter refused it \
             on #{observed}. A refusal fails the turn before any prompt is sent \
             (#1640), so this suggestion is an outage for every agent that takes \
             it. Confirm the adapter accepts it on a real turn before relisting.
             """
    end
  end

  test "known?/1 recognises catalog entries and nothing else" do
    assert ModelCatalog.known?("anthropic/claude-opus-5")
    assert ModelCatalog.known?("anthropic/claude-opus-5-5")
    # Right provider, unlisted id — accepted by the changeset, just not listed.
    refute ModelCatalog.known?("anthropic/claude-opus-99")
    # Listed id under the wrong provider.
    refute ModelCatalog.known?("openai/claude-opus-5")
    refute ModelCatalog.known?("bare-id")
    refute ModelCatalog.known?(nil)
  end
end
