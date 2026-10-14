defmodule Fountain.InferenceCredentialsTest do
  use Fountain.DataCase, async: true

  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Credential

  import Fountain.Factory

  setup do
    user = insert_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    %{user: user, dek: dek}
  end

  describe "providers/0" do
    test "lists the four supported providers" do
      assert Credential.providers() == [
               :anthropic_api_key,
               :claude_code_oauth_token,
               :openai_api_key,
               :gemini_api_key
             ]
    end
  end

  describe "credentials_for_provider/1 and missing_for_model/2" do
    test "names the credentials a model's provider accepts" do
      assert InferenceCredentials.credentials_for_provider("anthropic") ==
               [:anthropic_api_key, :claude_code_oauth_token]

      assert InferenceCredentials.credentials_for_provider("openai") == [:openai_api_key]
      assert InferenceCredentials.credentials_for_provider("google") == [:gemini_api_key]
      assert InferenceCredentials.credentials_for_provider("ollama") == []
      assert InferenceCredentials.credentials_for_provider(nil) == []
    end

    test "missing until any accepted credential is set; unknown providers need none", %{
      user: user,
      dek: dek
    } do
      assert InferenceCredentials.missing_for_model(user.id, "anthropic/claude-sonnet-5") ==
               {"anthropic", [:anthropic_api_key, :claude_code_oauth_token]}

      assert InferenceCredentials.missing_for_model(user.id, "openai/gpt-5") ==
               {"openai", [:openai_api_key]}

      assert InferenceCredentials.missing_for_model(user.id, "ollama/llama3") == nil
      assert InferenceCredentials.missing_for_model(user.id, nil) == nil

      # the OAuth token counts for Anthropic models too
      {:ok, _} =
        InferenceCredentials.put_credential(user.id, dek, :claude_code_oauth_token, "sk-ant-oat")

      assert InferenceCredentials.missing_for_model(user.id, "anthropic/claude-sonnet-5") == nil
      assert InferenceCredentials.missing_for_model(user.id, "openai/gpt-5") != nil
    end
  end

  describe "get_for_user/1" do
    test "returns nil for a user with no credentials", %{user: user} do
      assert nil == InferenceCredentials.get_for_user(user.id)
    end

    test "returns the row after a put", %{user: user, dek: dek} do
      {:ok, _} =
        InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant-test")

      assert %Credential{} = InferenceCredentials.get_for_user(user.id)
    end
  end

  describe "put_credential/4" do
    test "creates a row on first put and stores ciphertext (not plaintext)", %{
      user: user,
      dek: dek
    } do
      plaintext = "sk-ant-very-secret"

      {:ok, cred} =
        InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, plaintext)

      assert is_binary(cred.anthropic_api_key_ciphertext)
      refute cred.anthropic_api_key_ciphertext == plaintext
      refute String.contains?(cred.anthropic_api_key_ciphertext, plaintext)
    end

    test "updates an existing row on second put for a different provider", %{user: user, dek: dek} do
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant-1")
      {:ok, cred} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "sk-oai-1")

      assert is_binary(cred.anthropic_api_key_ciphertext)
      assert is_binary(cred.openai_api_key_ciphertext)
    end

    test "treats nil as clear", %{user: user, dek: dek} do
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant-1")
      {:ok, cred} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, nil)

      assert is_nil(cred.anthropic_api_key_ciphertext)
    end

    test "treats empty string as clear", %{user: user, dek: dek} do
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant-1")
      {:ok, cred} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "")

      assert is_nil(cred.anthropic_api_key_ciphertext)
    end

    test "raises on an unknown provider", %{user: user, dek: dek} do
      assert_raise FunctionClauseError, fn ->
        InferenceCredentials.put_credential(user.id, dek, :unknown_provider, "x")
      end
    end
  end

  describe "decrypted_for_user/2" do
    test "returns an empty map for a user with no credentials", %{user: user, dek: dek} do
      assert {:ok, %{}} = InferenceCredentials.decrypted_for_user(user.id, dek)
    end

    test "returns only providers the user has set", %{user: user, dek: dek} do
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant-1")
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "sk-oai-1")

      {:ok, map} = InferenceCredentials.decrypted_for_user(user.id, dek)

      assert map == %{
               anthropic_api_key: "sk-ant-1",
               openai_api_key: "sk-oai-1"
             }

      refute Map.has_key?(map, :gemini_api_key)
      refute Map.has_key?(map, :claude_code_oauth_token)
    end

    test "round-trips plaintext through encryption", %{user: user, dek: dek} do
      plaintexts = %{
        anthropic_api_key: "sk-ant-" <> String.duplicate("a", 80),
        claude_code_oauth_token: "ccode_oauth_" <> String.duplicate("b", 60),
        openai_api_key: "sk-proj-" <> String.duplicate("c", 100),
        gemini_api_key: "AIza" <> String.duplicate("d", 35)
      }

      for {provider, value} <- plaintexts do
        {:ok, _} = InferenceCredentials.put_credential(user.id, dek, provider, value)
      end

      {:ok, decrypted} = InferenceCredentials.decrypted_for_user(user.id, dek)
      assert decrypted == plaintexts
    end

    test "returns :decrypt_failed with the wrong DEK", %{user: user, dek: dek} do
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant-1")
      wrong_dek = :crypto.strong_rand_bytes(32)

      assert {:error, :decrypt_failed} =
               InferenceCredentials.decrypted_for_user(user.id, wrong_dek)
    end
  end

  describe "status_for_user/1" do
    test "all false for a user with no credentials", %{user: user} do
      status = InferenceCredentials.status_for_user(user.id)

      assert status == %{
               anthropic_api_key: false,
               claude_code_oauth_token: false,
               openai_api_key: false,
               gemini_api_key: false
             }
    end

    test "tracks set state per provider", %{user: user, dek: dek} do
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant-1")
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :gemini_api_key, "AIzaXYZ")

      status = InferenceCredentials.status_for_user(user.id)
      assert status[:anthropic_api_key] == true
      assert status[:gemini_api_key] == true
      assert status[:openai_api_key] == false
      assert status[:claude_code_oauth_token] == false
    end
  end

  describe "tenant scoping" do
    test "one user's credentials are not visible to another", %{user: user, dek: dek} do
      {:ok, _} =
        InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant-secret")

      other = insert_user()
      {:ok, other_dek} = Crypto.load_tenant_key(other.id)

      assert nil == InferenceCredentials.get_for_user(other.id)
      assert {:ok, %{}} = InferenceCredentials.decrypted_for_user(other.id, other_dek)
    end
  end
end
