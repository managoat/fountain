defmodule Fountain.PlatformInferenceTest do
  @moduledoc """
  The platform keys and the selection rule (#1388).

  `async: false` throughout: platform keys live in the global
  application environment, and an async module that writes it races every
  other module that reads it (#1214).
  """

  use Fountain.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Fountain.Environments
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformInference

  setup do
    original =
      for key <- [
            :platform_anthropic_api_key,
            :platform_openai_api_key,
            :platform_gemini_api_key
          ],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:fountain, key)
        {key, value} -> Application.put_env(:fountain, key, value)
      end)
    end)

    :ok
  end

  defp with_platform_key(provider \\ :platform_anthropic_api_key, key \\ "sk-platform") do
    Application.put_env(:fountain, provider, key)
  end

  describe "key_for/1 and enabled?/0" do
    test "off with nothing configured, and a blank value is still off" do
      refute PlatformInference.enabled?()
      assert PlatformInference.key_for("anthropic") == :none

      Application.put_env(:fountain, :platform_anthropic_api_key, "")
      refute PlatformInference.enabled?()
      assert PlatformInference.key_for("anthropic") == :none
    end

    test "a configured key comes back under the credential the tenant's own uses" do
      with_platform_key()

      assert PlatformInference.enabled?()
      assert PlatformInference.key_for("anthropic") == {:ok, :anthropic_api_key, "sk-platform"}
      assert PlatformInference.key_for("openai") == :none
      assert PlatformInference.configured_providers() == ["anthropic"]
    end

    test "a provider Fountain cannot export a credential for is never platform-served" do
      with_platform_key()
      assert PlatformInference.key_for("ollama") == :none
      assert PlatformInference.key_for(nil) == :none
    end
  end

  describe "keys set from the admin panel (put_key/3, clear_key/2, status/0)" do
    setup do
      %{admin: insert_verified_user()}
    end

    test "a stored key wins over the variable, and clearing it falls back", %{admin: admin} do
      with_platform_key(:platform_openai_api_key, "sk-from-env")

      assert {:ok, %PlatformInference.Key{provider: "openai"}} =
               PlatformInference.put_key("openai", "sk-from-admin", actor_user_id: admin.id)

      assert PlatformInference.key_for("openai") == {:ok, :openai_api_key, "sk-from-admin"}
      assert PlatformInference.configured_providers() == ["openai"]

      assert :ok = PlatformInference.clear_key("openai", actor_user_id: admin.id)
      assert PlatformInference.key_for("openai") == {:ok, :openai_api_key, "sk-from-env"}
    end

    test "a stored key turns a provider on with no variable at all", %{admin: admin} do
      refute PlatformInference.enabled?()

      {:ok, _} = PlatformInference.put_key("google", "AIza-stored", actor_user_id: admin.id)

      assert PlatformInference.enabled?()
      assert PlatformInference.key_for("google") == {:ok, :gemini_api_key, "AIza-stored"}

      assert {:ok, %Source{scope: :platform, kind: :gemini_api_key},
              %{gemini_api_key: "AIza-stored"}} =
               InferenceCredentials.resolve(admin.id, "google/gemini-3.1-pro-preview", nil, [])

      :ok = PlatformInference.clear_key("google")
      refute PlatformInference.enabled?()
    end

    test "the value is trimmed, and a value that is not one key is refused", %{admin: admin} do
      {:ok, _} = PlatformInference.put_key("anthropic", "  sk-trimmed\n", actor_user_id: admin.id)
      assert PlatformInference.key_for("anthropic") == {:ok, :anthropic_api_key, "sk-trimmed"}

      assert PlatformInference.put_key("anthropic", "") == {:error, :invalid_key}
      assert PlatformInference.put_key("anthropic", "   ") == {:error, :invalid_key}
      assert PlatformInference.put_key("anthropic", "sk-two words") == {:error, :invalid_key}
      assert PlatformInference.put_key("anthropic", "sk-a\tb") == {:error, :invalid_key}

      assert PlatformInference.put_key("anthropic", String.duplicate("k", 1_025)) ==
               {:error, :invalid_key}

      assert PlatformInference.put_key("ollama", "anything") == {:error, :invalid_key}
      # None of the refusals touched the stored key.
      assert PlatformInference.key_for("anthropic") == {:ok, :anthropic_api_key, "sk-trimmed"}
    end

    test "the value is encrypted at rest and never in the trail", %{admin: admin} do
      {:ok, row} = PlatformInference.put_key("openai", "sk-secret-value", actor_user_id: admin.id)

      refute row.ciphertext =~ "sk-secret-value"
      assert {:ok, "sk-secret-value"} = Fountain.Crypto.decrypt_platform(row.ciphertext)

      [event] = admin_events("admin.platform_inference_key.set")
      assert event.actor_user_id == admin.id
      assert event.metadata == %{"provider" => "openai", "replaced" => "none"}
      refute inspect(event) =~ "sk-secret"
    end

    test "the trail says what a key replaced, and a clear with nothing stored records nothing",
         %{admin: admin} do
      with_platform_key(:platform_anthropic_api_key, "sk-env")
      {:ok, _} = PlatformInference.put_key("anthropic", "sk-one", actor_user_id: admin.id)
      {:ok, _} = PlatformInference.put_key("anthropic", "sk-two", actor_user_id: admin.id)

      assert ["environment", "stored"] =
               "admin.platform_inference_key.set"
               |> admin_events()
               |> Enum.map(& &1.metadata["replaced"])
               |> Enum.sort()

      :ok = PlatformInference.clear_key("anthropic", actor_user_id: admin.id)
      :ok = PlatformInference.clear_key("anthropic", actor_user_id: admin.id)
      :ok = PlatformInference.clear_key("openai", actor_user_id: admin.id)

      assert [%{metadata: %{"provider" => "anthropic"}}] =
               admin_events("admin.platform_inference_key.cleared")
    end

    test "status/0 names the source, the operator and the key's tail", %{admin: admin} do
      with_platform_key(:platform_anthropic_api_key, "env-1234")

      {:ok, _} =
        PlatformInference.put_key("openai", "admin-5678", actor_user_id: admin.id)

      assert [anthropic, openai, google] = PlatformInference.status()

      assert %{provider: "anthropic", source: :environment, hint: "1234", updated_by: nil} =
               anthropic

      assert anthropic.env_var == "PLATFORM_ANTHROPIC_API_KEY"

      assert %{provider: "openai", source: :stored, hint: "5678"} = openai
      assert openai.updated_by == admin.email
      assert %DateTime{} = openai.updated_at

      assert %{provider: "google", source: :none, hint: nil, updated_at: nil} = google
    end

    test "a stored key the master key no longer decrypts falls back to the variable",
         %{admin: admin} do
      with_platform_key(:platform_openai_api_key, "sk-env")
      {:ok, row} = PlatformInference.put_key("openai", "sk-stored", actor_user_id: admin.id)

      # Corrupt the blob the way a rotated MASTER_SECRETS_KEY would: the row
      # is there, the bytes no longer authenticate.
      row
      |> Ecto.Changeset.change(ciphertext: :crypto.strong_rand_bytes(byte_size(row.ciphertext)))
      |> Repo.update!()

      assert PlatformInference.key_for("openai") == {:ok, :openai_api_key, "sk-env"}

      assert [%{provider: "openai", source: :undecryptable, hint: nil}] =
               Enum.filter(PlatformInference.status(), &(&1.provider == "openai"))

      # And with no variable either the provider is simply off, not broken.
      Application.put_env(:fountain, :platform_openai_api_key, "")
      assert PlatformInference.key_for("openai") == :none
    end
  end

  defp resolve(user, model), do: InferenceCredentials.resolve(user.id, model, nil, [])

  defp own!(user, dek, kind, value) do
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, kind, value)
    :ok
  end

  describe "InferenceCredentials.resolve/4, the selection" do
    setup do
      user = insert_verified_user()
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      %{user: user, dek: dek}
    end

    test "with no platform key an account with nothing is :missing, not a key", %{user: user} do
      assert {:ok, %Source{scope: :missing}, %{}} =
               resolve(user, "anthropic/claude-opus-5")
    end

    test "the tenant's own credential wins over a configured platform key", %{
      user: user,
      dek: dek
    } do
      with_platform_key()
      own!(user, dek, :anthropic_api_key, "sk-tenant")

      assert {:ok, %Source{scope: :credential}, %{anthropic_api_key: "sk-tenant"}} =
               resolve(user, "anthropic/claude-opus-5")
    end

    test "an OAuth token is a credential for anthropic and wins too", %{user: user, dek: dek} do
      with_platform_key()
      own!(user, dek, :claude_code_oauth_token, "oauth")

      assert {:ok, %Source{scope: :credential}, %{claude_code_oauth_token: "oauth"}} =
               resolve(user, "anthropic/claude-opus-5")
    end

    test "the platform key is merged in, leaving the tenant's other credentials alone", %{
      user: user,
      dek: dek
    } do
      with_platform_key()
      own!(user, dek, :openai_api_key, "sk-tenant-openai")

      assert {:ok, %Source{scope: :platform}, creds} = resolve(user, "anthropic/claude-opus-5")

      assert creds.anthropic_api_key == "sk-platform"
      assert creds.openai_api_key == "sk-tenant-openai"
    end

    test "a provider with no platform key configured is still :missing", %{user: user} do
      with_platform_key()

      assert {:ok, %Source{scope: :missing}, %{}} = resolve(user, "openai/gpt-5.5")
    end

    test "a provider that needs no credential is :own, whatever is configured", %{user: user} do
      with_platform_key()

      assert {:ok, %Source{scope: :none}, %{}} = resolve(user, "ollama/llama3")
      assert {:ok, %Source{scope: :none}, %{}} = resolve(user, nil)
    end

    # `put_credential/5` clears on an empty value, so the row is written
    # directly: what a set holds after an import or a rollback, not a
    # `put_credential/5` a caller can reach.
    test "an empty explicit credential refuses rather than selecting the platform", %{
      user: user,
      dek: dek
    } do
      with_platform_key()
      {:ok, set} = InferenceCredentials.create_set(user.id, "Blank")

      set
      |> Ecto.Changeset.change(anthropic_api_key_ciphertext: Fountain.Crypto.encrypt("", dek))
      |> Repo.update!()

      assert {:error, :inference_credential_unusable} =
               InferenceCredentials.resolve(user.id, "anthropic/claude-opus-5", nil,
                 credential_set_id: set.id
               )
    end

    test "an option the resolver does not read raises rather than being ignored", %{user: user} do
      assert_raise ArgumentError, ~r/unknown keys \[:brokered\]/, fn ->
        InferenceCredentials.resolve(user.id, "anthropic/claude-opus-5", nil, brokered: false)
      end
    end
  end

  # What admission does (`Launch.resolve_admission_inference/6`): resolve the
  # launch's selection. Nothing bounds a platform source's spend; the question
  # left is only whose credential serves the run.
  defp platform?(user_id, model, opts \\ []) do
    {:ok, source, _credentials} = InferenceCredentials.resolve(user_id, model, nil, opts)
    Source.platform?(source)
  end

  describe "resolve/4, whose credential a launch runs on" do
    setup do
      %{user: insert_verified_user()}
    end

    test "a tenant with no credential of their own runs on the platform key", %{user: user} do
      with_platform_key()
      assert platform?(user.id, "anthropic/claude-opus-5")
    end

    test "a tenant with their own key runs on it", %{user: user} do
      with_platform_key()

      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-mine")

      refute platform?(user.id, "anthropic/claude-opus-5")
      # And the same launch for another account still lands on the platform key.
      assert platform?(insert_verified_user().id, "anthropic/claude-opus-5")
    end

    # ADR 0053 decision 5. A vault or environment secret named after a
    # credential serves the conversation instead of the platform key. The
    # launch's ids are what make the resolver ask the question the provision
    # answers.
    test "a tenant whose vault names the credential runs on it", %{user: user} do
      with_platform_key()

      vault = insert_vault(user_id: user.id)
      insert_vault_secret(vault, key: "ANTHROPIC_API_KEY", value: "sk-from-the-vault")

      refute platform?(user.id, "anthropic/claude-opus-5", vault_id: vault.id)

      # The same launch without the vault, and the same vault under another
      # tenant, both run on the platform key.
      assert platform?(user.id, "anthropic/claude-opus-5")
      assert platform?(insert_verified_user().id, "anthropic/claude-opus-5", vault_id: vault.id)
    end

    test "an environment naming the credential counts too, and an unrelated key does not",
         %{user: user} do
      with_platform_key()

      env = insert_env(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "UNRELATED", "value" => "x"}, dek)

      assert platform?(user.id, "anthropic/claude-opus-5", environment_id: env.id)

      {:ok, _} =
        Environments.upsert_secret(env, %{"key" => "ANTHROPIC_API_KEY", "value" => "sk-e"}, dek)

      refute platform?(user.id, "anthropic/claude-opus-5", environment_id: env.id)
    end

    test "a secret for another provider does not serve this one", %{user: user} do
      with_platform_key()

      vault = insert_vault(user_id: user.id)
      insert_vault_secret(vault, key: "OPENAI_API_KEY", value: "sk-openai")

      assert platform?(user.id, "anthropic/claude-opus-5", vault_id: vault.id)
    end
  end

  defp admin_events(event_type) do
    Repo.all(
      from e in Fountain.Audit.AdminEvent,
        where: e.event_type == ^event_type,
        order_by: [asc: e.id]
    )
  end
end
