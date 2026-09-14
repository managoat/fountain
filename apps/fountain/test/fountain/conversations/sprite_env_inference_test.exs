defmodule Fountain.Conversations.SpriteEnvInferenceTest do
  @moduledoc """
  The source `InferenceCredentials.resolve/4` selects for a conversation's
  agent, and the credentials it hands provisioning (ADR 0053).

  These cases used to run through `SpriteEnv.select_inference/4`, a
  value-only wrapper with no production caller. They now go through the
  resolver admission and provisioning call, with the credential set, the
  vault and the platform key persisted where production reads them.

  `async: false`, and in its own module rather than beside the rest of
  `SpriteEnvTest`: the platform keys live in the global application
  environment, so a module that writes them races every module that reads
  them, and a module that only reads them races anything that writes (#1214).
  """

  use Fountain.DataCase, async: false

  alias Fountain.{Crypto, InferenceCredentials}
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

    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    %{user: user, dek: dek}
  end

  defp agent_on(user, model), do: insert_agent(user_id: user.id, runtime: "claude", model: model)

  # What admission and provisioning ask: the agent's model and runtime, the
  # launch's vault, and the account default set.
  defp resolve(user, agent, opts \\ []),
    do: InferenceCredentials.resolve(user.id, agent.model, agent.runtime, opts)

  defp own!(user, dek, kind, value) do
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, kind, value)
    :ok
  end

  defp vault_with(user, secrets) do
    vault = insert_vault(user_id: user.id)
    for {key, value} <- secrets, do: insert_vault_secret(vault, key: key, value: value)
    vault
  end

  describe "resolve/4" do
    test "the tenant's own credential is scope :credential", %{user: user, dek: dek} do
      own!(user, dek, :anthropic_api_key, "sk-tenant")

      assert {:ok, %Source{origin: :own, scope: :credential, kind: :anthropic_api_key},
              %{anthropic_api_key: "sk-tenant"}} = resolve(user, agent_on(user, @anthropic))
    end

    test "the deployment's key is :platform, merged in under the provider's credential",
         %{user: user} do
      Application.put_env(:fountain, :platform_anthropic_api_key, "sk-platform")

      assert {:ok, %Source{origin: :platform, scope: :platform}, creds} =
               resolve(user, agent_on(user, @anthropic))

      assert creds.anthropic_api_key == "sk-platform"
    end

    test "the tenant's own credential still wins over a configured platform key",
         %{user: user, dek: dek} do
      Application.put_env(:fountain, :platform_anthropic_api_key, "sk-platform")
      own!(user, dek, :anthropic_api_key, "sk-tenant")

      assert {:ok, %Source{origin: :own}, %{anthropic_api_key: "sk-tenant"}} =
               resolve(user, agent_on(user, @anthropic))
    end
  end

  # The two halves of what used to be one `:own`. Both keep `origin: :own`, so
  # neither is platform-paid and the usage stamp is byte-for-byte what it was.
  # They are separate because they are opposite answers to "is anything wrong
  # here", and only the source can tell a surface which.
  describe "resolve/4 with no credential anywhere" do
    # A model and runtime, not a persisted agent: `Agent.changeset/2` refuses
    # a model whose provider is not one of the three Fountain holds a
    # credential for (#554), so no row can carry `ollama/`. The case is still
    # reachable — a provider that stops being known, or a gateway model
    # reaching selection by another door.
    test "a provider that needs none is :none", %{user: user} do
      assert {:ok, %Source{origin: :own, scope: :none}, %{}} =
               InferenceCredentials.resolve(user.id, "ollama/llama3", "opencode", [])
    end

    test "a conversation with no agent needs none either", %{user: user} do
      assert {:ok, %Source{origin: :own, scope: :none}, %{}} =
               InferenceCredentials.resolve(user.id, nil, nil, [])
    end

    test "a provider that needs one nobody has is :missing, and still provisions",
         %{user: user} do
      assert {:ok, %Source{origin: :own, scope: :missing}, %{}} =
               resolve(user, agent_on(user, @anthropic))
    end
  end

  # ADR 0053 decision 5. A tenant secret named after a credential overrides it
  # in the sandbox — `Egress`'s gate-3 split says so and
  # `docs/concepts/secrets.md` publishes it — but selection could not see it,
  # so the deployment's key was selected, the turn was stamped `"platform"`,
  # priced against the tenant's credits and counted against the daily ceiling,
  # while the tenant's own secret served every one of them.
  describe "resolve/4 with a tenant secret shadowing a credential" do
    test "is :own, not :platform, even with a platform key configured", %{user: user} do
      Application.put_env(:fountain, :platform_anthropic_api_key, "sk-platform")
      vault = vault_with(user, %{"ANTHROPIC_API_KEY" => "sk-from-the-vault"})

      assert {:ok, %Source{origin: :own, scope: :tenant_secret} = source, creds} =
               resolve(user, agent_on(user, @anthropic), vault_id: vault.id)

      assert creds == %{anthropic_api_key: "sk-from-the-vault"}
      assert source.identity =~ "vault:#{vault.id}:"
    end

    test "an OAuth token by name counts for anthropic too", %{user: user} do
      Application.put_env(:fountain, :platform_anthropic_api_key, "sk-platform")
      vault = vault_with(user, %{"CLAUDE_CODE_OAUTH_TOKEN" => "oauth-from-the-vault"})

      assert {:ok, %Source{scope: :tenant_secret},
              %{claude_code_oauth_token: "oauth-from-the-vault"}} =
               resolve(user, agent_on(user, @anthropic), vault_id: vault.id)
    end

    test "a secret for another provider does not shadow this one", %{user: user} do
      Application.put_env(:fountain, :platform_anthropic_api_key, "sk-platform")
      vault = vault_with(user, %{"OPENAI_API_KEY" => "sk-openai", "UNRELATED" => "x"})

      assert {:ok, %Source{origin: :platform}, _} =
               resolve(user, agent_on(user, @anthropic), vault_id: vault.id)
    end

    test "with no platform key it is still :own rather than :missing", %{user: user} do
      vault = vault_with(user, %{"ANTHROPIC_API_KEY" => "sk-from-the-vault"})

      assert {:ok, %Source{origin: :own, scope: :tenant_secret},
              %{anthropic_api_key: "sk-from-the-vault"}} =
               resolve(user, agent_on(user, @anthropic), vault_id: vault.id)
    end

    test "a secret overrides the same kind and its source is reported", %{user: user, dek: dek} do
      own!(user, dek, :anthropic_api_key, "sk-row")
      vault = vault_with(user, %{"ANTHROPIC_API_KEY" => "sk-from-the-vault"})

      assert {:ok, %Source{origin: :own, scope: :tenant_secret},
              %{anthropic_api_key: "sk-from-the-vault"}} =
               resolve(user, agent_on(user, @anthropic), vault_id: vault.id)
    end
  end
end
