defmodule Fountain.ChatGPTAccountsTest do
  # ADR 0060 gives an owned row a name and lets a user hold several. These
  # tests hold four things: an owned row is invisible to every platform read
  # and mutation, its tokens never decrypt under the platform key (`Cipher`'s
  # owner dispatch), a user's credential read reaches exactly the grant it
  # names, and the table's naming rules. `async: false`: several insert the
  # platform row, which holds 'inference:platform' exclusive for the whole test.
  use Fountain.DataCase, async: false
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
    grant = owned_row(owner)
    other_grant = owned_row(other)

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
  end

  test "each of a user's two grants answers with its own bearer and its own source" do
    owner = insert_verified_user()
    personal = owned_row(owner, %{name: "Personal"}, "personal-access-token")
    work = owned_row(owner, %{name: "Work", account_id: "acct-work"}, "work-access-token")

    assert {:ok, %Grant{access_token: "personal-access-token", source: personal_source}} =
             read(personal, owner)

    assert {:ok, %Grant{access_token: "work-access-token", source: work_source}} =
             read(work, owner)

    assert personal_source.grant_id == personal.id
    assert personal_source.account_id == "acct-user"
    assert work_source.grant_id == work.id
    assert work_source.account_id == "acct-work"

    # One grant's pin never opens the other, under the same owner.
    assert {:error, :stale_grant} =
             ChatGPTAccounts.credential_for_user(work.id, owner.id, personal.generation)
  end

  test "an absent owner never requests platform ownership" do
    assert_raise FunctionClauseError, fn ->
      ChatGPTAccounts.credential_for_user(Ecto.UUID.generate(), nil, Ecto.UUID.generate())
    end

    assert_raise FunctionClauseError, fn ->
      Cipher.encrypt_user_tokens(nil, Ecto.UUID.generate(), %{
        access_token: "access",
        refresh_token: "refresh"
      })
    end

    # Nor is there a user blob bound to no row.
    assert_raise FunctionClauseError, fn ->
      Cipher.encrypt_user_tokens(Ecto.UUID.generate(), nil, %{
        access_token: "access",
        refresh_token: "refresh"
      })
    end
  end

  test "platform rows remain inaccessible through a user credential read" do
    owner = insert_verified_user()
    platform = %Account{} |> Account.connect_changeset(platform_attrs()) |> Repo.insert!()

    assert {:error, :not_connected} = read(platform, owner)
  end

  test "platform reads and admin mutations never select an owned grant" do
    owner = insert_verified_user()
    grant = owned_row(owner)
    second = owned_row(owner, %{account_id: "acct-second"})

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
    assert Repo.get!(Account, second.id) == second
    assert {:ok, %Grant{access_token: "user-access-token"}} = read(grant, owner)
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

  # The AAD names the grant as well as the owner and the field. Before a user
  # could hold two grants the owner was enough; now the same DEK covers
  # several rows, and one subscription's token must not open in another's.
  test "tokens cannot be swapped between two grants of one owner" do
    owner = insert_verified_user()
    personal = owned_row(owner, %{name: "Personal"}, "personal-access-token")
    work = owned_row(owner, %{name: "Work", account_id: "acct-work"}, "work-access-token")

    swapped = %{
      work
      | access_token_ciphertext: personal.access_token_ciphertext,
        refresh_token_ciphertext: personal.refresh_token_ciphertext
    }

    assert {:error, :undecryptable} = Cipher.decrypt_token(swapped, :access_token)
    assert {:error, :undecryptable} = Cipher.decrypt_token(swapped, :refresh_token)

    # Through the context too: the swapped row is written, and refused.
    work
    |> change(access_token_ciphertext: personal.access_token_ciphertext)
    |> Repo.update!()

    assert {:error, :undecryptable} = read(work, owner)
    assert {:ok, %Grant{access_token: "personal-access-token"}} = read(personal, owner)
  end

  # The grant id is in a user's AAD only. The platform row stays exactly
  # `Crypto.encrypt_platform/1`'s format, which is what production holds.
  test "the platform row's tokens are bound to nothing but the master key" do
    platform = %Account{} |> Account.connect_changeset(platform_attrs()) |> Repo.insert!()
    assert {:ok, "platform-access"} = Cipher.decrypt_token(platform, :access_token)

    assert {:ok, "platform-access"} =
             Cipher.decrypt_token(%{platform | id: Ecto.UUID.generate()}, :access_token)

    assert {:ok, "platform-access"} =
             Crypto.decrypt_platform(Cipher.encrypt_platform_token("platform-access"))
  end

  # This warning is the only thing that tells an operator a key rotation
  # killed the grant: the credential read answers `:none`, codex falls back
  # to the platform API key, and the status read never decrypts, so the
  # admin page still says "active". It was dropped once in the extraction
  # from `Fountain.PlatformChatGPT` because no test held it down.
  test "a token that will not decrypt says so in the log, for either owner" do
    owner = insert_verified_user()
    grant = owned_row(owner, %{access_token_ciphertext: Crypto.encrypt_platform("platform")})

    # Only this owner's lines: the capture is not the place to depend on what else logs.
    tenant_log =
      capture_log(fn -> assert {:error, :undecryptable} = read(grant, owner) end)
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, owner.id))
      |> Enum.join("\n")

    assert tenant_log =~ "does not decrypt under the tenant key"
    assert tenant_log =~ owner.id
    assert tenant_log =~ grant.id
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
    assert {:error, :undecryptable} = read(grant, owner)
  end

  test "platform ciphertext is not reinterpreted when found in an owned row" do
    owner = insert_verified_user()
    grant = owned_row(owner, %{access_token_ciphertext: Crypto.encrypt_platform("platform")})
    assert {:error, :undecryptable} = Cipher.decrypt_token(grant, :access_token)
    assert {:error, :undecryptable} = read(grant, owner)
  end

  test "credential inspection and generic JSON encoding do not export the bearer" do
    owner = insert_verified_user()
    grant = owned_row(owner)
    assert {:ok, credential} = read(grant, owner)
    refute inspect(credential) =~ "user-access-token"
    refute inspect(credential) =~ "user-refresh-token"
    assert {:error, %Protocol.UndefinedError{}} = Jason.encode(credential)
    assert Fountain.ChatGPTAccounts.Reserved.conflict?(%{"nested" => [credential]})
  end

  test "unusable and stale user grants return errors without touching platform refresh" do
    owner = insert_verified_user()
    grant = owned_row(owner)

    for {attrs, reason} <- [
          {%{status: "revoked"}, :revoked},
          {%{status: "expired"}, :expired},
          {%{status: "active", access_expires_at: ~U[2020-01-01 00:00:00Z]}, :refresh_required},
          {%{status: "active", account_id: nil}, :invalid_grant}
        ] do
      Account |> Repo.get!(grant.id) |> change(attrs) |> Repo.update!()

      assert {:error, ^reason} =
               ChatGPTAccounts.credential_for_user(grant.id, owner.id, grant.generation,
                 refresh: false
               )
    end
  end

  test "near-expiry tokens require refresh even before they lapse" do
    owner = insert_verified_user()
    expiry = Fountain.PlatformChatGPT.Tokens.expires_at(access_token(60))
    grant = owned_row(owner, %{access_expires_at: expiry})

    assert {:error, :refresh_required} =
             ChatGPTAccounts.credential_for_user(grant.id, owner.id, grant.generation,
               refresh: false
             )
  end

  test "encryption refuses an owner without a tenant key" do
    assert {:error, :not_found} =
             Cipher.encrypt_user_tokens(Ecto.UUID.generate(), Ecto.UUID.generate(), %{
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

    reconnected =
      changed
      |> Account.user_reconnect_changeset(%{user_id: other.id, name: "Stolen"})
      |> Repo.update!()

    assert reconnected.user_id == owner.id
    assert reconnected.name == grant.name
    refute reconnected.generation == changed.generation
    assert {:error, :not_connected} = read(reconnected, other)
    assert {:ok, _} = read(reconnected, owner)
  end

  # The owner is `user_id` and the actor is on the audit event. A second user
  # column on an owned row would have one account's deletion nilify, and so
  # write, another account's grant row.
  test "an owned row's changesets never set the operator column" do
    owner = insert_verified_user()
    other = insert_verified_user()

    linked =
      %Account{id: Ecto.UUID.generate(), user_id: owner.id}
      |> Account.user_connect_changeset(
        owner
        |> owned_attrs("acct-linked", "Linked")
        |> Map.put(:updated_by_user_id, other.id)
      )
      |> Repo.insert!()

    assert linked.updated_by_user_id == nil

    reconnected =
      linked
      |> Account.user_reconnect_changeset(%{updated_by_user_id: other.id})
      |> Repo.update!()

    assert reconnected.updated_by_user_id == nil
    assert Repo.get!(Account, linked.id).updated_by_user_id == nil
  end

  describe "an owned row is named, and a user may hold several (ADR 0060 decision 1)" do
    test "two grants for one user, and the platform row beside them" do
      owner = insert_verified_user()
      first = owned_row(owner, %{name: "Personal"})
      second = owned_row(owner, %{name: "Work", account_id: "acct-work"})

      platform =
        %Account{}
        |> Account.connect_changeset(platform_attrs())
        |> Repo.insert!()

      assert first.user_id == second.user_id
      refute first.id == second.id
      assert platform.name == nil
      assert Repo.get!(Account, platform.id) == platform
    end

    test "a name is unique per owner, not across owners" do
      owner = insert_verified_user()
      other = insert_verified_user()
      owned_row(owner, %{name: "Work"})
      owned_row(other, %{name: "Work"})

      assert {:error, changeset} =
               %Account{user_id: owner.id}
               |> Account.user_connect_changeset(owned_attrs(owner, "acct-second", "  Work  "))
               |> Repo.insert()

      assert %{name: ["already names a ChatGPT subscription on this account"]} =
               errors_on(changeset)
    end

    test "one upstream account is linked once per owner" do
      owner = insert_verified_user()
      other = insert_verified_user()
      owned_row(owner, %{name: "Personal"})
      owned_row(other, %{name: "Personal"})

      assert {:error, changeset} =
               %Account{user_id: owner.id}
               |> Account.user_connect_changeset(owned_attrs(owner, "acct-user", "Again"))
               |> Repo.insert()

      assert %{account_id: ["is already linked to this account"]} = errors_on(changeset)
    end

    test "a first link needs a name, an account id, a refresh token and the chatgpt kind" do
      owner = insert_verified_user()
      attrs = owned_attrs(owner, "acct-user", "Personal")

      for {broken, field} <- [
            {%{attrs | name: "   "}, :name},
            {%{attrs | name: String.duplicate("n", 201)}, :name},
            {Map.delete(attrs, :name), :name},
            {%{attrs | account_id: nil}, :account_id},
            {%{attrs | refresh_token_ciphertext: nil}, :refresh_token_ciphertext},
            {%{attrs | kind: "workspace_token"}, :kind}
          ] do
        changeset = Account.user_connect_changeset(%Account{user_id: owner.id}, broken)
        refute changeset.valid?
        assert Map.has_key?(errors_on(changeset), field)
      end

      assert_raise FunctionClauseError, fn ->
        Account.user_connect_changeset(%Account{}, attrs)
      end
    end

    test "the database refuses an owned row without a name and a platform row with one" do
      owner = insert_verified_user()

      for row <- [
            %Account{user_id: owner.id},
            %Account{user_id: owner.id, name: "  "},
            %Account{name: "Platform"}
          ] do
        assert_raise Ecto.ConstraintError, ~r/chatgpt_grant_name_follows_owner/, fn ->
          # A savepoint: the refused insert must not abort the test's transaction.
          Repo.transaction(fn ->
            Repo.insert!(%{row | kind: "chatgpt", access_token_ciphertext: "constraint-test"})
          end)
        end
      end
    end

    test "a rename changes the label and neither the generation nor the version" do
      owner = insert_verified_user()
      other = insert_verified_user()
      grant = owned_row(owner, %{name: "Personal"})

      renamed =
        grant
        |> Account.rename_changeset(%{
          name: " Work ",
          user_id: other.id,
          generation: Ecto.UUID.generate(),
          lock_version: 9,
          account_id: "acct-other",
          status: "revoked"
        })
        |> Repo.update!()

      assert renamed.name == "Work"

      assert Repo.get!(Account, grant.id) == %{
               grant
               | name: "Work",
                 updated_at: renamed.updated_at
             }

      assert_raise FunctionClauseError, fn ->
        Account.rename_changeset(%Account{}, %{name: "Platform"})
      end
    end
  end

  # `fountain_lock_inference_source()` refuses it, whatever wrote the UPDATE
  # (ADR 0052 decision 1: no transfer of a grant between users or scopes).
  test "the database refuses to change a grant's owner" do
    owner = insert_verified_user()
    other = insert_verified_user()
    grant = owned_row(owner)
    platform = %Account{} |> Account.connect_changeset(platform_attrs()) |> Repo.insert!()

    for {row, user_id} <- [{grant, other.id}, {grant, nil}, {platform, owner.id}] do
      error =
        assert_raise Postgrex.Error, fn ->
          # A savepoint: the refused update must not abort the test's transaction.
          Repo.transaction(fn ->
            Repo.update_all(from(a in Account, where: a.id == ^row.id),
              set: [user_id: user_id, name: user_id && "moved"]
            )
          end)
        end

      assert error.postgres.message == "a ChatGPT grant never changes its owner"
    end

    assert Repo.get!(Account, grant.id) == grant
    assert Repo.get!(Account, platform.id) == platform
  end

  defp platform_attrs do
    %{
      kind: "chatgpt",
      access_token_ciphertext: Crypto.encrypt_platform("platform-access"),
      last_refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp owned_attrs(owner, account_id, name) do
    {:ok, encrypted} =
      Cipher.encrypt_user_tokens(owner.id, Ecto.UUID.generate(), %{
        access_token: "user-access-token",
        refresh_token: "user-refresh-token"
      })

    Map.merge(encrypted, %{
      name: name,
      kind: "chatgpt",
      account_id: account_id,
      last_refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp read(grant, owner),
    do: ChatGPTAccounts.credential_for_user(grant.id, owner.id, grant.generation)

  # Nothing in the application writes an owned row yet; this is the shape one
  # has, inserted straight through the schema. The name is unique per call
  # because `(user_id, name)` is; pass `:account_id` for a user's second row.
  defp owned_row(owner, overrides \\ %{}, access \\ "user-access-token") do
    id = Ecto.UUID.generate()

    {:ok, encrypted} =
      Cipher.encrypt_user_tokens(owner.id, id, %{
        access_token: access,
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

    %Account{id: id, user_id: owner.id, name: "grant-#{System.unique_integer([:positive])}"}
    |> Account.connect_changeset(attrs)
    |> change(overrides)
    |> Repo.insert!()
  end
end
