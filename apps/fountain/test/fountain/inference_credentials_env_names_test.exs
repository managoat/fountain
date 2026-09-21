defmodule Fountain.InferenceCredentialsEnvNamesTest do
  @moduledoc """
  `InferenceCredentials.env_names/0` against `Broker.inference_keys/0`.

  Two tables map a credential to the environment variable it is exported as:
  the broker's, which builds the gate-3 placeholders, and this context's,
  which decides whether a tenant secret shadows a credential (ADR 0053
  decision 5). A disagreement is silent in both directions — a name only this
  one knows is a placeholder nobody substitutes, and a name only the broker
  knows is an override selection cannot see, which is the bug decision 5
  exists to fix. Hold them together here rather than merging them: the broker
  carries hosts and the managed grant, and this context must not carry either.
  """

  use ExUnit.Case, async: true

  alias Fountain.Broker
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Credential

  test "every static credential has a name, and it is the broker's" do
    names = InferenceCredentials.env_names()
    broker = Broker.inference_keys()

    assert Map.keys(names) |> Enum.sort() == Enum.sort(Credential.providers())

    for {credential, name} <- names do
      assert Map.get(broker, name) == credential,
             "#{name} maps to #{inspect(credential)} here and " <>
               "#{inspect(Map.get(broker, name))} in Fountain.Broker"
    end
  end

  test "runtime aliases retain the canonical broker name first" do
    assert InferenceCredentials.env_aliases() == %{
             anthropic_api_key: ["ANTHROPIC_API_KEY"],
             claude_code_oauth_token: ["CLAUDE_CODE_OAUTH_TOKEN"],
             openai_api_key: ["OPENAI_API_KEY"],
             gemini_api_key: ["GEMINI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"]
           }

    for {credential, [canonical | _]} <- InferenceCredentials.env_aliases() do
      assert InferenceCredentials.env_names()[credential] == canonical
    end
  end

  # ADR 0052 decision 6: configuration may neither name the managed grant nor
  # embed its placeholder, so it is not a credential a tenant secret can
  # shadow. Protect managed credentials; resolve ordinary tenant overrides.
  test "the managed ChatGPT grant is not one of them" do
    names = InferenceCredentials.env_names()

    refute Map.has_key?(names, :codex_chatgpt_access_token)
    refute "CODEX_CHATGPT_ACCESS_TOKEN" in Map.values(names)
    # Nor is it a key the broker substitutes: a managed grant rides the
    # protected path, as a session's authorization and never as a rule.
    refute Map.has_key?(Broker.inference_keys(), "CODEX_CHATGPT_ACCESS_TOKEN")
  end
end
