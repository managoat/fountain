defmodule Fountain.EnvironmentsTest do
  use Fountain.DataCase, async: true

  alias Fountain.Environments

  describe "create_environment/1" do
    test "creates an environment with valid attrs" do
      user = insert_verified_user()
      attrs = env_attrs(user_id: user.id)

      assert {:ok, env} = Environments.create_environment(attrs)
      assert env.user_id == user.id
      assert env.name == attrs["name"]
    end

    test "returns error changeset with missing required fields" do
      assert {:error, changeset} = Environments.create_environment(%{})
      assert changeset.errors != []
    end
  end

  describe "setup timeout" do
    test "defaults to two minutes and validates persisted bounds" do
      user = insert_verified_user()
      assert insert_env(user_id: user.id).setup_timeout_seconds == 120

      for seconds <- [1, 900] do
        env = insert_env(user_id: user.id, setup_timeout_seconds: seconds)
        assert Environments.get_environment!(env.id, user.id).setup_timeout_seconds == seconds
      end

      for invalid <- [0, 901, -1, 1.5, nil] do
        assert {:error, changeset} =
                 Environments.create_environment(
                   env_attrs(user_id: user.id, setup_timeout_seconds: invalid)
                 )

        assert Keyword.has_key?(changeset.errors, :setup_timeout_seconds)
      end
    end
  end

  describe "get_environment/2" do
    test "returns environment scoped to user" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)

      assert fetched = Environments.get_environment(env.id, user.id)
      assert fetched.id == env.id
    end

    test "returns nil for environment belonging to another user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      env = insert_env(user_id: user_a.id)

      assert Environments.get_environment(env.id, user_b.id) == nil
    end

    test "returns nil for non-existent id" do
      user = insert_verified_user()
      assert Environments.get_environment(Ecto.UUID.generate(), user.id) == nil
    end
  end

  describe "get_environment!/2" do
    test "raises for environment belonging to another user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      env = insert_env(user_id: user_a.id)

      assert_raise Ecto.NoResultsError, fn ->
        Environments.get_environment!(env.id, user_b.id)
      end
    end
  end

  describe "list_environments/1" do
    test "returns only environments for the given user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      env_a = insert_env(user_id: user_a.id)
      _env_b = insert_env(user_id: user_b.id)

      results = Environments.list_environments(user_a.id)
      assert length(results) == 1
      assert hd(results).id == env_a.id
    end

    test "returns empty list when user has no environments" do
      user = insert_verified_user()
      assert Environments.list_environments(user.id) == []
    end
  end

  describe "update_environment/2" do
    test "updates environment name" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)

      assert {:ok, updated} = Environments.update_environment(env, %{"name" => "renamed"})
      assert updated.name == "renamed"
    end
  end

  describe "delete_environment/1" do
    test "deletes the environment" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)

      assert {:ok, _} = Environments.delete_environment(env)
      assert Environments.get_environment(env.id, user.id) == nil
    end
  end

  describe "upsert_secret/3" do
    test "inserts a new secret" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert {:ok, secret} =
               Environments.upsert_secret(env, %{"key" => "API_KEY", "value" => "abc123"}, dek)

      assert secret.key == "API_KEY"
    end

    test "updates an existing secret with the same key" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, _} = Environments.upsert_secret(env, %{"key" => "API_KEY", "value" => "first"}, dek)
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "API_KEY", "value" => "second"}, dek)

      secrets = Environments._unsafe_list_secrets(env)
      assert length(secrets) == 1
    end
  end

  describe "_unsafe_list_secrets/1" do
    test "returns all secrets for an environment" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      insert_secret(env, key: "FOO")
      insert_secret(env, key: "BAR")

      secrets = Environments._unsafe_list_secrets(env)
      assert length(secrets) == 2
    end

    test "returns empty list when environment has no secrets" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)

      assert Environments._unsafe_list_secrets(env) == []
    end
  end

  describe "delete_secret/3" do
    test "deletes the secret" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      secret = insert_secret(env, key: "TO_DELETE")

      assert {:ok, _} = Environments.delete_secret(env, secret)
      assert Environments._unsafe_list_secrets(env) == []
    end
  end

  describe "decrypted_env/2" do
    test "returns a map of key => plaintext value" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      Environments.upsert_secret(env, %{"key" => "HOST", "value" => "localhost"}, dek)
      Environments.upsert_secret(env, %{"key" => "PORT", "value" => "5432"}, dek)

      decrypted = Environments.decrypted_env(env, dek)
      assert decrypted["HOST"] == "localhost"
      assert decrypted["PORT"] == "5432"
    end

    test "returns empty map when environment has no secrets" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert Environments.decrypted_env(env, dek) == %{}
    end

    test "silently skips secrets that fail to decrypt with wrong DEK" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      Environments.upsert_secret(env, %{"key" => "MY_KEY", "value" => "secret"}, dek)

      wrong_dek = :crypto.strong_rand_bytes(32)
      result = Environments.decrypted_env(env, wrong_dek)
      assert result == %{}
    end
  end

  describe "Secret.changeset/3 — put_ciphertext nil branch" do
    test "does not update value_ciphertext when value is not in attrs" do
      existing_ciphertext = <<1, 2, 3>>
      dek = :crypto.strong_rand_bytes(32)
      env_id = Ecto.UUID.generate()

      secret = %Fountain.Environments.Secret{value_ciphertext: existing_ciphertext}

      changeset =
        Fountain.Environments.Secret.changeset(
          secret,
          %{"key" => "NEW_KEY", "environment_id" => env_id},
          dek
        )

      # value not in attrs → get_change(:value) is nil → nil branch is hit
      # ciphertext field is not changed
      refute Ecto.Changeset.get_change(changeset, :value_ciphertext)
      # changeset is invalid because value is required
      refute changeset.valid?
    end
  end

  describe "Secret.decrypt/2" do
    test "decrypts a secret that was encrypted with the tenant key" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, secret} =
        Environments.upsert_secret(
          env,
          %{"key" => "DECRYPT_ME", "value" => "plaintext_value"},
          dek
        )

      reloaded = Fountain.Repo.get!(Fountain.Environments.Secret, secret.id)
      assert {:ok, "plaintext_value"} = Fountain.Environments.Secret.decrypt(reloaded, dek)
    end

    test "returns :error for a non-Secret struct argument" do
      dek = :crypto.strong_rand_bytes(32)
      assert :error = Fountain.Environments.Secret.decrypt(%{}, dek)
    end
  end

  describe "_unsafe_get_secret/2" do
    test "returns the secret when env_id and key match" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      {:ok, secret} = Environments.upsert_secret(env, %{"key" => "MY_KEY", "value" => "val"}, dek)

      result = Environments._unsafe_get_secret(env.id, "MY_KEY")
      assert result != nil
      assert result.id == secret.id
      assert result.key == "MY_KEY"
    end

    test "returns nil when key does not exist in the environment" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)

      assert Environments._unsafe_get_secret(env.id, "MISSING_KEY") == nil
    end

    test "returns nil when env_id does not exist" do
      assert Environments._unsafe_get_secret(Ecto.UUID.generate(), "ANY_KEY") == nil
    end
  end
end
