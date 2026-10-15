defmodule Fountain.InferenceSourceBindingTest do
  use Fountain.DataCase, async: false

  alias Fountain.{Crypto, Environments, InferenceCredentials, Vaults}
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

  test "kind precedence and same-kind overrides select the value actually exported", %{
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
  end

  test "aliases normalize within a layer and reject only conflicting values for the selected provider",
       %{user: user, dek: dek} do
    google = vault_with(user, %{"GEMINI_API_KEY" => "google"})

    assert {:ok, %{kind: :gemini_api_key}, %{gemini_api_key: "google"}} =
             InferenceCredentials.resolve(user.id, "google/gemini-2.5-pro", "gemini",
               vault_id: google.id
             )

    conflicting =
      vault_with(user, %{"GEMINI_API_KEY" => "one", "GOOGLE_GENERATIVE_AI_API_KEY" => "two"})

    assert {:error, :inference_credential_conflict} =
             InferenceCredentials.resolve(user.id, "google/gemini-2.5-pro", "gemini",
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
             InferenceCredentials.resolve(user.id, "google/gemini-2.5-pro", "gemini",
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

  # ChatGPT subscriptions were removed on 2026-10-13. A conversation pinned
  # to one, a user's or the deployment's, is refused with
  # `:inference_source_changed` at its next turn or wake, even when the set
  # it names now holds an OpenAI key: nothing is substituted for it.
  test "a conversation pinned to a ChatGPT subscription is refused, not moved to a key", %{
    user: user,
    dek: dek
  } do
    {:ok, set} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "sk-own")
    grant_id = Ecto.UUID.generate()

    base = %{
      "set_id" => set.id,
      "runtime" => "codex",
      "model" => "openai/gpt-5",
      "environment_id" => nil,
      "vault_id" => nil
    }

    user_grant =
      Map.merge(base, %{
        "origin" => "own",
        "scope" => "grant",
        "kind" => "codex_chatgpt_access_token",
        "identity" => "chatgpt_grant:" <> grant_id,
        "revision" => Ecto.UUID.generate(),
        "grant_id" => grant_id,
        "generation" => Ecto.UUID.generate()
      })

    platform_grant =
      Map.merge(base, %{
        "origin" => "platform",
        "scope" => "platform",
        "kind" => "codex_chatgpt_access_token",
        "identity" => "platform:chatgpt:" <> grant_id,
        "revision" => Ecto.UUID.generate()
      })

    # The deployment's API key, which ADR 0075 removed.
    platform_key =
      Map.merge(base, %{
        "origin" => "platform",
        "scope" => "platform",
        "kind" => "openai_api_key",
        "identity" => "platform:environment:openai",
        "revision" => "0123abcd"
      })

    for stored <- [user_grant, platform_grant, platform_key] do
      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(user.id, Source.load(stored))

      conv =
        insert_conversation(
          user_id: user.id,
          runtime: "codex",
          inference_source: stored
        )

      assert {:error, :inference_source_changed} =
               InferenceBinding.reserve(conv, Source.load(stored))
    end
  end

  # #2602: a value rotated in place keeps the source's identity and moves
  # its revision. Every runtime runs on it, codex included (#2602).
  test "a record rotated in place serves claude and codex", %{user: user, dek: dek} do
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "first")
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "first-openai")

    {:ok, claude, _} =
      InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "claude")

    {:ok, codex, _} = InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex")

    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "second")

    {:ok, restored} =
      InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "first")

    refute restored.revision == claude.revision

    assert :ok = InferenceCredentials.validate_source(user.id, claude)

    assert {:ok, fresh, %{anthropic_api_key: "first"}} =
             InferenceCredentials.resolve(user.id, claude.model, claude.runtime,
               expected_source: Source.dump(claude)
             )

    assert fresh.identity == claude.identity
    assert fresh.revision == restored.revision

    # The record's revision covers all four of its keys, so the anthropic
    # write moved the codex binding's revision too: a rotation, which serves,
    # and the value it serves is the one codex already had.
    assert :ok = InferenceCredentials.validate_source(user.id, codex)

    assert {:ok, _, %{openai_api_key: "first-openai"}} =
             InferenceCredentials.resolve(user.id, codex.model, codex.runtime,
               expected_source: Source.dump(codex)
             )
  end

  test "a rotation is recorded by the next reservation, and identity still refuses", %{
    user: user,
    dek: dek
  } do
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "first")

    {:ok, source, _} =
      InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "claude")

    conv =
      insert_conversation(
        user_id: user.id,
        runtime: "claude",
        inference_source: Source.dump(source)
      )

    {:ok, rotated} =
      InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "second")

    {:ok, fresh, _} =
      InferenceCredentials.resolve(user.id, source.model, source.runtime,
        expected_source: Source.dump(source)
      )

    assert :ok = InferenceBinding.reserve(conv, fresh)
    assert Repo.reload!(conv).inference_source["revision"] == rotated.revision

    # Not this source's rotation: another kind.
    other = %{
      fresh
      | kind: :claude_code_oauth_token,
        identity: "credential:#{rotated.id}:claude_code_oauth_token"
    }

    assert {:error, :inference_source_changed} = InferenceBinding.reserve(conv, other)
  end

  test "saving the value the record already holds keeps its binding", %{user: user, dek: dek} do
    {:ok, set} =
      InferenceCredentials.put_credential(user.id, dek, :claude_code_oauth_token, "token")

    {:ok, source, _} =
      InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "claude")

    {:ok, again} =
      InferenceCredentials.put_credential(user.id, dek, :claude_code_oauth_token, "token")

    assert again.revision == source.revision
    assert again.claude_code_oauth_token_ciphertext == set.claude_code_oauth_token_ciphertext
    assert :ok = InferenceCredentials.validate_source(user.id, source)

    {:ok, _} =
      InferenceCredentials.put_credential(user.id, dek, :claude_code_oauth_token, "token")

    assert :ok = InferenceCredentials.validate_source(user.id, source)

    {:ok, replaced} =
      InferenceCredentials.put_credential(user.id, dek, :claude_code_oauth_token, "other")

    refute replaced.revision == source.revision
  end

  test "a record deleted and written again is a different source, never a fallback", %{
    user: user,
    dek: dek
  } do
    {:ok, first} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "first")

    {:ok, source, _} =
      InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "claude")

    Repo.delete!(first)
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "first")

    assert {:error, :inference_source_changed} =
             InferenceCredentials.validate_source(user.id, source)

    assert {:error, :inference_credential_not_found} =
             InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "claude",
               expected_source: Source.dump(source)
             )
  end

  # #2602: each plain variable has a revision of its own, so an edit to
  # another variable in the same map is no credential change, for any
  # runtime. A change to the credential's own value is a rotation, which
  # every runtime runs on.
  test "plain variables carry per-key revisions", %{user: user} do
    vars = fn openai, gemini, unrelated ->
      %{"OPENAI_API_KEY" => openai, "GEMINI_API_KEY" => gemini, "UNRELATED" => unrelated}
    end

    env = insert_env(user_id: user.id, env_vars: vars.("first", "gemini-first", "a"))

    {:ok, codex, _} =
      InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex", environment_id: env.id)

    {:ok, gemini, _} =
      InferenceCredentials.resolve(user.id, "google/gemini-2.5-pro", "gemini",
        environment_id: env.id
      )

    assert codex.identity == "environment:#{env.id}:OPENAI_API_KEY"
    refute codex.revision == env.inference_revision
    refute codex.revision == gemini.revision
    refute inspect(Source.dump(codex)) =~ "first"

    {:ok, env} =
      Environments.update_environment(env, %{"env_vars" => vars.("first", "gemini-first", "b")})

    assert {:ok, ^codex, _} =
             InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex",
               environment_id: env.id,
               expected_source: Source.dump(codex)
             )

    assert :ok = InferenceCredentials.validate_source(user.id, codex)
    assert :ok = InferenceCredentials.validate_source(user.id, gemini)

    {:ok, _} =
      Environments.update_environment(env, %{"env_vars" => vars.("second", "gemini-second", "b")})

    assert :ok = InferenceCredentials.validate_source(user.id, codex)

    assert {:ok, rotated, %{openai_api_key: "second"}} =
             InferenceCredentials.resolve(user.id, codex.model, codex.runtime,
               environment_id: env.id,
               expected_source: Source.dump(codex)
             )

    assert rotated.identity == codex.identity
    refute rotated.revision == codex.revision

    assert :ok = InferenceCredentials.validate_source(user.id, gemini)

    assert {:ok, _, %{gemini_api_key: "gemini-second"}} =
             InferenceCredentials.resolve(user.id, gemini.model, gemini.runtime,
               environment_id: env.id,
               expected_source: Source.dump(gemini)
             )
  end

  # Bound before per-key revisions, a plain variable's source carries the
  # map's `inference_revision`. A fresh source differs from it only in the
  # revision, which is a rotation in place, so the change of scheme refuses
  # nothing, before an edit to the map or after.
  test "a binding with the map's revision still serves", %{user: user} do
    env =
      insert_env(user_id: user.id, env_vars: %{"OPENAI_API_KEY" => "first", "UNRELATED" => "a"})

    {:ok, source, _} =
      InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex", environment_id: env.id)

    legacy = %{source | revision: env.inference_revision}
    assert :ok = InferenceCredentials.validate_source(user.id, legacy)

    {:ok, _} =
      Environments.update_environment(env, %{
        "env_vars" => %{"OPENAI_API_KEY" => "first", "UNRELATED" => "b"}
      })

    assert :ok = InferenceCredentials.validate_source(user.id, legacy)
  end

  test "a changed identity refuses every runtime", %{user: user, dek: dek} do
    for {model, runtime, key} <- [
          {"anthropic/claude-sonnet-5", "claude", "ANTHROPIC_API_KEY"},
          {"google/gemini-2.5-pro", "gemini", "GEMINI_API_KEY"},
          {"openai/gpt-5", "codex", "OPENAI_API_KEY"}
        ] do
      vault = insert_vault(user_id: user.id)
      {:ok, secret} = Vaults.upsert_secret(vault, %{"key" => key, "value" => "first"}, dek)

      {:ok, source, _} =
        InferenceCredentials.resolve(user.id, model, runtime, vault_id: vault.id)

      # Another vault holding the same value is another source.
      other = insert_vault(user_id: user.id)
      {:ok, _} = Vaults.upsert_secret(other, %{"key" => key, "value" => "first"}, dek)

      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(user.id, %{source | vault_id: other.id})

      # Deleted and written again is a new row, not a rotation.
      {:ok, _} = Vaults.delete_secret(vault, secret)
      {:ok, _} = Vaults.upsert_secret(vault, %{"key" => key, "value" => "first"}, dek)

      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(user.id, source)
    end
  end

  test "encrypted environment and vault rotation serves codex and claude", %{
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

      assert :ok = InferenceCredentials.validate_source(user.id, source)

      {:ok, _} =
        context.upsert_secret(parent, %{"key" => "ANTHROPIC_API_KEY", "value" => "first"}, dek)

      {:ok, claude, _} =
        InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "claude", opts)

      {:ok, _} =
        context.upsert_secret(parent, %{"key" => "ANTHROPIC_API_KEY", "value" => "second"}, dek)

      assert :ok = InferenceCredentials.validate_source(user.id, claude)

      assert {:ok, %{identity: identity}, %{anthropic_api_key: "second"}} =
               InferenceCredentials.resolve(
                 user.id,
                 claude.model,
                 claude.runtime,
                 opts ++ [expected_source: Source.dump(claude)]
               )

      assert identity == claude.identity
    end
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
