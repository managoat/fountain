defmodule Fountain.VaultsTest do
  use Fountain.DataCase, async: true

  alias Fountain.Vaults

  describe "create_vault/1" do
    test "creates a vault with valid attrs" do
      user = insert_verified_user()
      attrs = vault_attrs(user_id: user.id)

      assert {:ok, vault} = Vaults.create_vault(attrs)
      assert vault.user_id == user.id
      assert vault.name == attrs["name"]
    end

    test "returns error changeset with missing required fields" do
      assert {:error, changeset} = Vaults.create_vault(%{})
      assert changeset.errors != []
    end
  end

  describe "copy_vault/4" do
    import ExUnit.CaptureLog

    alias Fountain.Conversations.SpriteEnv

    defp copyable_source(user) do
      vault =
        insert_vault(
          user_id: user.id,
          description: "project secrets",
          metadata: %{"project" => "p1"}
        )

      expires_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
      insert_vault_secret(vault, key: "API_TOKEN", value: "copy-me-token-value")

      insert_vault_secret(vault,
        key: "DATABASE_URL",
        value: "postgres://copy-me-db-value",
        expires_at: expires_at
      )

      {vault, expires_at}
    end

    test "creates a new vault with the same keys, re-encrypted, readable at spawn" do
      user = insert_verified_user()
      {source, expires_at} = copyable_source(user)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert {:ok, copy} = Vaults.copy_vault(source, %{"name" => "track-1"}, dek)

      assert copy.id != source.id
      assert copy.user_id == user.id
      assert copy.name == "track-1"
      assert copy.description == "project secrets"
      assert copy.metadata == %{"project" => "p1"}

      # The read path a sandbox spawn takes, not the API.
      assert SpriteEnv.merge_secrets(nil, copy, dek) == %{
               "API_TOKEN" => "copy-me-token-value",
               "DATABASE_URL" => "postgres://copy-me-db-value"
             }

      copied = Map.new(Vaults._unsafe_list_secrets(copy), &{&1.key, &1})
      originals = Map.new(Vaults._unsafe_list_secrets(source), &{&1.key, &1})
      assert Map.keys(copied) == Map.keys(originals)
      assert copied["DATABASE_URL"].expires_at == expires_at
      assert copied["API_TOKEN"].expires_at == nil

      for {key, secret} <- copied do
        # Written as a new row, encrypted afresh, not a shared ciphertext.
        assert secret.id != originals[key].id
        assert secret.value_ciphertext != originals[key].value_ciphertext
      end
    end

    test "name, description and metadata may be overridden" do
      user = insert_verified_user()
      {source, _} = copyable_source(user)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert {:ok, copy} =
               Vaults.copy_vault(
                 source,
                 %{"name" => "track-2", "description" => "", "metadata" => %{"track" => "t2"}},
                 dek
               )

      assert copy.description == ""
      assert copy.metadata == %{"track" => "t2"}
    end

    test "the copy is independent of later writes to the source" do
      user = insert_verified_user()
      {source, _} = copyable_source(user)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, copy} = Vaults.copy_vault(source, %{"name" => "track-3"}, dek)
      {:ok, _} = Vaults.upsert_secret(source, %{"key" => "API_TOKEN", "value" => "rotated"}, dek)

      {:ok, _} =
        Vaults.upsert_secret(copy, %{"key" => "CLONE_TOKEN", "value" => "track-only"}, dek)

      assert Vaults.decrypted_env(copy, dek)["API_TOKEN"] == "copy-me-token-value"
      refute Map.has_key?(Vaults.decrypted_env(source, dek), "CLONE_TOKEN")
    end

    test "an empty source vault copies to an empty vault" do
      user = insert_verified_user()
      source = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert {:ok, copy} = Vaults.copy_vault(source, %{"name" => "empty-copy"}, dek)
      assert Vaults._unsafe_list_secrets(copy) == []
    end

    test "audits the vault and each key, never a value" do
      user = insert_verified_user()
      {source, _} = copyable_source(user)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, copy} = Vaults.copy_vault(source, %{"name" => "track-4"}, dek, actor: "api")

      events =
        Repo.all(
          from a in Fountain.Audit.Event,
            where: a.user_id == ^user.id and a.resource_id == ^copy.id
        )

      created = Enum.find(events, &(&1.action == "vault.created"))
      assert created.actor == "api"
      assert created.metadata["copied_from"] == source.id
      assert created.metadata["secret_count"] == 2

      writes = Enum.filter(events, &(&1.action == "vault.secret.write"))

      assert writes |> Enum.map(& &1.metadata["key"]) |> Enum.sort() == [
               "API_TOKEN",
               "DATABASE_URL"
             ]

      assert Enum.all?(writes, &(&1.metadata["copied_from"] == source.id))

      trail = inspect(events)
      refute trail =~ "copy-me-token-value"
      refute trail =~ "copy-me-db-value"
    end

    test "logs no secret value, even at debug level" do
      user = insert_verified_user()
      {source, _} = copyable_source(user)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      log =
        capture_log([level: :debug], fn ->
          Logger.put_process_level(self(), :debug)
          assert {:ok, _} = Vaults.copy_vault(source, %{"name" => "track-5"}, dek)
          Logger.delete_process_level(self())
        end)

      refute log =~ "copy-me-token-value"
      refute log =~ "copy-me-db-value"
    end

    test "a name already taken is refused and nothing is written" do
      user = insert_verified_user()
      {source, _} = copyable_source(user)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      before = Repo.aggregate(Fountain.Vaults.VaultSecret, :count)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Vaults.copy_vault(source, %{"name" => source.name}, dek)

      assert errors_on(changeset).name != []
      assert length(Vaults.list_vaults(user.id)) == 1
      assert Repo.aggregate(Fountain.Vaults.VaultSecret, :count) == before
    end

    test "a missing name is refused" do
      user = insert_verified_user()
      {source, _} = copyable_source(user)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert {:error, %Ecto.Changeset{}} = Vaults.copy_vault(source, %{}, dek)
      assert length(Vaults.list_vaults(user.id)) == 1
    end

    test "a secret that cannot be copied rolls the whole copy back" do
      user = insert_verified_user()
      {source, _} = copyable_source(user)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      # DATABASE_URL sorts after API_TOKEN, so API_TOKEN has already been
      # written into the new vault by the time the copy reaches this row.
      {1, _} =
        Repo.update_all(
          from(s in Fountain.Vaults.VaultSecret,
            where: s.vault_id == ^source.id and s.key == "DATABASE_URL"
          ),
          set: [value_ciphertext: :crypto.strong_rand_bytes(48)]
        )

      before = Repo.aggregate(Fountain.Vaults.VaultSecret, :count)

      assert {:error, {:secret_not_copyable, "DATABASE_URL"}} =
               Vaults.copy_vault(source, %{"name" => "track-6"}, dek)

      assert Vaults.get_vault_by_name("track-6", user.id) == nil
      assert Repo.aggregate(Fountain.Vaults.VaultSecret, :count) == before

      refute Repo.exists?(
               from a in Fountain.Audit.Event,
                 where: a.user_id == ^user.id and a.action == "vault.created",
                 where: fragment("?->>'copied_from' = ?", a.metadata, ^source.id)
             )
    end

    test "a secret failing today's write checks rolls the whole copy back" do
      user = insert_verified_user()
      source = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      # A row written before the reserved-key check existed.
      Repo.insert!(%Fountain.Vaults.VaultSecret{
        vault_id: source.id,
        key: Fountain.ChatGPTAccounts.Reserved.key(),
        value_ciphertext: Fountain.Crypto.encrypt("legacy", dek)
      })

      assert {:error, {:secret_not_copyable, key}} =
               Vaults.copy_vault(source, %{"name" => "track-7"}, dek)

      assert key == Fountain.ChatGPTAccounts.Reserved.key()
      assert Vaults.get_vault_by_name("track-7", user.id) == nil
    end
  end

  describe "update_secret_metadata/4" do
    test "invalid metadata leaves the secret and audit trail unchanged" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      secret = insert_vault_secret(vault, key: "TOKEN", expires_at: "2027-01-15T00:00:00Z")

      assert {:error, changeset} =
               Vaults.update_secret_metadata(vault, secret.key, %{"expires_at" => "invalid"})

      assert errors_on(changeset).expires_at != []
      stored = Repo.reload!(secret)
      assert stored.expires_at == secret.expires_at
      assert stored.value_ciphertext == secret.value_ciphertext

      refute Repo.exists?(
               from a in Fountain.Audit.Event,
                 where: a.user_id == ^user.id and a.action == "vault.secret.update"
             )
    end
  end

  describe "get_vault/2" do
    test "a malformed id reads as nil rather than raising (#1679)" do
      user = insert_verified_user()

      assert Vaults.get_vault("prod-creds", user.id) == nil
      # Sixteen characters is what a cast-based guard would have let through.
      assert Vaults.get_vault("prod-credentials", user.id) == nil
    end

    test "returns vault scoped to user" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      assert fetched = Vaults.get_vault(vault.id, user.id)
      assert fetched.id == vault.id
    end

    test "returns nil for vault belonging to another user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      vault = insert_vault(user_id: user_a.id)

      assert Vaults.get_vault(vault.id, user_b.id) == nil
    end

    test "returns nil for non-existent id" do
      user = insert_verified_user()
      assert Vaults.get_vault(Ecto.UUID.generate(), user.id) == nil
    end
  end

  describe "list_vaults/1" do
    test "returns only vaults for the given user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      vault_a = insert_vault(user_id: user_a.id)
      _vault_b = insert_vault(user_id: user_b.id)

      results = Vaults.list_vaults(user_a.id)
      assert length(results) == 1
      assert hd(results).id == vault_a.id
    end

    test "returns empty list when user has no vaults" do
      user = insert_verified_user()
      assert Vaults.list_vaults(user.id) == []
    end
  end

  describe "update_vault/2" do
    test "updates vault name" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      assert {:ok, updated} = Vaults.update_vault(vault, %{"name" => "renamed"})
      assert updated.name == "renamed"
    end
  end

  describe "delete_vault/1" do
    test "deletes the vault" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      assert {:ok, _} = Vaults.delete_vault(vault)
      assert Vaults.get_vault(vault.id, user.id) == nil
    end
  end

  describe "upsert_secret/3" do
    test "inserts a new secret" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert {:ok, secret} =
               Vaults.upsert_secret(vault, %{"key" => "TOKEN", "value" => "xyz"}, dek)

      assert secret.key == "TOKEN"
    end

    test "updates an existing secret with the same key" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "TOKEN", "value" => "first"}, dek)
      {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "TOKEN", "value" => "second"}, dek)

      secrets = Vaults._unsafe_list_secrets(vault)
      assert length(secrets) == 1
    end

    test "records an optional expiry" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      expires_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

      assert {:ok, secret} =
               Vaults.upsert_secret(
                 vault,
                 %{"key" => "TOKEN", "value" => "xyz", "expires_at" => expires_at},
                 dek
               )

      assert secret.expires_at == expires_at

      assert {:ok, no_expiry} =
               Vaults.upsert_secret(vault, %{"key" => "OTHER", "value" => "abc"}, dek)

      assert no_expiry.expires_at == nil
    end

    test "moving the expiry re-arms the notice" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      expires_at = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

      {:ok, secret} =
        Vaults.upsert_secret(
          vault,
          %{"key" => "TOKEN", "value" => "v1", "expires_at" => expires_at},
          dek
        )

      # Simulate the sweeper having sent the notice.
      {:ok, _} =
        secret
        |> Ecto.Changeset.change(
          expiry_notified_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )
        |> Repo.update()

      later = DateTime.add(expires_at, 30, :day)

      {:ok, rotated} =
        Vaults.upsert_secret(
          vault,
          %{"key" => "TOKEN", "value" => "v2", "expires_at" => later},
          dek
        )

      assert rotated.expiry_notified_at == nil

      # A write that leaves the expiry alone keeps the stamp.
      {:ok, _} =
        rotated
        |> Ecto.Changeset.change(
          expiry_notified_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )
        |> Repo.update()

      {:ok, untouched} = Vaults.upsert_secret(vault, %{"key" => "TOKEN", "value" => "v3"}, dek)
      assert untouched.expiry_notified_at
    end
  end

  describe "_unsafe_list_secrets/1" do
    test "returns all secrets for a vault" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      insert_vault_secret(vault, key: "FOO")
      insert_vault_secret(vault, key: "BAR")

      secrets = Vaults._unsafe_list_secrets(vault)
      assert length(secrets) == 2
    end

    test "returns empty list when vault has no secrets" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      assert Vaults._unsafe_list_secrets(vault) == []
    end
  end

  describe "delete_secret/3" do
    test "deletes the secret" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      secret = insert_vault_secret(vault, key: "TO_DELETE")

      assert {:ok, _} = Vaults.delete_secret(vault, secret)
      assert Vaults._unsafe_list_secrets(vault) == []
    end
  end

  describe "_unsafe_get_secret/2" do
    test "returns the secret for the given vault_id and key" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      insert_vault_secret(vault, key: "MY_SECRET")

      result = Vaults._unsafe_get_secret(vault.id, "MY_SECRET")
      assert result != nil
      assert result.key == "MY_SECRET"
      assert result.vault_id == vault.id
    end

    test "returns nil when the key does not exist in the vault" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      assert Vaults._unsafe_get_secret(vault.id, "NONEXISTENT") == nil
    end

    test "returns nil when the vault_id does not match" do
      user = insert_verified_user()
      vault_a = insert_vault(user_id: user.id)
      vault_b = insert_vault(user_id: user.id)
      insert_vault_secret(vault_a, key: "ONLY_IN_A")

      assert Vaults._unsafe_get_secret(vault_b.id, "ONLY_IN_A") == nil
    end
  end

  describe "get_vault!/2" do
    test "returns vault when id and user_id match" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      result = Vaults.get_vault!(vault.id, user.id)
      assert result.id == vault.id
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      user = insert_verified_user()

      assert_raise Ecto.NoResultsError, fn ->
        Vaults.get_vault!(Ecto.UUID.generate(), user.id)
      end
    end

    test "raises Ecto.NoResultsError when vault belongs to a different user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      vault = insert_vault(user_id: user_a.id)

      assert_raise Ecto.NoResultsError, fn ->
        Vaults.get_vault!(vault.id, user_b.id)
      end
    end
  end

  describe "_unsafe_get_vault/1" do
    test "returns the vault when it exists" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      result = Vaults._unsafe_get_vault(vault.id)
      assert result.id == vault.id
    end

    test "returns nil for a non-existent id" do
      assert Vaults._unsafe_get_vault(Ecto.UUID.generate()) == nil
    end

    test "returns vault regardless of owner" do
      user_a = insert_verified_user()
      vault = insert_vault(user_id: user_a.id)

      result = Vaults._unsafe_get_vault(vault.id)
      assert result.id == vault.id
      assert result.user_id == user_a.id
    end
  end

  describe "VaultSecret.changeset/3 — put_ciphertext nil branch" do
    test "does not update value_ciphertext when value is not in attrs" do
      existing_ciphertext = <<1, 2, 3>>
      dek = :crypto.strong_rand_bytes(32)
      vault_id = Ecto.UUID.generate()

      secret = %Fountain.Vaults.VaultSecret{value_ciphertext: existing_ciphertext}

      changeset =
        Fountain.Vaults.VaultSecret.changeset(
          secret,
          %{"key" => "NEW_KEY", "vault_id" => vault_id},
          dek
        )

      # value not in attrs → get_change(:value) is nil → nil branch is hit
      # ciphertext field is not changed
      refute Ecto.Changeset.get_change(changeset, :value_ciphertext)
      # changeset is invalid because value is required
      refute changeset.valid?
    end
  end

  describe "VaultSecret.decrypt/2" do
    test "decrypts a vault secret that was encrypted with the tenant key" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, _secret} =
        Vaults.upsert_secret(vault, %{"key" => "DECRYPT_ME", "value" => "plaintext_value"}, dek)

      # Load the raw secret (with ciphertext) to test decrypt directly
      [raw_secret] = Vaults._unsafe_list_secrets(vault)
      assert {:ok, "plaintext_value"} = Fountain.Vaults.VaultSecret.decrypt(raw_secret, dek)
    end

    test "returns :error for a non-VaultSecret argument" do
      dek = :crypto.strong_rand_bytes(32)
      assert :error = Fountain.Vaults.VaultSecret.decrypt(%{}, dek)
    end
  end

  describe "decrypted_env/2" do
    test "returns a map of key => plaintext value" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      Vaults.upsert_secret(vault, %{"key" => "SECRET_A", "value" => "val_a"}, dek)
      Vaults.upsert_secret(vault, %{"key" => "SECRET_B", "value" => "val_b"}, dek)

      decrypted = Vaults.decrypted_env(vault, dek)
      assert decrypted["SECRET_A"] == "val_a"
      assert decrypted["SECRET_B"] == "val_b"
    end

    test "returns empty map when vault has no secrets" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert Vaults.decrypted_env(vault, dek) == %{}
    end

    test "silently skips secrets that fail to decrypt with wrong DEK" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      Vaults.upsert_secret(vault, %{"key" => "MY_KEY", "value" => "secret"}, dek)

      wrong_dek = :crypto.strong_rand_bytes(32)
      result = Vaults.decrypted_env(vault, wrong_dek)
      assert result == %{}
    end

    test "vault secrets override environment secrets on key collision" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      Fountain.Environments.upsert_secret(
        env,
        %{"key" => "DB_URL", "value" => "env_value"},
        dek
      )

      Vaults.upsert_secret(vault, %{"key" => "DB_URL", "value" => "vault_value"}, dek)

      env_map = Fountain.Environments.decrypted_env(env, dek)
      vault_map = Vaults.decrypted_env(vault, dek)

      merged = Map.merge(env_map, vault_map)
      assert merged["DB_URL"] == "vault_value"
    end
  end
end
