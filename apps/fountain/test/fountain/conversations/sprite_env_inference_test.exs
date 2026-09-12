defmodule Fountain.Conversations.SpriteEnvInferenceTest do
  @moduledoc """
  `SpriteEnv.select_inference/3` and the source it resolves (ADR 0053).

  `async: false`, and in its own module rather than beside the rest of
  `SpriteEnvTest`: the platform keys live in the global application
  environment, so a module that writes them races every module that reads
  them, and a module that only reads them races anything that writes (#1214).
  """

  use Fountain.DataCase, async: false

  alias Fountain.Conversations.SpriteEnv
  alias Fountain.InferenceCredentials.Source

  @anthropic "anthropic/claude-opus-5"

  setup do
    previous =
      for key <- [:platform_anthropic_api_key, :platform_openai_api_key, :platform_gemini_api_key],
          do: {key, Application.get_env(:fountain, key)}

    for {key, _} <- previous, do: Application.delete_env(:fountain, key)

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    %{user: insert_verified_user()}
  end

  defp agent_on(user, model), do: insert_agent(user_id: user.id, runtime: "claude", model: model)

  describe "select_inference/3" do
    test "the tenant's own credential is scope :credential", %{user: user} do
      own = %{anthropic_api_key: "sk-tenant"}

      assert {%Source{origin: :own, scope: :credential}, ^own} =
               SpriteEnv.select_inference(agent_on(user, @anthropic), own)
    end

    test "the deployment's key is :platform, merged in under the provider's credential",
         %{user: user} do
      Application.put_env(:fountain, :platform_anthropic_api_key, "sk-platform")

      assert {%Source{origin: :platform, scope: :platform}, creds} =
               SpriteEnv.select_inference(agent_on(user, @anthropic), %{})

      assert creds.anthropic_api_key == "sk-platform"
    end

    test "the tenant's own credential still wins over a configured platform key", %{user: user} do
      Application.put_env(:fountain, :platform_anthropic_api_key, "sk-platform")
      own = %{anthropic_api_key: "sk-tenant"}

      assert {%Source{origin: :own}, ^own} =
               SpriteEnv.select_inference(agent_on(user, @anthropic), own)
    end
  end

  # The two halves of what used to be one `:own`. Both keep `origin: :own`, so
  # neither is platform-paid and the usage stamp is byte-for-byte what it was.
  # They are separate because they are opposite answers to "is anything wrong
  # here", and only the source can tell a surface which.
  describe "select_inference/3 with no credential anywhere" do
    # A bare map, not a persisted agent: `Agent.changeset/2` refuses a model
    # whose provider is not one of the three Fountain holds a credential for
    # (#554), so no row can carry `ollama/`. `select_inference/3` takes a map
    # by contract and the case is still reachable — a provider that stops
    # being known, or a gateway model reaching selection by another door.
    test "a provider that needs none is :none", %{user: user} do
      agent = %{user_id: user.id, runtime: "opencode", model: "ollama/llama3"}

      assert {%Source{origin: :own, scope: :none}, %{}} = SpriteEnv.select_inference(agent, %{})
    end

    test "a conversation with no agent needs none either" do
      assert {%Source{origin: :own, scope: :none}, %{}} = SpriteEnv.select_inference(nil, %{})
    end

    test "a provider that needs one nobody has is :missing, and still provisions",
         %{user: user} do
      assert {%Source{origin: :own, scope: :missing}, %{}} =
               SpriteEnv.select_inference(agent_on(user, @anthropic), %{})
    end
  end
end
