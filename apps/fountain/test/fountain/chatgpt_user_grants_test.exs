defmodule Fountain.ChatGPTUserGrantsTest do
  # ADR 0060 stage 1: a user links several ChatGPT subscriptions. Every test
  # starts with the deployment's own grant connected and ends by proving it
  # is exactly as it was: nothing a user does to their grants touches it.
  # `async: false`: connecting the platform row holds 'inference:platform'
  # exclusive for the whole test.
  use Fountain.DataCase, async: false
  use Mimic

  import Fountain.ChatGPTFixtures

  alias Fountain.Audit.{AdminEvent, Event}
  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.Grant
  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT.Account

  setup do
    platform = connect!()

    %{
      user: insert_verified_user(),
      other: insert_verified_user(),
      platform: platform,
      admin_events: Repo.aggregate(AdminEvent, :count)
    }
  end

  # The last line of every test here.
  defp assert_platform_untouched(ctx) do
    assert Repo.get!(Account, ctx.platform.id) == ctx.platform
    assert %{status: "active", account_id: "acct_platform_1"} = ChatGPTAccounts.platform_status()

    assert ChatGPTAccounts.platform_selection() ==
             {:ok, %{grant_id: ctx.platform.id, generation: ctx.platform.generation}}

    # A user's grant never writes the privilege trail.
    assert Repo.aggregate(AdminEvent, :count) == ctx.admin_events
  end

  describe "two grants for one user" do
    test "both are listed by name, and each answers with its own bearer and source", ctx do
      assert ChatGPTAccounts.list_for_user(ctx.user.id) == []

      assert {:ok, work} = link(ctx.user, "Work", "acct-work", access: bearer("work"))
      assert {:ok, personal} = link(ctx.user, "Personal", "acct-personal")

      assert [%{name: "Personal"} = listed_personal, %{name: "Work"} = listed_work] =
               ChatGPTAccounts.list_for_user(ctx.user.id)

      assert listed_personal == personal
      assert listed_work == work
      assert {:ok, ^work} = ChatGPTAccounts.get_for_user(work.grant_id, ctx.user.id)
      assert ChatGPTAccounts.list_for_user(ctx.other.id) == []

      assert %{
               status: "active",
               kind: "chatgpt",
               refreshable: true,
               lock_version: 1,
               account_id: "acct-work",
               account_email: "admin@example.com",
               plan_type: "pro",
               revoked_reason: nil,
               exhausted_until: nil
             } = work

      # The view is the pin the credential read takes.
      assert {:ok, %Grant{access_token: access, source: source}} = credential(work, ctx.user)
      assert access == bearer("work")
      assert source.grant_id == work.grant_id
      assert source.account_id == "acct-work"
      assert source.owner_scope == {:user, ctx.user.id}

      assert {:ok, %Grant{source: %{grant_id: personal_id, account_id: "acct-personal"}}} =
               credential(personal, ctx.user)

      assert personal_id == personal.grant_id
      assert_platform_untouched(ctx)
    end

    test "a link leaves a tenant event with the grant's name and nothing of the provider's",
         ctx do
      assert {:ok, grant} =
               link(ctx.user, "Work", "acct-work", [], actor: "api", request_ip: "203.0.113.7")

      event = Repo.one!(from(e in Event, where: e.action == "chatgpt_grant.connected"))
      assert event.user_id == ctx.user.id
      assert event.actor == "api"
      assert event.request_ip == "203.0.113.7"
      assert event.resource_type == "chatgpt_grant"
      assert event.resource_id == grant.grant_id

      assert event.metadata == %{
               "name" => "Work",
               "method" => "device_code",
               "plan" => "pro"
             }

      assert_platform_untouched(ctx)
    end

    test "the stored row is the owner's alone: tenant encryption and no operator column", ctx do
      assert {:ok, grant} = link(ctx.user, "Work", "acct-work")
      row = Repo.get!(Account, grant.grant_id)

      assert row.user_id == ctx.user.id
      assert row.updated_by_user_id == nil
      assert :error = Crypto.decrypt_platform(row.access_token_ciphertext)
      assert :error = Crypto.decrypt_platform(row.refresh_token_ciphertext)
      refute Map.has_key?(row.id_claims, "email")
      assert_platform_untouched(ctx)
    end
  end

  describe "a name is unique per user" do
    test "a second link under a taken name is refused, and another user may use it", ctx do
      assert {:ok, _} = link(ctx.user, "Work", "acct-work")

      assert {:error, %Ecto.Changeset{} = changeset} = link(ctx.user, " Work ", "acct-second")

      assert %{name: ["already names a ChatGPT subscription on this account"]} =
               errors_on(changeset)

      assert {:ok, _} = link(ctx.other, "Work", "acct-work")
      assert [%{name: "Work"}] = ChatGPTAccounts.list_for_user(ctx.user.id)
      assert [%{action: "chatgpt_grant.connected"}] = grant_events(ctx.user)
      assert_platform_untouched(ctx)
    end

    test "a blank or oversized name is refused", ctx do
      for name <- ["", "   ", String.duplicate("n", 201)] do
        assert {:error, %Ecto.Changeset{} = changeset} = link(ctx.user, name, "acct-work")
        assert Map.has_key?(errors_on(changeset), :name)
      end

      assert ChatGPTAccounts.list_for_user(ctx.user.id) == []
      assert_platform_untouched(ctx)
    end

    test "a rename to a blank or oversized name is refused, and writes and records nothing",
         ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")
      row = Repo.get!(Account, work.grant_id)

      for name <- ["", "   ", String.duplicate("n", 201)] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 ChatGPTAccounts.rename_for_user(work.grant_id, ctx.user.id, name)

        assert Map.has_key?(errors_on(changeset), :name)
      end

      assert Repo.get!(Account, work.grant_id) == row
      assert [%{action: "chatgpt_grant.connected"}] = grant_events(ctx.user)
      assert_platform_untouched(ctx)
    end

    test "a rename keeps the pin, refuses a taken name, and records only a real change", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")
      assert {:ok, _personal} = link(ctx.user, "Personal", "acct-personal")

      assert {:ok, renamed} =
               ChatGPTAccounts.rename_for_user(work.grant_id, ctx.user.id, " Day job ",
                 actor: "ui"
               )

      assert renamed.name == "Day job"
      assert renamed.generation == work.generation
      assert renamed.lock_version == work.lock_version
      assert {:ok, %Grant{}} = credential(work, ctx.user)

      event = Repo.one!(from(e in Event, where: e.action == "chatgpt_grant.renamed"))
      assert event.actor == "ui"
      assert event.resource_id == work.grant_id
      assert event.metadata == %{"name" => "Day job", "previous_name" => "Work"}

      assert {:error, %Ecto.Changeset{} = changeset} =
               ChatGPTAccounts.rename_for_user(work.grant_id, ctx.user.id, "Personal")

      assert Map.has_key?(errors_on(changeset), :name)

      assert {:ok, %{name: "Day job"}} =
               ChatGPTAccounts.rename_for_user(work.grant_id, ctx.user.id, "Day job")

      assert Repo.aggregate(from(e in Event, where: e.action == "chatgpt_grant.renamed"), :count) ==
               1

      assert_platform_untouched(ctx)
    end
  end

  describe "one upstream account is linked once per user" do
    test "a second link of the same account names the grant that holds it", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")

      assert {:error, {:account_already_linked, linked}} = link(ctx.user, "Again", "acct-work")
      assert linked == %{grant_id: work.grant_id, name: "Work"}

      assert {:ok, _} = link(ctx.other, "Work", "acct-work")
      assert [%{name: "Work"}] = ChatGPTAccounts.list_for_user(ctx.user.id)
      assert_platform_untouched(ctx)
    end

    test "a reconnect with the same account advances the generation and keeps the row", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")

      assert {:ok, again} =
               ChatGPTAccounts.reconnect_for_user(
                 work.grant_id,
                 ctx.user.id,
                 tokens("acct-work", access: bearer("again")),
                 method: "device_code",
                 actor: "ui"
               )

      assert again.grant_id == work.grant_id
      assert again.name == "Work"
      refute again.generation == work.generation
      assert again.lock_version == work.lock_version + 1

      assert {:error, :stale_grant} = credential(work, ctx.user)
      assert {:ok, %Grant{access_token: access}} = credential(again, ctx.user)
      assert access == bearer("again")

      assert [_first, reconnect] =
               Repo.all(
                 from(e in Event,
                   where: e.action == "chatgpt_grant.connected",
                   order_by: [asc: e.inserted_at, asc: e.id]
                 )
               )

      assert reconnect.metadata["reconnect"] == true
      refute Map.has_key?(reconnect.metadata, "generation")
      assert_platform_untouched(ctx)
    end

    test "a late completion against a newer reconnect is refused and leaves the newer one alone",
         ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")

      # Two sign-ins begin against the same generation; this one finishes first.
      assert {:ok, first} =
               ChatGPTAccounts.reconnect_for_user(
                 work.grant_id,
                 ctx.user.id,
                 tokens("acct-work", access: bearer("first")),
                 expected_generation: work.generation
               )

      row = Repo.get!(Account, work.grant_id)

      assert {:error, :stale_grant} =
               ChatGPTAccounts.reconnect_for_user(
                 work.grant_id,
                 ctx.user.id,
                 tokens("acct-work", access: bearer("late")),
                 expected_generation: work.generation
               )

      assert Repo.get!(Account, work.grant_id) == row
      assert {:ok, %Grant{access_token: access}} = credential(first, ctx.user)
      assert access == bearer("first")

      assert Repo.aggregate(
               from(e in Event, where: e.action == "chatgpt_grant.connected"),
               :count
             ) == 2

      # Another user's grant answers as it does without the fence.
      assert {:error, :not_found} =
               ChatGPTAccounts.reconnect_for_user(
                 work.grant_id,
                 ctx.other.id,
                 tokens("acct-t"),
                 expected_generation: first.generation
               )

      assert_platform_untouched(ctx)
    end

    test "a reconnect may change the account, but not onto another of the user's grants", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")
      assert {:ok, personal} = link(ctx.user, "Personal", "acct-personal")

      assert {:error, {:account_already_linked, linked}} =
               ChatGPTAccounts.reconnect_for_user(
                 work.grant_id,
                 ctx.user.id,
                 tokens("acct-personal")
               )

      assert linked == %{grant_id: personal.grant_id, name: "Personal"}
      assert {:ok, ^work} = ChatGPTAccounts.get_for_user(work.grant_id, ctx.user.id)

      assert {:ok, %{account_id: "acct-new-job", name: "Work"}} =
               ChatGPTAccounts.reconnect_for_user(
                 work.grant_id,
                 ctx.user.id,
                 tokens("acct-new-job")
               )

      assert_platform_untouched(ctx)
    end

    test "the index stands behind the check made under the lock", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")
      row = Repo.get!(Account, work.grant_id)

      # Past the context's check on purpose: only the index stands here.
      assert {:error, changeset} =
               %Account{id: Ecto.UUID.generate(), user_id: ctx.user.id}
               |> Account.user_connect_changeset(%{
                 name: "Again",
                 kind: "chatgpt",
                 account_id: "acct-work",
                 access_token_ciphertext: row.access_token_ciphertext,
                 refresh_token_ciphertext: row.refresh_token_ciphertext,
                 last_refreshed_at: row.last_refreshed_at
               })
               |> Repo.insert()

      assert %{account_id: ["is already linked to this account"]} = errors_on(changeset)
      assert_platform_untouched(ctx)
    end
  end

  describe "a token set that cannot be a user's grant" do
    test "no refresh token, or an id_token with no account, is refused before anything is read",
         ctx do
      stub(Crypto, :load_tenant_key, fn _ -> flunk("loaded a key for a refused link") end)

      assert {:error, :no_refresh_token} =
               ChatGPTAccounts.connect_for_user(ctx.user.id, "Work", %{
                 access_token: access_token(),
                 refresh_token: nil,
                 id_token: id_token()
               })

      assert {:error, :invalid_id_token} =
               ChatGPTAccounts.connect_for_user(ctx.user.id, "Work", %{
                 access_token: access_token(),
                 refresh_token: "rt",
                 id_token: jwt(%{"email" => "nobody@example.com"})
               })

      assert ChatGPTAccounts.list_for_user(ctx.user.id) == []
      assert_platform_untouched(ctx)
    end

    test "an absent owner never means the platform", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")

      for call <- [
            fn -> ChatGPTAccounts.list_for_user(nil) end,
            fn -> ChatGPTAccounts.get_for_user(work.grant_id, nil) end,
            fn -> ChatGPTAccounts.connect_for_user(nil, "Work", tokens("acct-x")) end,
            fn -> ChatGPTAccounts.reconnect_for_user(work.grant_id, nil, tokens("acct-x")) end,
            fn -> ChatGPTAccounts.rename_for_user(work.grant_id, nil, "Stolen") end,
            fn -> ChatGPTAccounts.disconnect_for_user(work.grant_id, nil) end,
            fn -> ChatGPTAccounts.remove_for_user(work.grant_id, nil) end
          ] do
        assert_raise FunctionClauseError, call
      end

      assert_platform_untouched(ctx)
    end
  end

  describe "another user's grant" do
    test "cannot be read, renamed, reconnected, disconnected or removed", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")
      row = Repo.get!(Account, work.grant_id)
      id = work.grant_id
      thief = ctx.other.id

      assert {:error, :not_found} = ChatGPTAccounts.get_for_user(id, thief)
      assert {:error, :not_found} = ChatGPTAccounts.rename_for_user(id, thief, "Stolen")

      assert {:error, :not_found} =
               ChatGPTAccounts.reconnect_for_user(id, thief, tokens("acct-t"))

      assert {:error, :not_found} = ChatGPTAccounts.disconnect_for_user(id, thief)
      assert {:error, :not_found} = ChatGPTAccounts.remove_for_user(id, thief)
      assert {:error, :not_connected} = credential(work, ctx.other)

      assert {:error, :not_connected} =
               ChatGPTAccounts.refresh_for_user(id, thief, work.generation)

      assert ChatGPTAccounts.list_for_user(thief) == []
      assert Repo.get!(Account, id) == row
      assert grant_events(ctx.other) == []
      assert [%{action: "chatgpt_grant.connected"}] = grant_events(ctx.user)
      assert_platform_untouched(ctx)
    end

    test "the platform row is not a user's grant, and neither is an id that is not one", ctx do
      platform = Repo.one!(from(a in Account, where: is_nil(a.user_id)))

      for id <- [platform.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :not_found} = ChatGPTAccounts.get_for_user(id, ctx.user.id)
        assert {:error, :not_found} = ChatGPTAccounts.rename_for_user(id, ctx.user.id, "Mine")
        assert {:error, :not_found} = ChatGPTAccounts.disconnect_for_user(id, ctx.user.id)
        assert {:error, :not_found} = ChatGPTAccounts.remove_for_user(id, ctx.user.id)

        assert {:error, :not_found} =
                 ChatGPTAccounts.reconnect_for_user(id, ctx.user.id, tokens("acct-mine"))

        # The credential half refuses the same ids, in its own word.
        assert {:error, :not_connected} =
                 ChatGPTAccounts.credential_for_user(id, ctx.user.id, platform.generation)

        assert {:error, :not_connected} =
                 ChatGPTAccounts.refresh_for_user(id, ctx.user.id, platform.generation)

        assert {:error, :not_connected} =
                 ChatGPTAccounts.refresh_serialized_for_user(
                   id,
                   ctx.user.id,
                   platform.generation
                 )
      end

      assert_platform_untouched(ctx)
    end

    test "an owner id that is not one owns nothing, and is refused rather than raised", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")
      row = Repo.get!(Account, work.grant_id)
      id = work.grant_id

      for owner <- ["not-a-uuid", "../" <> ctx.user.id, ""] do
        assert ChatGPTAccounts.list_for_user(owner) == []
        assert {:error, :not_found} = ChatGPTAccounts.get_for_user(id, owner)
        assert {:error, :ineligible_owner} = link(%{id: owner}, "Mine", "acct-mine")

        assert {:error, :not_found} =
                 ChatGPTAccounts.reconnect_for_user(id, owner, tokens("acct-mine"))

        assert {:error, :not_found} = ChatGPTAccounts.rename_for_user(id, owner, "Mine")
        assert {:error, :not_found} = ChatGPTAccounts.disconnect_for_user(id, owner)
        assert {:error, :not_found} = ChatGPTAccounts.remove_for_user(id, owner)

        assert {:error, :not_connected} =
                 ChatGPTAccounts.credential_for_user(id, owner, work.generation)

        assert {:error, :not_connected} =
                 ChatGPTAccounts.refresh_for_user(id, owner, work.generation)

        assert {:error, :not_connected} =
                 ChatGPTAccounts.refresh_serialized_for_user(id, owner, work.generation)
      end

      assert Repo.get!(Account, id) == row
      assert [%{action: "chatgpt_grant.connected"}] = grant_events(ctx.user)
      assert_platform_untouched(ctx)
    end
  end

  describe "who may link" do
    for attrs <- [
          %{principal: true},
          %{email_verified_at: nil},
          %{suspended_at: ~U[2026-09-01 00:00:00Z]}
        ] do
      test "an owner with #{inspect(attrs)} cannot link, reconnect or rename, and can still " <>
             "see, disconnect and remove",
           ctx do
        assert {:ok, work} = link(ctx.user, "Work", "acct-work")
        ctx.user |> change(unquote(Macro.escape(attrs))) |> Repo.update!()

        assert {:error, :ineligible_owner} = link(ctx.user, "Personal", "acct-personal")

        assert {:error, :ineligible_owner} =
                 ChatGPTAccounts.reconnect_for_user(work.grant_id, ctx.user.id, tokens("acct-w"))

        assert {:error, :not_connected} = credential(work, ctx.user)

        assert {:error, :ineligible_owner} =
                 ChatGPTAccounts.rename_for_user(work.grant_id, ctx.user.id, "Old job")

        assert [%{action: "chatgpt_grant.connected"}] = grant_events(ctx.user)

        # What is already there is not orphaned: it can be seen, and taken away.
        assert [%{name: "Work"}] = ChatGPTAccounts.list_for_user(ctx.user.id)
        assert {:ok, ^work} = ChatGPTAccounts.get_for_user(work.grant_id, ctx.user.id)
        assert :ok = ChatGPTAccounts.disconnect_for_user(work.grant_id, ctx.user.id)
        assert :ok = ChatGPTAccounts.remove_for_user(work.grant_id, ctx.user.id)
        assert_platform_untouched(ctx)
      end
    end
  end

  describe "metadata reads" do
    test "neither decrypt nor refresh, and sanitize an unknown failure reason", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")

      Account
      |> Repo.get!(work.grant_id)
      |> change(%{status: "revoked", revoked_reason: "raw-provider-secret"})
      |> Repo.update!()

      stub(Crypto, :load_tenant_key, fn _ -> flunk("a metadata read loaded a token key") end)
      stub(Crypto, :decrypt_platform, fn _ -> flunk("a metadata read decrypted a token") end)
      stub(Crypto, :decrypt, fn _, _, _ -> flunk("a metadata read decrypted a token") end)

      assert {:ok, view} = ChatGPTAccounts.get_for_user(work.grant_id, ctx.user.id)
      assert [^view] = ChatGPTAccounts.list_for_user(ctx.user.id)
      assert view.status == "revoked"
      assert view.revoked_reason == "provider_error"
      refute inspect(view) =~ "raw-provider-secret"

      refute Enum.any?(Map.keys(view), &String.contains?(Atom.to_string(&1), "ciphertext"))
      assert {:ok, _} = Jason.encode(view)

      # The closing platform check does decrypt, and should.
      stub(Crypto, :decrypt_platform, &call_original(Crypto, :decrypt_platform, [&1]))
      assert_platform_untouched(ctx)
    end

    test "every terminal code OAuth names survives the reason allowlist", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")

      for code <- Fountain.PlatformChatGPT.OAuth.terminal_codes() do
        Account
        |> Repo.get!(work.grant_id)
        |> change(%{status: "revoked", revoked_reason: code})
        |> Repo.update!()

        assert {:ok, %{revoked_reason: ^code}} =
                 ChatGPTAccounts.get_for_user(work.grant_id, ctx.user.id)
      end

      assert_platform_untouched(ctx)
    end
  end

  describe "disconnect is a tombstone" do
    test "the tokens go; the id, the name and the account stay; every pin is stale", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")
      assert {:ok, personal} = link(ctx.user, "Personal", "acct-personal")
      untouched = Repo.get!(Account, personal.grant_id)

      assert :ok = ChatGPTAccounts.disconnect_for_user(work.grant_id, ctx.user.id, actor: "ui")

      row = Repo.get!(Account, work.grant_id)
      assert row.status == "disconnected"
      assert row.access_token_ciphertext == nil
      assert row.refresh_token_ciphertext == nil
      assert row.id_claims == %{}
      assert row.access_expires_at == nil
      assert row.name == "Work"
      assert row.account_id == "acct-work"
      refute row.generation == work.generation
      assert row.lock_version == work.lock_version + 1

      assert {:ok, gone} = ChatGPTAccounts.get_for_user(work.grant_id, ctx.user.id)
      assert %{status: "disconnected", refreshable: false, name: "Work"} = gone
      assert [%{name: "Personal"}, ^gone] = ChatGPTAccounts.list_for_user(ctx.user.id)

      # Neither the old pin nor the new one yields a credential, and neither
      # reaches for another grant or for the platform's.
      assert {:error, :stale_grant} = credential(work, ctx.user)
      assert {:error, :disconnected} = credential(gone, ctx.user)

      assert {:error, :disconnected} =
               ChatGPTAccounts.refresh_for_user(gone.grant_id, ctx.user.id, gone.generation)

      assert {:error, :disconnected} =
               ChatGPTAccounts.refresh_serialized_for_user(
                 gone.grant_id,
                 ctx.user.id,
                 gone.generation
               )

      event = Repo.one!(from(e in Event, where: e.action == "chatgpt_grant.disconnected"))
      assert event.actor == "ui"
      assert event.resource_id == work.grant_id
      # A fencing value is in no tenant event: `GET /api/audit` is any key's to read.
      assert event.metadata == %{"name" => "Work"}

      # Idempotent, and silent the second time.
      assert :ok = ChatGPTAccounts.disconnect_for_user(work.grant_id, ctx.user.id)
      assert Repo.get!(Account, work.grant_id) == row

      assert Repo.aggregate(
               from(e in Event, where: e.action == "chatgpt_grant.disconnected"),
               :count
             ) == 1

      assert Repo.get!(Account, personal.grant_id) == untouched
      assert {:ok, %Grant{}} = credential(personal, ctx.user)
      assert_platform_untouched(ctx)
    end

    test "the same subscription comes back by reconnecting the tombstone, not by a second link",
         ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")
      assert :ok = ChatGPTAccounts.disconnect_for_user(work.grant_id, ctx.user.id)

      assert {:error, {:account_already_linked, linked}} = link(ctx.user, "Work 2", "acct-work")
      assert linked == %{grant_id: work.grant_id, name: "Work"}

      assert {:ok, back} =
               ChatGPTAccounts.reconnect_for_user(
                 work.grant_id,
                 ctx.user.id,
                 tokens("acct-work", access: bearer("back"))
               )

      assert %{status: "active", refreshable: true, name: "Work"} = back
      assert back.grant_id == work.grant_id
      assert {:ok, %Grant{access_token: access}} = credential(back, ctx.user)
      assert access == bearer("back")
      assert_platform_untouched(ctx)
    end

    test "only a disconnected grant is removed, and removal frees its account", ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")
      row = Repo.get!(Account, work.grant_id)

      assert {:error, :still_connected} =
               ChatGPTAccounts.remove_for_user(work.grant_id, ctx.user.id)

      assert Repo.get!(Account, work.grant_id) == row
      refute Repo.exists?(from(e in Event, where: e.action == "chatgpt_grant.removed"))

      assert :ok = ChatGPTAccounts.disconnect_for_user(work.grant_id, ctx.user.id)
      assert :ok = ChatGPTAccounts.remove_for_user(work.grant_id, ctx.user.id, actor: "api")
      refute Repo.get(Account, work.grant_id)
      assert ChatGPTAccounts.list_for_user(ctx.user.id) == []

      event = Repo.one!(from(e in Event, where: e.action == "chatgpt_grant.removed"))
      assert event.actor == "api"
      assert event.resource_id == work.grant_id
      assert event.metadata == %{"name" => "Work"}

      assert {:error, :not_found} = ChatGPTAccounts.remove_for_user(work.grant_id, ctx.user.id)
      assert {:ok, _} = link(ctx.user, "Work", "acct-work")
      assert_platform_untouched(ctx)
    end

    test "the database refuses a tombstone with a token, a live row without one, and a " <>
           "disconnected platform row",
         ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-work")
      platform = Repo.one!(from(a in Account, where: is_nil(a.user_id)))

      for {id, sets} <- [
            {work.grant_id, [status: "disconnected"]},
            {work.grant_id, [access_token_ciphertext: nil]},
            {platform.id,
             [status: "disconnected", access_token_ciphertext: nil, refresh_token_ciphertext: nil]}
          ] do
        assert_raise Postgrex.Error, ~r/chatgpt_grant_tokens_follow_status/, fn ->
          Repo.transaction(fn ->
            Repo.update_all(from(a in Account, where: a.id == ^id), set: sets)
          end)
        end
      end

      assert_platform_untouched(ctx)
    end
  end

  describe "audit" do
    test "every event is recorded after its write has committed", ctx do
      test = self()

      stub(Fountain.Audit, :record, fn attrs ->
        send(test, {:audited, attrs.action, Repo.in_transaction?()})
        {:error, :unavailable}
      end)

      # The control: this is what the stub would see from inside a write.
      assert Repo.transaction(fn -> Repo.in_transaction?() end) == {:ok, true}

      assert {:ok, work} = link(ctx.user, "Work", "acct-work")
      assert {:ok, _} = ChatGPTAccounts.rename_for_user(work.grant_id, ctx.user.id, "Job")

      assert {:ok, _} =
               ChatGPTAccounts.reconnect_for_user(work.grant_id, ctx.user.id, tokens("acct-work"))

      assert :ok = ChatGPTAccounts.disconnect_for_user(work.grant_id, ctx.user.id)
      assert :ok = ChatGPTAccounts.remove_for_user(work.grant_id, ctx.user.id)

      for action <- ~w(connected renamed connected disconnected removed) do
        expected = "chatgpt_grant." <> action
        assert_received {:audited, ^expected, false}
        assert_platform_untouched(ctx)
      end

      refute_received {:audited, _, _}
    end

    test "no event carries a token, a ciphertext, an email or the provider's account id", ctx do
      access = bearer("audited")
      assert {:ok, work} = link(ctx.user, "Work", "acct-secret-id", access: access)
      assert {:ok, _} = ChatGPTAccounts.rename_for_user(work.grant_id, ctx.user.id, "Job")
      assert :ok = ChatGPTAccounts.disconnect_for_user(work.grant_id, ctx.user.id)
      assert :ok = ChatGPTAccounts.remove_for_user(work.grant_id, ctx.user.id)

      events = grant_events(ctx.user)
      assert length(events) == 4

      for event <- events do
        dumped = inspect(event.metadata)
        refute dumped =~ access
        refute dumped =~ "rt_acct-secret-id"
        refute dumped =~ "acct-secret-id"
        refute dumped =~ "admin@example.com"
      end

      assert_platform_untouched(ctx)
    end
  end

  describe "inspection" do
    # A refusal hands its caller a changeset, and the ordinary thing to do
    # with an unexpected one is to log it.
    test "neither a row nor a refused changeset prints a ciphertext, the email or a claim",
         ctx do
      assert {:ok, work} = link(ctx.user, "Work", "acct-secret-id")
      assert {:ok, _} = link(ctx.user, "Personal", "acct-personal")
      row = Repo.get!(Account, work.grant_id)

      assert {:error, %Ecto.Changeset{} = on_connect} = link(ctx.user, "Work", "acct-third")

      assert {:error, %Ecto.Changeset{} = on_rename} =
               ChatGPTAccounts.rename_for_user(work.grant_id, ctx.user.id, "Personal")

      # Untruncated on both sides, or a long blob would pass by being cut short.
      print = &inspect(&1, limit: :infinity, printable_limit: :infinity)

      secrets = [
        print.(row.access_token_ciphertext),
        print.(row.refresh_token_ciphertext),
        print.(on_connect.changes.access_token_ciphertext),
        print.(on_connect.changes.refresh_token_ciphertext),
        "admin@example.com",
        # A stored claim, as the map prints it.
        ~s("account_id" =>)
      ]

      for printed <- [print.(row), print.(on_connect), print.(on_rename)], secret <- secrets do
        refute printed =~ secret
      end

      # What an operator needs to tell rows apart is still there.
      assert inspect(row) =~ work.grant_id
      assert inspect(row) =~ "Work"
      assert_platform_untouched(ctx)
    end
  end

  defp grant_events(user) do
    Repo.all(from(e in Event, where: e.user_id == ^user.id and like(e.action, "chatgpt_grant.%")))
  end

  defp link(user, name, account_id, token_opts \\ [], opts \\ []),
    do: ChatGPTAccounts.connect_for_user(user.id, name, tokens(account_id, token_opts), opts)

  defp tokens(account_id, opts \\ []) do
    %{
      access_token: Keyword.get(opts, :access, access_token()),
      refresh_token: "rt_" <> account_id,
      id_token: id_token(%{account_id: account_id})
    }
  end

  defp bearer(label), do: jwt(%{"exp" => 4_102_444_800, "label" => label})

  defp credential(view, user),
    do: ChatGPTAccounts.credential_for_user(view.grant_id, user.id, view.generation)
end
