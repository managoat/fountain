defmodule Fountain.ChatGPTUserRefreshIsolationTest do
  # Independent, committed transactions prove the tenant fences and lock.
  use ExUnit.Case, async: false
  use Mimic

  import Ecto.Query
  import Ecto.Changeset
  import Fountain.ChatGPTFixtures

  alias Fountain.Accounts.{User, UserDataKey}
  alias Fountain.Audit.{AdminEvent, Event}
  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.{Cipher, Grant}
  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.Repo

  setup_all do
    %{repo: start_supervised!({Repo, name: nil, pool: DBConnection.ConnectionPool, pool_size: 4})}
  end

  setup %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    users = for _ <- 1..2, do: insert_owner()
    ids = Enum.map(users, & &1.id)
    platform_id = "user-refresh-platform-#{Ecto.UUID.generate()}"
    handler = "user-refresh-isolation-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler,
        [:fountain, :chatgpt, :refresh_lock, :contention],
        &__MODULE__.contending/4,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      Repo.put_dynamic_repo(repo)
      Repo.delete_all(from(e in Event, where: e.user_id in ^ids))

      Repo.delete_all(
        from(a in Account, where: a.user_id in ^ids or a.account_id == ^platform_id)
      )

      Repo.delete_all(from(u in User, where: u.id in ^ids))

      Repo.delete_all(
        from(e in AdminEvent, where: fragment("?->>'account_id'", e.metadata) == ^platform_id)
      )
    end)

    %{users: users, platform_id: platform_id}
  end

  @doc false
  def contending(_event, _measurements, _metadata, owner),
    do: send(owner, {:contending, self(), Repo.checked_out?()})

  test "two users and the platform renew independently while a same-grant contender waits", ctx do
    [first_user, second_user] = ctx.users
    first = user_grant!(first_user.id, %{refresh_token: "rt_first", account_id: "acct-first"})
    second = user_grant!(second_user.id, %{refresh_token: "rt_second", account_id: "acct-second"})

    platform =
      connect!(%{
        access_token: access_token(60),
        refresh_token: "rt_platform",
        account_id: ctx.platform_id
      })

    owner = self()

    stub_auth(%{
      "/oauth/token" => fn body ->
        token = body["refresh_token"]
        send(owner, {:upstream, self(), token})
        barrier()

        {200,
         %{
           "access_token" => access_token(7_200, %{"source" => token}),
           "refresh_token" => token <> "-rotated"
         }}
      end
    })

    holder = refresh(ctx.repo, first)

    try do
      assert_receive {:upstream, holder_pid, "rt_first"}, 2_000
      waiter = refresh(ctx.repo, first)
      second_holder = refresh(ctx.repo, second)

      platform_holder =
        independent(ctx.repo, fn -> PlatformChatGPT.refresh_serialized(:if_stale) end)

      try do
        assert_receive {:contending, waiter_pid, false}, 2_000
        assert waiter_pid == waiter.pid
        assert_receive {:upstream, second_pid, "rt_second"}, 2_000
        assert_receive {:upstream, platform_pid, "rt_platform"}, 2_000
        send(second_pid, :release)
        send(platform_pid, :release)
        assert :ok = Task.await(second_holder)
        assert {:ok, _platform_access} = Task.await(platform_holder)
        assert Task.yield(holder, 0) == nil
        send(holder_pid, :release)
        assert :ok = Task.await(holder)
        assert :ok = Task.await(waiter)
        refute_received {:upstream, _, _}

        for {original, refresh} <- [{first, "rt_first"}, {second, "rt_second"}] do
          current = Repo.get!(Account, original.id)
          assert current.lock_version == original.lock_version + 1
          assert current.generation == original.generation
          assert {:ok, rotated} = Cipher.decrypt_token(current, :refresh_token)
          assert rotated == refresh <> "-rotated"

          assert {:ok, %Grant{} = grant} =
                   ChatGPTAccounts.credential_for_user(
                     current.id,
                     current.user_id,
                     current.generation,
                     refresh: false
                   )

          assert grant.source.account_id == original.account_id
          assert grant.source.owner_scope == {:user, original.user_id}
          assert grant.source.lock_version == current.lock_version
          assert {:ok, access} = Cipher.decrypt_token(current, :access_token)
          assert grant.access_token == access
        end

        assert Repo.get!(Account, platform.id).lock_version == platform.lock_version + 1
      after
        for task <- [waiter, second_holder, platform_holder],
            do: Task.shutdown(task, :brutal_kill)
      end
    after
      Task.shutdown(holder, :brutal_kill)
    end
  end

  for mutation <- [:disconnect, :reconnect, :suspend], response <- [:success, :terminal] do
    test "#{mutation} commits while an independent user #{response} response is pending", ctx do
      user = hd(ctx.users)
      account = user_grant!(user.id)
      owner = self()

      stub_auth(%{
        "/oauth/token" => fn _ ->
          send(owner, :refreshing)
          barrier()

          case unquote(response) do
            :success ->
              {200, %{"access_token" => access_token(7_200), "refresh_token" => "rt_late"}}

            :terminal ->
              {400, %{"error" => "invalid_grant"}}
          end
        end
      })

      holder = refresh(ctx.repo, account)

      try do
        assert_receive :refreshing, 2_000
        mutate(unquote(mutation), user, account)
        send(holder.pid, :release)
        expected = if unquote(mutation) == :reconnect, do: :stale_grant, else: :not_connected
        assert {:error, ^expected} = Task.await(holder)

        case Repo.get(Account, account.id) do
          nil ->
            :ok

          current ->
            assert current.status == "active"
            assert current.refresh_token_ciphertext == account.refresh_token_ciphertext
        end

        refute Repo.exists?(
                 from(e in Event,
                   where: e.action == "chatgpt.reconnect_required" and e.user_id == ^user.id
                 )
               )
      after
        Task.shutdown(holder, :brutal_kill)
      end
    end
  end

  test "tenant revocation commits before its best-effort audit", ctx do
    account = user_grant!(hd(ctx.users).id)
    stub_refusal()

    expect(Fountain.Audit, :record, fn attrs ->
      refute Repo.in_transaction?()
      assert attrs.user_id == account.user_id

      committed =
        ctx.repo |> independent(fn -> Repo.get!(Account, account.id) end) |> Task.await()

      assert committed.status == "revoked"
      assert committed.lock_version == account.lock_version + 1
      {:error, :unavailable}
    end)

    assert {:error, :revoked} =
             ChatGPTAccounts.refresh_serialized_for_user(
               account.id,
               account.user_id,
               account.generation
             )

    assert Repo.get!(Account, account.id).status == "revoked"
  end

  defp mutate(:disconnect, _user, account), do: Repo.delete!(account)

  defp mutate(:reconnect, _user, account),
    do: account |> Account.connect_changeset(%{}) |> Repo.update!()

  defp mutate(:suspend, user, _account),
    do:
      user
      |> change(suspended_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

  defp insert_owner do
    user =
      Repo.insert!(%User{
        email: "refresh-#{Ecto.UUID.generate()}@example.test",
        email_verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Repo.insert!(%UserDataKey{
      user_id: user.id,
      wrapped_key: Crypto.wrap_dek(Crypto.generate_dek())
    })

    user
  end

  defp refresh(repo, account),
    do:
      independent(repo, fn ->
        ChatGPTAccounts.refresh_serialized_for_user(
          account.id,
          account.user_id,
          account.generation
        )
      end)

  defp independent(repo, fun) do
    Task.async(fn ->
      Repo.put_dynamic_repo(repo)
      fun.()
    end)
  end

  defp barrier do
    receive do
      :release -> :ok
    after
      5_000 -> raise "user refresh barrier timed out"
    end
  end
end
