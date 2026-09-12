defmodule Fountain.ChatGPTUserRefreshTest do
  # The application coordinator and Req provider stub are shared processes.
  use Fountain.DataCase, async: false
  use Mimic

  import Fountain.ChatGPTFixtures
  import ExUnit.CaptureLog

  alias Fountain.Audit.{AdminEvent, Event}
  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.{Cipher, Grant, RefreshCoordinator}
  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT.Account

  test "a stale credential renews with its owner's DEK and returns the committed source" do
    user = insert_verified_user()
    account = user_grant!(user.id)
    access = access_token(7_200, %{"renewed" => true})

    stub_refresh(%{
      expect_refresh: "rt_user",
      access_token: access,
      id_token: id_token(%{account_id: account.account_id})
    })

    assert {:ok, %Grant{} = grant} = credential(account)
    assert grant.access_token == access
    assert grant.source.owner_scope == {:user, user.id}
    assert grant.source.generation == account.generation
    assert grant.source.lock_version == account.lock_version + 1
    current = Repo.get!(Account, account.id)
    assert {:ok, "rt_rotated"} = Cipher.decrypt_token(current, :refresh_token)
    assert :error = Crypto.decrypt_platform(current.refresh_token_ciphertext)
    refute inspect(grant) =~ access
    refute inspect(:sys.get_state(RefreshCoordinator)) =~ access
  end

  test "omitted rotation preserves the encrypted refresh token" do
    account = user_grant!(insert_verified_user().id)
    access = access_token(7_200)
    stub_auth(%{"/oauth/token" => fn _ -> {200, %{"access_token" => access}} end})
    assert {:ok, %Grant{access_token: ^access}} = credential(account)

    assert Repo.get!(Account, account.id).refresh_token_ciphertext ==
             account.refresh_token_ciphertext
  end

  test "simultaneous callers share one exchange and re-read their own credential" do
    account = user_grant!(insert_verified_user().id)
    owner = self()
    access = access_token(7_200)

    stub_auth(%{
      "/oauth/token" => fn _ ->
        send(owner, {:upstream, self()})
        receive do: (:release -> :ok)
        {200, %{"access_token" => access, "refresh_token" => "rt_rotated"}}
      end
    })

    callers = for _ <- 1..6, do: Task.async(fn -> credential(account) end)
    assert_receive {:upstream, worker}, 2_000
    await_waiters(6)
    refute_received {:upstream, _}
    send(worker, :release)

    for caller <- callers do
      assert {:ok, %Grant{access_token: ^access, source: source}} = Task.await(caller)
      assert source.grant_id == account.id
      assert source.lock_version == account.lock_version + 1
    end

    refute_received {:upstream, _}
  end

  test "another owner, the platform row and a stale generation cannot initiate refresh" do
    user = insert_verified_user()
    other = insert_verified_user()
    account = user_grant!(user.id)
    platform = connect!(%{access_token: access_token(60)})
    stub_auth(%{})

    assert {:error, :not_connected} =
             ChatGPTAccounts.refresh_for_user(account.id, other.id, account.generation)

    assert {:error, :not_connected} =
             ChatGPTAccounts.refresh_for_user(platform.id, user.id, platform.generation)

    assert {:error, :stale_grant} =
             ChatGPTAccounts.refresh_for_user(account.id, user.id, Ecto.UUID.generate())

    assert_raise FunctionClauseError, fn ->
      ChatGPTAccounts.refresh_for_user(account.id, nil, account.generation)
    end

    assert Repo.get!(Account, account.id).lock_version == account.lock_version
  end

  for attrs <- [
        %{principal: true},
        %{email_verified_at: nil},
        %{suspended_at: ~U[2026-09-01 00:00:00Z]}
      ] do
    test "ineligible owner #{inspect(attrs)} cannot read or refresh a grant" do
      user = insert_verified_user()
      account = user_grant!(user.id, %{access_token: access_token(7_200)})
      user |> change(unquote(Macro.escape(attrs))) |> Repo.update!()
      stub_auth(%{})
      assert {:error, :not_connected} = credential(account)

      assert {:error, :not_connected} =
               ChatGPTAccounts.refresh_for_user(account.id, user.id, account.generation)
    end
  end

  test "transient provider errors retain the grant without echoing response secrets" do
    account = user_grant!(insert_verified_user().id)
    secret = "synthetic-provider-echo"

    stub_auth(%{
      "/oauth/token" => fn _ ->
        {503, %{"error" => "unavailable", "error_description" => secret}}
      end
    })

    log = capture_log(fn -> assert {:error, :refresh_failed} = credential(account) end)
    refute log =~ secret
    assert Repo.get!(Account, account.id) == account
    refute Repo.exists?(from(e in Event, where: e.action == "chatgpt.reconnect_required"))
  end

  test "terminal refusal writes only a tenant reconnect-required event" do
    account = user_grant!(insert_verified_user().id)
    stub_refusal("invalid_grant")
    assert {:error, :revoked} = credential(account)
    current = Repo.get!(Account, account.id)
    assert current.status == "revoked"
    assert current.generation == account.generation
    assert current.lock_version == account.lock_version + 1
    event = Repo.one!(from(e in Event, where: e.action == "chatgpt.reconnect_required"))
    assert event.user_id == account.user_id
    assert event.actor == "system:chatgpt_accounts"
    assert event.resource_id == account.id
    assert event.metadata == %{"reason" => "invalid_grant", "generation" => account.generation}

    refute Repo.exists?(
             from(e in AdminEvent, where: e.event_type == "admin.platform_chatgpt.revoked")
           )

    assert {:error, :revoked} = credential(account)

    assert Repo.aggregate(
             from(e in Event, where: e.action == "chatgpt.reconnect_required"),
             :count
           ) == 1
  end

  for response <- [:success, :terminal] do
    test "reconnect fences a late user #{response} response" do
      account = user_grant!(insert_verified_user().id)

      stub_auth(%{
        "/oauth/token" => fn _ ->
          account |> Account.connect_changeset(%{}) |> Repo.update!()

          case unquote(response) do
            :success ->
              {200, %{"access_token" => access_token(7_200), "refresh_token" => "rt_late"}}

            :terminal ->
              {400, %{"error" => "invalid_grant"}}
          end
        end
      })

      assert {:error, :stale_grant} = credential(account)
      current = Repo.get!(Account, account.id)
      assert current.status == "active"
      assert current.lock_version == account.lock_version + 1
      assert current.refresh_token_ciphertext == account.refresh_token_ciphertext
      refute Repo.exists?(from(e in Event, where: e.action == "chatgpt.reconnect_required"))
    end
  end

  test "refresh cannot change the pinned provider account or provider user" do
    account = user_grant!(insert_verified_user().id)

    for claims <- [
          %{account_id: "another-account"},
          %{account_id: account.account_id, user_id: "another-user"}
        ] do
      stub_refresh(%{expect_refresh: "rt_user", id_token: id_token(claims)})
      assert {:error, :account_mismatch} = credential(account)
      assert Repo.get!(Account, account.id) == account
    end
  end

  test "wrong key refuses renewal before contacting the provider" do
    account = user_grant!(insert_verified_user().id)
    stub_auth(%{})
    key = Repo.get_by!(Fountain.Accounts.UserDataKey, user_id: account.user_id)
    key |> change(wrapped_key: Crypto.wrap_dek(Crypto.generate_dek())) |> Repo.update!()
    assert {:error, :undecryptable} = credential(account)
    assert Repo.get!(Account, account.id) == account
  end

  test "renewal skips a recent grant but renews an idle grant with a still-fresh bearer" do
    account = user_grant!(insert_verified_user().id, %{access_token: access_token(7_200)})
    stub_auth(%{})
    assert :ok = ChatGPTAccounts.refresh_for_user(account.id, account.user_id, account.generation)
    account |> change(last_refreshed_at: ~U[2020-01-01 00:00:00Z]) |> Repo.update!()

    stub_refresh(%{
      expect_refresh: "rt_user",
      id_token: id_token(%{account_id: account.account_id})
    })

    assert :ok = ChatGPTAccounts.refresh_for_user(account.id, account.user_id, account.generation)
    assert Repo.get!(Account, account.id).lock_version == account.lock_version + 1
  end

  defp credential(account),
    do: ChatGPTAccounts.credential_for_user(account.id, account.user_id, account.generation)

  defp await_waiters(count, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    if map_size(:sys.get_state(RefreshCoordinator).callers) != count do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_waiters(count, deadline)
    end
  end
end
