defmodule Fountain.Conversations.InferenceProcessEnvTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.{Identity, Provisioning, Redaction, SpriteEnv}
  alias Fountain.{Environments, Vaults}
  alias Managoat.Runtimes.{Claude, Codex, Gemini, OpenCode}

  @names ~w(ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY
            GEMINI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY)

  test "each pinned runtime exports its credential to the process but not the shared file" do
    cases = [
      {Claude, "anthropic/claude", :anthropic_api_key, "ANTHROPIC_API_KEY"},
      {Claude, "anthropic/claude", :claude_code_oauth_token, "CLAUDE_CODE_OAUTH_TOKEN"},
      {Codex, "openai/gpt", :openai_api_key, "OPENAI_API_KEY"},
      {Gemini, "google/gemini", :gemini_api_key, "GEMINI_API_KEY"},
      {OpenCode, "anthropic/claude", :anthropic_api_key, "ANTHROPIC_API_KEY"},
      {OpenCode, "openai/gpt", :openai_api_key, "OPENAI_API_KEY"},
      {OpenCode, "google/gemini", :gemini_api_key, "GOOGLE_GENERATIVE_AI_API_KEY"}
    ]

    for {runtime, model, credential, name} <- cases do
      sprite_env = build(%{model: model}, nil, %{}, runtime, %{credential => "runtime-bearer"})
      assert {name, "runtime-bearer"} in sprite_env
      assert_disk_excludes_auth(sprite_env)
    end
  end

  test "environment and vault credentials and aliases remain process inputs only" do
    user = insert_verified_user()
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
    env = insert_env(user_id: user.id)
    vault = insert_vault(user_id: user.id)

    for name <- @names do
      assert {:ok, _} =
               Environments.upsert_secret(env, %{"key" => name, "value" => "env-bearer"}, dek)

      assert {:ok, _} =
               Vaults.upsert_secret(vault, %{"key" => name, "value" => "vault-bearer"}, dek)
    end

    for {selected_vault, expected} <- [{nil, "env-bearer"}, {vault, "vault-bearer"}] do
      secrets = SpriteEnv.merge_secrets(env, selected_vault, dek)
      sprite_env = build(nil, env, Map.put(secrets, "TOOL_SECRET", "tool-value"), Claude, %{})
      for name <- @names, do: assert({name, expected} in sprite_env)
      assert {"TOOL_SECRET", "tool-value"} in Identity.disk_env(sprite_env)
      assert_disk_excludes_auth(sprite_env)
    end
  end

  # Only a source that is a managed grant exports the name at all: see "a
  # managed ChatGPT grant" below. The credentials map alone does not.
  test "the managed name is never exported from the credentials map alone" do
    placeholder = Fountain.Broker.placeholder("CODEX_CHATGPT_ACCESS_TOKEN")
    sprite_env = build(nil, nil, %{}, Codex, %{codex_chatgpt_access_token: placeholder})
    refute List.keymember?(sprite_env, "CODEX_CHATGPT_ACCESS_TOKEN", 0)
    assert_disk_excludes_auth(sprite_env)
  end

  # ADR 0060 decision 6: a user's subscription gets a `CODEX_HOME` of its own
  # per grant and generation. It is per conversation, so it is process env.
  describe "a managed ChatGPT grant" do
    setup do
      grant_id = Ecto.UUID.generate()
      generation = Ecto.UUID.generate()

      source = %{
        Fountain.InferenceCredentials.Source.grant()
        | kind: :codex_chatgpt_access_token,
          grant_id: grant_id,
          generation: generation
      }

      {:ok,
       source: source,
       home: "/home/sprite/.codex-grants/#{grant_id}.#{generation}",
       placeholder: Fountain.ChatGPTAccounts.Reserved.placeholder(grant_id)}
    end

    test "its placeholder and its home reach the process and never the shared file", ctx do
      creds = %{codex_chatgpt_access_token: ctx.placeholder}
      {sprite_env, conv_id} = build_for(ctx.source, nil, %{}, creds)

      assert {"CODEX_CHATGPT_ACCESS_TOKEN", ctx.placeholder} in sprite_env
      assert {"CODEX_HOME", ctx.home} in sprite_env
      assert_disk_excludes_auth(sprite_env)
      refute List.keymember?(Identity.disk_env(sprite_env), "CODEX_HOME", 0)

      # A placeholder is not a secret and ends in `__` (#2366).
      registered = Redaction.lookup(conv_id)
      assert "cb-token" in registered
      refute ctx.placeholder in registered
    end

    test "a tenant CODEX_HOME cannot point codex back at the shared auth file", ctx do
      env = %Fountain.Environments.Environment{
        env_vars: %{"CODEX_HOME" => "/home/sprite/.codex", "PLAIN" => "p"}
      }

      secrets = %{"CODEX_HOME" => "/home/sprite/.codex", "TOOL_SECRET" => "kept"}
      {sprite_env, _} = build_for(ctx.source, env, secrets, %{})

      assert for({"CODEX_HOME", value} <- sprite_env, do: value) == [ctx.home]
      assert {"PLAIN", "p"} in sprite_env
      assert {"TOOL_SECRET", "kept"} in sprite_env
    end

    test "any other source keeps a tenant CODEX_HOME, on the disk as before" do
      env = %Fountain.Environments.Environment{env_vars: %{"CODEX_HOME" => "/opt/codex"}}

      for source <- [nil, Fountain.InferenceCredentials.Source.credential()] do
        {sprite_env, _} = build_for(source, env, %{}, %{openai_api_key: "sk-own"})
        assert {"CODEX_HOME", "/opt/codex"} in sprite_env
        assert {"CODEX_HOME", "/opt/codex"} in Identity.disk_env(sprite_env)
      end
    end

    defp build_for(source, env, secrets, credentials) do
      conv_id = Ecto.UUID.generate()
      on_exit(fn -> Redaction.delete(conv_id) end)

      sprite_env =
        SpriteEnv.build(%{model: "gpt-5", runtime: "codex"}, env, secrets,
          runtime_module: Codex,
          env_credentials: credentials,
          callback_token: "cb-token",
          conversation_id: conv_id,
          sandbox_id: nil,
          inference_source: source
        )

      {sprite_env, conv_id}
    end
  end

  defp build(agent, env, secrets, runtime, credentials) do
    conv_id = Ecto.UUID.generate()
    on_exit(fn -> Redaction.delete(conv_id) end)

    SpriteEnv.build(agent, env, secrets,
      runtime_module: runtime,
      env_credentials: credentials,
      callback_token: nil,
      conversation_id: conv_id,
      sandbox_id: nil
    )
  end

  defp assert_disk_excludes_auth(sprite_env) do
    body = sprite_env |> Identity.disk_env() |> Provisioning.render_env_file()

    for name <- ["CODEX_CHATGPT_ACCESS_TOKEN" | @names] do
      refute body =~ "#{name}="
    end
  end
end
