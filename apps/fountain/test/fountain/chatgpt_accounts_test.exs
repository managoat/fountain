defmodule Fountain.ChatGPTAccountsTest do
  use Fountain.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  import Fountain.ChatGPTFixtures, only: [access_token: 0, access_token: 1]

  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.{Cipher, Grant}
  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT.Account

  test "a user gets only their grant with a matching bearer and source snapshot" do
    owner = insert_verified_user()
    other = insert_verified_user()
    grant = user_grant(owner)
    other_grant = user_grant(other)

    assert {:ok, %Grant{} = credential} = read(grant, owner)
    assert credential.access_token == "user-access-token"

    assert credential.source == %{
             kind: :chatgpt,
             owner_scope: {:user, owner.id},
             grant_id: grant.id,
             generation: grant.generation,
             lock_version: grant.lock_version,
             account_id: "acct-user",
             plan_type: "pro",
             id_claims: %{"account_id" => "acct-user", "user_id" => "provider-user"}
           }

    assert {:error, :not_connected} = read(grant, other)
    assert {:error, :not_connected} = read(other_grant, owner)

    assert {:error, :stale_grant} =
             ChatGPTAccounts.credential_for_user(grant.id, owner.id, Ecto.UUID.generate())

    # The metadata read produces the pin the credential read takes, so the
    # two compose without a caller reaching for the schema.
    pin = ChatGPTAccounts.status_for_user(owner.id)

    assert {:ok, %Grant{}} =
             ChatGPTAccounts.credential_for_user(pin.grant_id, owner.id, pin.generation)
  end

  test "every terminal code OAuth names survives the reason allowlist" do
    owner = insert_verified_user()
    grant = user_grant(owner)

    for code <- Fountain.PlatformChatGPT.OAuth.terminal_codes() do
      Account
      |> Repo.get!(grant.id)
      |> change(%{status: "revoked", revoked_reason: code})
      |> Repo.update!()

      assert ChatGPTAccounts.status_for_user(owner.id).revoked_reason == code
    end
  end

  test "metadata reads neither decrypt nor refresh and sanitize an unknown failure reason" do
    owner = insert_verified_user()
    grant = user_grant(owner, %{revoked_reason: "raw-provider-secret", status: "revoked"})

    stub(Crypto, :load_tenant_key, fn _ -> flunk("status loaded a token key") end)
    stub(Crypto, :decrypt_platform, fn _ -> flunk("status decrypted a platform token") end)
    stub(Crypto, :decrypt, fn _, _, _ -> flunk("status decrypted a tenant token") end)

    status = ChatGPTAccounts.status_for_user(owner.id)
    assert status.account_id == grant.account_id
    assert status.status == "revoked"
    assert status.revoked_reason == "provider_error"
    assert status.grant_id == grant.id
    assert status.generation == grant.generation
    refute Map.has_key?(status, :access_token_ciphertext)
    refute Map.has_key?(status, :refresh_token_ciphertext)
    refute inspect(status) =~ "raw-provider-secret"
    assert ChatGPTAccounts.status_for_user(Ecto.UUID.generate()) == :not_connected
  end

  test "an absent owner never requests platform ownership" do
    assert_raise FunctionClauseError, fn -> ChatGPTAccounts.status_for_user(nil) end

    assert_raise FunctionClauseError, fn ->
      ChatGPTAccounts.credential_for_user(Ecto.UUID.generate(), nil, Ecto.UUID.generate())
    end

    assert_raise FunctionClauseError, fn ->
      Cipher.encrypt_user_tokens(nil, %{access_token: "access", refresh_token: "refresh"})
    end
  end

  test "platform rows remain inaccessible through a user credential read" do
    owner = insert_verified_user()

    platform =
      %Account{}
      |> Account.connect_changeset(%{
        kind: "chatgpt",
        access_token_ciphertext: Crypto.encrypt_platform("platform-access"),
        last_refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    assert {:error, :not_connected} = read(platform, owner)
    assert ChatGPTAccounts.status_for_user(owner.id) == :not_connected
  end

  test "tenant tokens use the tenant DEK and cannot be swapped between fields or owners" do
    owner = insert_verified_user()
    other = insert_verified_user()
    grant = user_grant(owner)

    assert {:ok, "user-refresh-token"} = Cipher.decrypt_token(grant, :refresh_token)
    assert :error = Crypto.decrypt_platform(grant.access_token_ciphertext)

    assert {:error, :undecryptable} =
             Cipher.decrypt_token(%{grant | user_id: other.id}, :access_token)

    assert {:error, :undecryptable} =
             Cipher.decrypt_token(
               %{grant | access_token_ciphertext: grant.refresh_token_ciphertext},
               :access_token
             )
  end

  # This warning is the only thing that tells an operator a key rotation
  # killed the grant: the credential read answers `:none`, codex falls back
  # to the platform API key, and the status read never decrypts, so the
  # admin page still says "active". It was dropped once in the extraction
  # from `Fountain.PlatformChatGPT` because no test held it down.
  test "a token that will not decrypt says so in the log, for either owner" do
    owner = insert_verified_user()
    grant = user_grant(owner, %{access_token_ciphertext: Crypto.encrypt_platform("platform")})

    tenant_log = capture_log(fn -> assert {:error, :undecryptable} = read(grant, owner) end)
    assert tenant_log =~ "does not decrypt under the tenant key"
    assert tenant_log =~ owner.id
    assert tenant_log =~ "access_token"
    refute tenant_log =~ "platform"

    platform =
      %Account{}
      |> Account.connect_changeset(%{
        kind: "chatgpt",
        access_token_ciphertext: <<0, 1, 2, 3>>,
        last_refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    platform_log =
      capture_log(fn ->
        assert {:error, :undecryptable} = Cipher.decrypt_token(platform, :access_token)
      end)

    assert platform_log =~ "does not decrypt under MASTER_SECRETS_KEY"
    assert platform_log =~ "reconnect at /admin/inference"
  end

  test "a wrong DEK fails without attempting platform decryption" do
    owner = insert_verified_user()
    grant = user_grant(owner)
    stub(Crypto, :load_tenant_key, fn _ -> {:ok, Crypto.generate_dek()} end)
    stub(Crypto, :decrypt_platform, fn _ -> flunk("tried platform encryption as a fallback") end)
    assert {:error, :undecryptable} = read(grant, owner)
  end

  test "platform ciphertext is not reinterpreted when found in an owned row" do
    owner = insert_verified_user()
    grant = user_grant(owner, %{access_token_ciphertext: Crypto.encrypt_platform("platform")})
    assert {:error, :undecryptable} = read(grant, owner)
  end

  test "credential inspection and generic JSON encoding do not export the bearer" do
    owner = insert_verified_user()
    grant = user_grant(owner)
    assert {:ok, credential} = read(grant, owner)
    refute inspect(credential) =~ "user-access-token"
    refute inspect(credential) =~ "user-refresh-token"
    assert {:error, %Protocol.UndefinedError{}} = Jason.encode(credential)
  end

  test "unusable and stale user grants return errors without touching platform refresh" do
    owner = insert_verified_user()
    grant = user_grant(owner)

    for {attrs, reason} <- [
          {%{status: "revoked"}, :revoked},
          {%{status: "expired"}, :expired},
          {%{status: "active", access_expires_at: ~U[2020-01-01 00:00:00Z]}, :refresh_required},
          {%{status: "active", account_id: nil}, :invalid_grant}
        ] do
      Account |> Repo.get!(grant.id) |> change(attrs) |> Repo.update!()
      assert {:error, ^reason} = read(grant, owner)
    end
  end

  test "near-expiry tokens require refresh even before they lapse" do
    owner = insert_verified_user()
    expiry = Fountain.PlatformChatGPT.Tokens.expires_at(access_token(60))
    grant = user_grant(owner, %{access_expires_at: expiry})
    assert {:error, :refresh_required} = read(grant, owner)
  end

  test "encryption refuses an owner without a tenant key" do
    assert {:error, :not_found} =
             Cipher.encrypt_user_tokens(Ecto.UUID.generate(), %{
               access_token: "access",
               refresh_token: "refresh"
             })
  end

  test "lifecycle changesets cannot transfer ownership" do
    owner = insert_verified_user()
    other = insert_verified_user()
    grant = user_grant(owner)

    changed =
      grant
      |> Account.connect_changeset(%{user_id: other.id})
      |> Repo.update!()

    assert changed.user_id == owner.id
    assert {:error, :not_connected} = read(changed, other)
    assert {:ok, _} = read(changed, owner)
  end

  defp read(grant, owner),
    do: ChatGPTAccounts.credential_for_user(grant.id, owner.id, grant.generation)

  # No application writer for user grants exists until durable attempts land.
  defp user_grant(owner, overrides \\ %{}) do
    {:ok, encrypted} =
      Cipher.encrypt_user_tokens(owner.id, %{
        access_token: "user-access-token",
        refresh_token: "user-refresh-token"
      })

    attrs =
      Map.merge(encrypted, %{
        kind: "chatgpt",
        account_id: "acct-user",
        plan_type: "pro",
        id_claims: %{"account_id" => "acct-user", "user_id" => "provider-user"},
        access_expires_at: Fountain.PlatformChatGPT.Tokens.expires_at(access_token()),
        last_refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %Account{user_id: owner.id}
    |> Account.connect_changeset(attrs)
    |> change(overrides)
    |> Repo.insert!()
  end
end
