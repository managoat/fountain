defmodule Managoat.Runtimes.ModelTest do
  use ExUnit.Case, async: true

  alias Managoat.Runtimes

  defp agent(runtime, model), do: %{name: "a", runtime: runtime, model: model}

  describe "provider_for_runtime/1" do
    test "maps each single-provider runtime to its provider" do
      assert Runtimes.Model.provider_for_runtime("claude") == "anthropic"
      assert Runtimes.Model.provider_for_runtime("codex") == "openai"
      assert Runtimes.Model.provider_for_runtime("gemini") == "google"
    end

    test "returns nil for Fountain's acp runtime — it has no fixed provider" do
      assert Runtimes.Model.provider_for_runtime("acp") == nil
    end

    test "returns nil for anything unrecognised" do
      assert Runtimes.Model.provider_for_runtime("nope") == nil
      assert Runtimes.Model.provider_for_runtime(nil) == nil
    end
  end

  describe "split/1" do
    test "splits a canonical model on the first slash only" do
      assert Runtimes.Model.split("anthropic/claude-sonnet-4-6") ==
               {"anthropic", "claude-sonnet-4-6"}

      assert Runtimes.Model.split("openrouter/meta/llama-3") == {"openrouter", "meta/llama-3"}
    end

    test "refuses to guess at anything non-canonical" do
      for bad <- ["claude-sonnet-4-6", "anthropic/", "/gpt-5", "", nil] do
        assert Runtimes.Model.split(bad) == {nil, nil}
      end
    end
  end

  describe "the provider set" do
    # The set is closed because it is what the runtimes can be handed a
    # credential for: each single-provider runtime reaches exactly one of
    # them. A host gates the provider half of a model on this at write time;
    # the suggestion catalog that goes with it is the host's (in Fountain,
    # the `Agents.ModelCatalog` module, tested there).
    test "providers/0 is exactly the set a runtime can be given a credential for" do
      assert Runtimes.Model.providers() == ~w(anthropic openai google)

      for runtime <- ~w(claude codex gemini) do
        assert Runtimes.Model.provider_for_runtime(runtime) in Runtimes.Model.providers()
      end
    end

    test "known_provider?/1 accepts the three and nothing else" do
      assert Runtimes.Model.known_provider?("anthropic")
      assert Runtimes.Model.known_provider?("openai")
      assert Runtimes.Model.known_provider?("google")
      refute Runtimes.Model.known_provider?("anthopic")
      refute Runtimes.Model.known_provider?("openrouter")
      refute Runtimes.Model.known_provider?(nil)
    end
  end

  describe "acp_model/2" do
    test "a single-provider runtime gets the bare id" do
      assert Runtimes.Model.acp_model("claude", "anthropic/claude-sonnet-4-6") ==
               "claude-sonnet-4-6"

      assert Runtimes.Model.acp_model("codex", "openai/gpt-5.3-codex") == "gpt-5.3-codex"
    end

    test "a runtime with no fixed provider gets the canonical id" do
      assert Runtimes.Model.acp_model("acp", "anthropic/claude-sonnet-4-6") ==
               "anthropic/claude-sonnet-4-6"
    end

    test "no parseable model, nothing to pin" do
      assert Runtimes.Model.acp_model("acp", "claude-sonnet-4-6") == nil
      assert Runtimes.Model.acp_model("claude", nil) == nil
    end

    test "a non-string runtime is treated as single-provider, never as provider-less" do
      assert Runtimes.Model.acp_model(nil, "openai/gpt-5.3-codex") == "gpt-5.3-codex"
      assert Runtimes.Model.acp_model(%{}, "bare-id") == nil
    end
  end

  describe "model_args/1" do
    test "strips the provider prefix" do
      assert Runtimes.Model.model_args(agent("claude", "anthropic/claude-sonnet-4-6")) ==
               ["--model", "claude-sonnet-4-6"]
    end

    test "passes no flag when there is no parseable model" do
      assert Runtimes.Model.model_args(agent("claude", nil)) == []
      assert Runtimes.Model.model_args(agent("claude", "bare-id")) == []
      assert Runtimes.Model.model_args(%{}) == []
    end
  end

  # The regression #553 describes: runtimes built argv that never mentioned
  # agent.model, so the CLI's own default ran instead.
  #
  # No runtime builds argv any more. gemini was the last one, and #941 deleted
  # its `build_command/5` along with the `--approval-mode yolo` it carried. The
  # model is pinned per session over ACP now — see "model selection" in
  # `acp/peer_test.exs`, which is where this regression is guarded.
  #
  # `Model.model_args/1` itself is still tested above: it is what an argv-based
  # runtime would use, and it is cheaper to keep than to re-derive if a fifth
  # runtime ever arrives that cannot speak ACP.
end
