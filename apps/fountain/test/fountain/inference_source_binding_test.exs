defmodule Fountain.InferenceSourceBindingTest do
  use Fountain.DataCase, async: false

  alias Fountain.{Crypto, Environments, InferenceCredentials, PlatformInference, Vaults}
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Conversations.{InferenceBinding, SpriteEnv}

  setup do
    user = insert_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    %{user: user, dek: dek}
  end

  defp vault_with(user, secrets) do
    vault = insert_vault(user_id: user.id)
    for {key, value} <- secrets, do: insert_vault_secret(vault, key: key, value: value)
    vault
  end

  test "runtime precedence and same-kind overrides select the value actually exported", %{
    user: user,
    dek: dek
  } do
    {:ok, _} =
      InferenceCredentials.put_credential(user.id, dek, :claude_code_oauth_token, "oauth")

    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "api")
    vault = vault_with(user, %{"ANTHROPIC_API_KEY" => "override"})

    assert {:ok, %{kind: :claude_code_oauth_token, scope: :credential},
            %{claude_code_oauth_token: "oauth"}} =
             InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "claude",
               vault_id: vault.id
             )

    assert {:ok, %{kind: :anthropic_api_key, scope: :tenant_secret},
            %{anthropic_api_key: "override"}} =
             InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "opencode",
               vault_id: vault.id
             )

    {:ok, oauth_only} = InferenceCredentials.create_set(user.id, "OAuth only")

    {:ok, oauth_only} =
      InferenceCredentials.put_credential_in(oauth_only, dek, :claude_code_oauth_token, "oauth")

    assert {:error, :inference_credential_unusable} =
             InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "opencode",
               credential_set_id: oauth_only.id
             )
  end

  test "aliases normalize within a layer and reject only conflicting values for the selected provider",
       %{user: user, dek: dek} do
    google = vault_with(user, %{"GEMINI_API_KEY" => "google"})

    assert {:ok, %{kind: :gemini_api_key}, %{gemini_api_key: "google"}} =
             InferenceCredentials.resolve(user.id, "google/gemini-2.5-pro", "opencode",
               vault_id: google.id
             )

    conflicting =
      vault_with(user, %{"GEMINI_API_KEY" => "one", "GOOGLE_GENERATIVE_AI_API_KEY" => "two"})

    assert {:error, :inference_credential_conflict} =
             InferenceCredentials.resolve(user.id, "google/gemini-2.5-pro", "opencode",
               vault_id: conflicting.id
             )

    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "api")

    assert {:ok, %{kind: :anthropic_api_key}, _} =
             InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "claude",
               vault_id: conflicting.id
             )
  end

  test "vault aliases override the environment by kind, with a durable source reference", %{
    user: user
  } do
    env = insert_env(user_id: user.id, env_vars: %{"GEMINI_API_KEY" => "environment"})
    vault = insert_vault(user_id: user.id)
    secret = insert_vault_secret(vault, key: "GOOGLE_GENERATIVE_AI_API_KEY", value: "vault")

    assert {:ok, source, %{gemini_api_key: "vault"}} =
             InferenceCredentials.resolve(user.id, "google/gemini-2.5-pro", "opencode",
               environment_id: env.id,
               vault_id: vault.id
             )

    assert source.identity == "vault:#{vault.id}:#{secret.id}"
    assert source.revision == secret.inference_revision
    assert Source.load(Source.dump(source)) == source
    refute inspect(Source.dump(source)) =~ "environment\""
  end

  test "a pinned absence of a set does not adopt a later account default", %{user: user, dek: dek} do
    env = insert_env(user_id: user.id, env_vars: %{"OPENAI_API_KEY" => "environment-key"})

    {:ok, source, _} =
      InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex", environment_id: env.id)

    assert source.set_id == nil
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "new-default")
    assert :ok = InferenceCredentials.validate_source(user.id, source)
  end

  test "renames retain a binding and replacement changes its revision even when restored", %{
    user: user,
    dek: dek
  } do
    {:ok, set} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "first")

    {:ok, source, _} =
      InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "claude")

    {:ok, renamed} = InferenceCredentials.rename_set(set, "Renamed")
    assert :ok = InferenceCredentials.validate_source(user.id, source)

    {:ok, changed} =
      InferenceCredentials.put_credential_in(renamed, dek, :anthropic_api_key, "second")

    {:ok, restored} =
      InferenceCredentials.put_credential_in(changed, dek, :anthropic_api_key, "first")

    refute restored.revision == source.revision

    assert {:error, :inference_source_changed} =
             InferenceCredentials.validate_source(user.id, source)
  end

  test "default switches preserve the original set while deletion refuses fallback", %{
    user: user,
    dek: dek
  } do
    {:ok, first} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "first")

    {:ok, source, _} =
      InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "claude")

    {:ok, second} = InferenceCredentials.create_set(user.id, "Second")

    {:ok, second} =
      InferenceCredentials.put_credential_in(second, dek, :anthropic_api_key, "second")

    {:ok, _} = InferenceCredentials.set_default(second)
    assert :ok = InferenceCredentials.validate_source(user.id, source)
    {:ok, _} = InferenceCredentials.delete_set(InferenceCredentials.get_set(first.id, user.id))

    assert {:error, :inference_source_changed} =
             InferenceCredentials.validate_source(user.id, source)

    assert {:error, :inference_credential_not_found} =
             InferenceCredentials.decrypted_for(user.id, first.id, dek)
  end

  test "plain environment changes and restorations require explicit reselection", %{user: user} do
    env = insert_env(user_id: user.id, env_vars: %{"OPENAI_API_KEY" => "first"})

    {:ok, source, _} =
      InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex", environment_id: env.id)

    {:ok, env} =
      Environments.update_environment(env, %{"env_vars" => %{"OPENAI_API_KEY" => "second"}})

    {:ok, _} =
      Environments.update_environment(env, %{"env_vars" => %{"OPENAI_API_KEY" => "first"}})

    assert {:error, :inference_source_changed} =
             InferenceCredentials.validate_source(user.id, source)
  end

  test "encrypted environment and vault replacement cannot silently fall back", %{
    user: user,
    dek: dek
  } do
    for type <- [:environment, :vault] do
      parent =
        if type == :environment,
          do: insert_env(user_id: user.id),
          else: insert_vault(user_id: user.id)

      context = if type == :environment, do: Environments, else: Vaults

      {:ok, _} =
        context.upsert_secret(parent, %{"key" => "OPENAI_API_KEY", "value" => "first"}, dek)

      opts = if type == :environment, do: [environment_id: parent.id], else: [vault_id: parent.id]
      {:ok, source, _} = InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex", opts)

      {:ok, _} =
        context.upsert_secret(parent, %{"key" => "OPENAI_API_KEY", "value" => "second"}, dek)

      {:ok, _} =
        context.upsert_secret(parent, %{"key" => "OPENAI_API_KEY", "value" => "first"}, dek)

      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(user.id, source)
    end
  end

  test "stored platform key replacement retains no stale binding", %{user: user} do
    {:ok, key} = PlatformInference.put_key("openai", "first")
    {:ok, source, _} = InferenceCredentials.resolve(user.id, "openai/gpt-5", "opencode")
    assert source.identity == "platform:stored:openai"
    assert source.revision == key.revision
    {:ok, _} = PlatformInference.put_key("openai", "second")

    assert {:error, :inference_source_changed} =
             InferenceCredentials.validate_source(user.id, source)
  end

  test "Codex reserves pending peers by identity and revision before preparation", %{
    user: user,
    dek: dek
  } do
    {:ok, set} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "first")
    {:ok, source, _} = InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex")
    sandbox = insert_sandbox(user_id: user.id)
    first = insert_conversation(user_id: user.id, sandbox: sandbox, runtime: "codex")
    assert :ok = InferenceBinding.reserve(first, source)
    second = insert_conversation(user_id: user.id, sandbox: sandbox, runtime: "codex")
    assert :ok = InferenceBinding.reserve(second, source)
    {:ok, _} = InferenceCredentials.put_credential_in(set, dek, :openai_api_key, "replacement")
    {:ok, replacement, _} = InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex")
    third = insert_conversation(user_id: user.id, sandbox: sandbox, runtime: "codex")
    assert {:error, :codex_inference_conflict} = InferenceBinding.reserve(third, replacement)
    Repo.update!(Ecto.Changeset.change(first, status: "failed"))
    Repo.update!(Ecto.Changeset.change(second, status: "terminated"))
    assert {:error, :codex_inference_conflict} = InferenceBinding.reserve(third, replacement)
    Enum.each([first, second, third], &Repo.delete!/1)
    fourth = insert_conversation(user_id: user.id, sandbox: sandbox, runtime: "codex")
    assert {:error, :codex_inference_conflict} = InferenceBinding.reserve(fourth, replacement)
  end

  test "unbound legacy Codex machines refuse a source even without other conversations", %{
    user: user,
    dek: dek
  } do
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "new-key")
    {:ok, source, _} = InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex")
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, runtime: "codex")
    assert {:error, :codex_inference_conflict} = InferenceBinding.reserve(conv, source)
    assert Repo.reload!(sandbox).codex_inference_source == nil
  end

  test "runtime environment removes competing auth inputs but preserves unrelated tools", %{
    user: user
  } do
    env =
      insert_env(
        user_id: user.id,
        env_vars: %{"ANTHROPIC_API_KEY" => "loser", "GEMINI_API_KEY" => "tool"}
      )

    agent = %{model: "anthropic/claude-sonnet-5"}

    pairs =
      SpriteEnv.build(agent, env, %{"ANTHROPIC_API_KEY" => "another-loser"},
        runtime_module: Managoat.Runtimes.Claude,
        env_credentials: %{claude_code_oauth_token: "winner"},
        conversation_id: Ecto.UUID.generate(),
        callback_token: nil,
        sandbox_id: nil
      )

    assert {"CLAUDE_CODE_OAUTH_TOKEN", "winner"} in pairs
    refute List.keymember?(pairs, "ANTHROPIC_API_KEY", 0)
    assert {"GEMINI_API_KEY", "tool"} in pairs
  end
end
