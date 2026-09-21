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

  test "one of a user's two grants renews and the other is untouched" do
    user = insert_verified_user()
    renewed = user_grant!(user.id, %{refresh_token: "rt_personal"})
    idle = user_grant!(user.id, %{refresh_token: "rt_work"})
    platform = connect!()
    access = access_token(7_200, %{"renewed" => true})

    stub_refresh(%{
      expect_refresh: "rt_personal",
      access_token: access,
      id_token: id_token(%{account_id: renewed.account_id})
    })

    assert {:ok, %Grant{access_token: ^access, source: source}} = credential(renewed)
    assert source.grant_id == renewed.id
    assert source.account_id == renewed.account_id
    assert source.lock_version == renewed.lock_version + 1
    assert Repo.get!(Account, idle.id) == idle
    assert Repo.get!(Account, platform.id) == platform

    # The other grant is its own refresh chain, under the same owner's key.
    stub_refresh(%{
      expect_refresh: "rt_work",
      refresh_token: "rt_work_rotated",
      id_token: id_token(%{account_id: idle.account_id})
    })

    assert {:ok, %Grant{source: %{grant_id: idle_id}}} = credential(idle)
    assert idle_id == idle.id

    assert {:ok, "rt_rotated"} =
             Cipher.decrypt_token(Repo.get!(Account, renewed.id), :refresh_token)

    assert {:ok, "rt_work_rotated"} =
             Cipher.decrypt_token(Repo.get!(Account, idle.id), :refresh_token)

    assert Repo.get!(Account, platform.id) == platform
  end

  test "a refresh that answers as the user's other subscription is refused" do
    user = insert_verified_user()
    personal = user_grant!(user.id)
    work = user_grant!(user.id)
    stub_refresh(%{expect_refresh: "rt_user", id_token: id_token(%{account_id: work.account_id})})

    assert {:error, :account_mismatch} = credential(personal)
    assert Repo.get!(Account, personal.id) == personal
    assert Repo.get!(Account, work.id) == work
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

  # The coordinator's job and the refresh lock are keyed by the grant id. A
  # second spelling of one id must not become a second exchange: that would
  # rotate the refresh token twice and keep only one of the results.
  test "another spelling of the same ids joins the same exchange" do
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

    spellings = [
      {account.id, account.user_id},
      {String.upcase(account.id), String.upcase(account.user_id)}
    ]

    callers =
      for {grant_id, user_id} <- spellings do
        Task.async(fn ->
          ChatGPTAccounts.credential_for_user(grant_id, user_id, account.generation)
        end)
      end

    assert_receive {:upstream, worker}, 2_000
    await_waiters(2)
    assert map_size(:sys.get_state(RefreshCoordinator).jobs) == 1
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
    refute Repo.exists?(from(e in Event, where: e.action == "chatgpt_grant.reconnect_required"))
  end

  test "terminal refusal writes only a tenant reconnect-required event" do
    account = user_grant!(insert_verified_user().id)
    stub_refusal("invalid_grant")
    assert {:error, :revoked} = credential(account)
    current = Repo.get!(Account, account.id)
    assert current.status == "revoked"
    assert current.generation == account.generation
    assert current.lock_version == account.lock_version + 1
    event = Repo.one!(from(e in Event, where: e.action == "chatgpt_grant.reconnect_required"))
    assert event.user_id == account.user_id
    assert event.actor == "system:chatgpt_accounts"
    assert event.resource_id == account.id

    assert event.metadata == %{
             "name" => account.name,
             "reason" => "invalid_grant",
             "generation" => account.generation
           }

    refute Repo.exists?(
             from(e in AdminEvent, where: e.event_type == "admin.platform_chatgpt.revoked")
           )

    assert {:error, :revoked} = credential(account)

    assert Repo.aggregate(
             from(e in Event, where: e.action == "chatgpt_grant.reconnect_required"),
             :count
           ) == 1
  end

  # ADR 0060 decision 5. The trigger's half is held down in
  # `chatgpt_grant_source_lock_test.exs`; this is the Elixir half, where the
  # platform branch of `with_grant_source_lock/2` sits one clause away.
  test "a user refresh and a terminal refusal take the owner's source key, never the platform's" do
    user = insert_verified_user()
    renewed = user_grant!(user.id)
    refused = user_grant!(user.id)
    test = self()
    handler = "user-refresh-source-lock-#{System.unique_integer([:positive])}"

    # The write runs in a coordinator worker, so the handler reports to the test.
    :telemetry.attach(
      handler,
      [:fountain, :repo, :query],
      fn _event, _measurements, %{query: query} = metadata, _config ->
        # A lock's key is the only parameter worth keeping; a write's are ciphertexts.
        params = if query =~ "pg_advisory", do: metadata.params, else: []
        send(test, {:statement, query, params})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    stub_refresh(%{
      expect_refresh: "rt_user",
      id_token: id_token(%{account_id: renewed.account_id})
    })

    assert {:ok, %Grant{}} = credential(renewed)
    assert Repo.get!(Account, renewed.id).lock_version == renewed.lock_version + 1

    stub_refusal("invalid_grant")
    assert {:error, :revoked} = credential(refused)
    assert Repo.get!(Account, refused.id).status == "revoked"

    :telemetry.detach(handler)
    statements = drain_statements()

    refute Enum.any?(statements, fn {query, _} -> query =~ "inference:platform" end)

    tenant_locks =
      Enum.filter(statements, fn {query, params} ->
        query =~ "pg_advisory_xact_lock(" and params == ["inference:" <> user.id]
      end)

    # One for the fenced token write, one for the fenced revocation.
    assert length(tenant_locks) == 2
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
      refute Repo.exists?(from(e in Event, where: e.action == "chatgpt_grant.reconnect_required"))
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

  defp drain_statements(acc \\ []) do
    receive do
      {:statement, query, params} -> drain_statements([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp await_waiters(count, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    if map_size(:sys.get_state(RefreshCoordinator).callers) != count do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_waiters(count, deadline)
    end
  end
end
