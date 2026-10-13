defmodule Fountain.Conversations.InferenceProcessEnvTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.{Identity, Provisioning, Redaction, SpriteEnv}
  alias Fountain.{Environments, Vaults}
  alias Managoat.Runtimes.{Claude, Codex, Gemini}

  @names ~w(ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY
            GEMINI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY)

  test "each pinned runtime exports its credential to the process but not the shared file" do
    cases = [
      {Claude, "anthropic/claude", :anthropic_api_key, "ANTHROPIC_API_KEY"},
      {Claude, "anthropic/claude", :claude_code_oauth_token, "CLAUDE_CODE_OAUTH_TOKEN"},
      {Codex, "openai/gpt", :openai_api_key, "OPENAI_API_KEY"},
      {Gemini, "google/gemini", :gemini_api_key, "GEMINI_API_KEY"}
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

  # A tenant's own CODEX_HOME is machine-wide configuration and stays on the
  # disk.
  test "a tenant CODEX_HOME reaches the shared file" do
    env = %Fountain.Environments.Environment{env_vars: %{"CODEX_HOME" => "/opt/codex"}}
    sprite_env = build(%{model: "gpt-5"}, env, %{}, Codex, %{openai_api_key: "sk-own"})
    assert {"CODEX_HOME", "/opt/codex"} in sprite_env
    assert {"CODEX_HOME", "/opt/codex"} in Identity.disk_env(sprite_env)
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

    for name <- @names do
      refute body =~ "#{name}="
    end
  end
end
