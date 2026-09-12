defmodule Fountain.PlatformInferenceTest do
  @moduledoc """
  The platform keys, the selection rule and the daily ceiling (#1388).

  `async: false` throughout: platform keys and the ceiling live in the global
  application environment, and an async module that writes it races every
  other module that reads it (#1214).
  """

  use Fountain.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Fountain.Credits
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformInference

  setup do
    original =
      for key <- [
            :platform_anthropic_api_key,
            :platform_openai_api_key,
            :platform_gemini_api_key,
            :platform_inference_daily_cents
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

      assert InferenceCredentials.select("google/gemini-3.1-pro-preview", %{}) ==
               {:ok, Source.platform(), %{gemini_api_key: "AIza-stored"}}

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

  describe "InferenceCredentials.select/2" do
    test "with no platform key an account with nothing gets the refusal, not a key" do
      assert InferenceCredentials.select("anthropic/claude-opus-5", %{}) ==
               {:error, :no_credential}
    end

    test "the tenant's own credential wins over a configured platform key" do
      with_platform_key()
      own = %{anthropic_api_key: "sk-tenant"}

      assert {:ok, %Source{origin: :own, scope: :credential}, ^own} =
               InferenceCredentials.select("anthropic/claude-opus-5", own)
    end

    test "an OAuth token is a credential for anthropic and wins too" do
      with_platform_key()
      own = %{claude_code_oauth_token: "oauth"}

      assert {:ok, %Source{origin: :own, scope: :credential}, ^own} =
               InferenceCredentials.select("anthropic/claude-opus-5", own)
    end

    test "the platform key is merged in, leaving the tenant's other credentials alone" do
      with_platform_key()
      own = %{openai_api_key: "sk-tenant-openai"}

      assert {:ok, %Source{origin: :platform}, creds} =
               InferenceCredentials.select("anthropic/claude-opus-5", own)

      assert creds.anthropic_api_key == "sk-platform"
      assert creds.openai_api_key == "sk-tenant-openai"
    end

    test "a provider with no platform key configured is still refused" do
      with_platform_key()

      assert InferenceCredentials.select("openai/gpt-5.5", %{}) == {:error, :no_credential}
    end

    test "a provider that needs no credential is :own, whatever is configured" do
      with_platform_key()

      assert {:ok, %Source{origin: :own, scope: :none}, %{}} =
               InferenceCredentials.select("ollama/llama3", %{})

      assert {:ok, %Source{origin: :own, scope: :none}, %{}} =
               InferenceCredentials.select(nil, %{})
    end

    test "an empty-string credential is not a credential" do
      with_platform_key()

      assert {:ok, %Source{origin: :platform}, creds} =
               InferenceCredentials.select("anthropic/claude-opus-5", %{anthropic_api_key: ""})

      assert creds.anthropic_api_key == "sk-platform"
    end
  end

  describe "gate/2" do
    setup do
      %{user: insert_verified_user()}
    end

    test "with no platform key nothing is gated", %{user: user} do
      assert PlatformInference.gate(user.id, "anthropic/claude-opus-5") == :ok
    end

    test "under the ceiling a platform account passes", %{user: user} do
      with_platform_key()
      assert PlatformInference.gate(user.id, "anthropic/claude-opus-5") == :ok
    end

    test "over the ceiling a platform account is refused", %{user: user} do
      with_platform_key()
      Application.put_env(:fountain, :platform_inference_daily_cents, 10)
      burn_inference(user, 10)

      assert PlatformInference.gate(user.id, "anthropic/claude-opus-5") ==
               {:error, :platform_inference_unavailable}
    end

    test "a tenant with their own key is never touched by the ceiling", %{user: user} do
      with_platform_key()
      Application.put_env(:fountain, :platform_inference_daily_cents, 0)
      burn_inference(user, 500)

      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-mine")

      assert PlatformInference.gate(user.id, "anthropic/claude-opus-5") == :ok
      # And the same account without the key would have been refused.
      assert PlatformInference.gate(insert_verified_user().id, "anthropic/claude-opus-5") ==
               {:error, :platform_inference_unavailable}
    end

    test "yesterday's spend does not count against today", %{user: user} do
      with_platform_key()
      Application.put_env(:fountain, :platform_inference_daily_cents, 10)
      entry = burn_inference(user, 500)

      entry
      |> Ecto.Changeset.change(
        inserted_at: DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert PlatformInference.gate(user.id, "anthropic/claude-opus-5") == :ok
    end
  end

  describe "check_ceiling/0" do
    test "a zero ceiling refuses rather than reading as unbounded" do
      Application.put_env(:fountain, :platform_inference_daily_cents, 0)

      assert PlatformInference.check_ceiling() ==
               {:error, :platform_inference_unavailable}
    end

    test "the default ceiling is $50" do
      Application.delete_env(:fountain, :platform_inference_daily_cents)
      assert PlatformInference.daily_ceiling_cents() == 5_000
    end
  end

  defp admin_events(event_type) do
    Repo.all(
      from e in Fountain.Audit.AdminEvent,
        where: e.event_type == ^event_type,
        order_by: [asc: e.id]
    )
  end

  defp burn_inference(user, cents) do
    {:ok, entry} =
      Credits.debit(user.id, cents, "burn_inference",
        idempotency_key: "burn_inference:test:#{System.unique_integer([:positive])}",
        actor: "system:test"
      )

    entry
  end
end
