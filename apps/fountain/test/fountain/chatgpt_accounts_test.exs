defmodule Fountain.ChatGPTAccountsTest do
  # The `user_id` column outlived the tenant-owner half of ADR 0052 (#2188).
  # These tests hold two things about it: an owned row, should one ever be
  # written, is invisible to every platform read and mutation, and its
  # tokens never decrypt under the platform key (`Cipher`'s owner dispatch).
  use Fountain.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  import Fountain.ChatGPTFixtures, only: [access_token: 0]

  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.Cipher
  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT.Account

  test "an absent owner never requests platform encryption" do
    assert_raise FunctionClauseError, fn ->
      Cipher.encrypt_user_tokens(nil, %{access_token: "access", refresh_token: "refresh"})
    end
  end

  test "platform reads and admin mutations never select an owned grant" do
    owner = insert_verified_user()
    grant = owned_row(owner)

    refute ChatGPTAccounts.platform_active?()
    assert ChatGPTAccounts.platform_status() == :not_connected
    assert ChatGPTAccounts.platform_credential() == :none
    assert ChatGPTAccounts.platform_credential(refresh: false) == :none
    assert ChatGPTAccounts.platform_access_token() == {:error, :not_connected}
    assert ChatGPTAccounts.platform_sandbox_auth() == :none
    assert ChatGPTAccounts.platform_keepalive() == {:ok, :skipped}
    assert ChatGPTAccounts.platform_refresh_serialized(:if_stale) == {:error, :not_connected}
    assert :ok = ChatGPTAccounts.platform_disconnect()
    assert Repo.get!(Account, grant.id) == grant

    assert {:ok, platform} =
             ChatGPTAccounts.platform_connect_workspace_token("wst_platform", nil,
               account_id: "acct-platform"
             )

    assert platform.user_id == nil
    refute platform.id == grant.id
    assert ChatGPTAccounts.platform_status().account_id == "acct-platform"
    assert ChatGPTAccounts.platform_access_token() == {:ok, "wst_platform"}
    assert :ok = ChatGPTAccounts.platform_disconnect()
    assert Repo.get!(Account, grant.id) == grant
  end

  test "tenant tokens use the tenant DEK and cannot be swapped between fields or owners" do
    owner = insert_verified_user()
    other = insert_verified_user()
    grant = owned_row(owner)

    assert {:ok, "user-access-token"} = Cipher.decrypt_token(grant, :access_token)
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
    grant = owned_row(owner, %{access_token_ciphertext: Crypto.encrypt_platform("platform")})

    tenant_log =
      capture_log(fn ->
        assert {:error, :undecryptable} = Cipher.decrypt_token(grant, :access_token)
      end)

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
    grant = owned_row(owner)
    stub(Crypto, :load_tenant_key, fn _ -> {:ok, Crypto.generate_dek()} end)
    stub(Crypto, :decrypt_platform, fn _ -> flunk("tried platform encryption as a fallback") end)
    assert {:error, :undecryptable} = Cipher.decrypt_token(grant, :access_token)
  end

  test "platform ciphertext is not reinterpreted when found in an owned row" do
    owner = insert_verified_user()
    grant = owned_row(owner, %{access_token_ciphertext: Crypto.encrypt_platform("platform")})
    assert {:error, :undecryptable} = Cipher.decrypt_token(grant, :access_token)
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
    grant = owned_row(owner)

    changed =
      grant
      |> Account.connect_changeset(%{user_id: other.id})
      |> Repo.update!()

    assert changed.user_id == owner.id
  end

  # Nothing in the application writes an owned row; this is the shape one
  # would have, inserted straight through the schema.
  defp owned_row(owner, overrides \\ %{}) do
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
