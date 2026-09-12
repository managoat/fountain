defmodule Fountain.ChatGPTRefreshCoordinationTest do
  # Committed rows, a real two-connection pool and a shared provider stub.
  # SQL sandbox sharing cannot establish cross-node exclusion.
  use ExUnit.Case, async: false
  use Mimic

  import Ecto.Query
  import Fountain.ChatGPTFixtures

  alias Fountain.Audit.AdminEvent
  alias Fountain.ChatGPTAccounts.RefreshLock
  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.Repo

  @contention [:fountain, :chatgpt, :refresh_lock, :contention]

  setup_all do
    repo =
      start_supervised!({Repo, name: nil, pool: DBConnection.ConnectionPool, pool_size: 2})

    %{repo: repo}
  end

  setup %{repo: repo} do
    previous_repo = Repo.put_dynamic_repo(repo)
    account_id = "refresh-coordination-#{Ecto.UUID.generate()}"
    owner = self()
    handler_id = "refresh-lock-test-#{account_id}"

    :ok = :telemetry.attach(handler_id, @contention, &__MODULE__.on_contention/4, owner)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      # The module's pool outlives each test's cleanup.
      Repo.put_dynamic_repo(repo)
      Repo.delete_all(from(a in Account, where: a.account_id == ^account_id))

      Repo.delete_all(
        from(e in AdminEvent, where: fragment("?->>'account_id'", e.metadata) == ^account_id)
      )

      Repo.put_dynamic_repo(previous_repo)
    end)

    %{repo: repo, account_id: account_id}
  end

  @doc false
  def on_contention(_event, _measurements, _metadata, owner) do
    send(owner, {:contending, self(), Repo.checked_out?()})
  end

  for mode <- [:if_stale, :force] do
    test "independent #{mode} refreshers exchange once and serve the committed winner", ctx do
      account = connect!(%{access_token: access_token(60), account_id: ctx.account_id})
      winner = access_token(7_200, %{"winner" => true})
      owner = self()

      stub_auth(%{
        "/oauth/token" => fn body ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(owner, {:upstream, self(), backend, body["refresh_token"]})
          await_release()
          {200, %{"access_token" => winner, "refresh_token" => "rt_winner"}}
        end
      })

      holder = independent(ctx.repo, fn -> PlatformChatGPT.refresh_serialized(unquote(mode)) end)

      try do
        assert_receive {:upstream, holder_pid, holder_backend, "rt_original"}, 2_000
        assert holder_pid == holder.pid

        waiter =
          independent(ctx.repo, fn -> PlatformChatGPT.refresh_serialized(unquote(mode)) end)

        try do
          assert_receive {:contending, waiter_pid, false}, 2_000
          assert waiter_pid == waiter.pid
          %{rows: [[free_backend]]} = Repo.query!("SELECT pg_backend_pid()")
          refute free_backend == holder_backend
          # The holder has no row lock and has not committed new tokens yet.
          assert Repo.get!(Account, account.id).lock_version == account.lock_version
          send(holder.pid, :release)
          assert {:ok, ^winner} = Task.await(holder)
          assert {:ok, ^winner} = Task.await(waiter)
          refute_received {:upstream, _, _, _}
          current = Repo.get!(Account, account.id)
          assert current.lock_version == account.lock_version + 1
          assert current.generation == account.generation
          assert {:ok, "rt_winner"} = Crypto.decrypt_platform(current.refresh_token_ciphertext)
        after
          Task.shutdown(waiter, :brutal_kill)
        end
      after
        Task.shutdown(holder, :brutal_kill)
      end
    end
  end

  for mutation <- [:disconnect, :reconnect], response <- [:success, :terminal] do
    test "#{mutation} commits during an independent refresh's #{response} response", ctx do
      original = connect!(%{access_token: access_token(60), account_id: ctx.account_id})
      owner = self()

      stub_auth(%{
        "/oauth/token" => fn _ ->
          send(owner, :refreshing)
          await_release()

          case unquote(response) do
            :success -> {200, %{"access_token" => access_token(), "refresh_token" => "rt_late"}}
            :terminal -> {400, %{"error" => "invalid_grant"}}
          end
        end
      })

      holder = independent(ctx.repo, fn -> PlatformChatGPT.refresh_serialized(:if_stale) end)

      try do
        assert_receive :refreshing, 2_000

        case unquote(mutation) do
          :disconnect ->
            assert :ok = PlatformChatGPT.disconnect()

          :reconnect ->
            replacement = connect!(%{account_id: ctx.account_id})
            refute replacement.generation == original.generation
        end

        send(holder.pid, :release)

        case unquote(mutation) do
          :disconnect ->
            assert {:error, :not_connected} = Task.await(holder)
            refute Repo.get(Account, original.id)

          :reconnect ->
            assert {:error, :stale_grant} = Task.await(holder)
            current = Repo.get!(Account, original.id)
            assert current.status == "active"

            assert {:ok, "rt_original"} =
                     Crypto.decrypt_platform(current.refresh_token_ciphertext)
        end

        refute Repo.exists?(
                 from(e in AdminEvent,
                   where:
                     e.event_type == "admin.platform_chatgpt.revoked" and
                       fragment("?->>'account_id'", e.metadata) == ^ctx.account_id
                 )
               )
      after
        Task.shutdown(holder, :brutal_kill)
      end
    end
  end

  test "many contenders release pool capacity and stop at their wait deadline", ctx do
    grant_id = Ecto.UUID.generate()
    holder = hold_lock(ctx.repo, grant_id)

    waiters =
      for _ <- 1..6 do
        independent(ctx.repo, fn ->
          RefreshLock.run(grant_id, fn -> flunk("contender acquired held lock") end,
            wait_timeout: 250
          )
        end)
      end

    try do
      for waiter <- waiters do
        pid = waiter.pid
        assert_receive {:contending, ^pid, false}, 2_000
      end

      # One of just two connections remains usable despite six waiters.
      # The timeout only has to be long enough to distinguish "a connection
      # is free" from "both are pinned"; a loaded runner should not have to
      # answer in a second to prove that.
      assert %{rows: [[1]]} = Repo.query!("SELECT 1", [], timeout: 5_000)

      assert {:ok, :other_grant} =
               RefreshLock.run(Ecto.UUID.generate(), fn -> {:ok, :other_grant} end)

      for waiter <- waiters, do: assert({:error, :refresh_busy} = Task.await(waiter))
      assert Task.yield(holder, 0) == nil
    after
      for waiter <- waiters, do: Task.shutdown(waiter, :brutal_kill)
      send(holder.pid, :release)
      Task.shutdown(holder, 1_000)
    end
  end

  test "revocation is committed before its best-effort audit", ctx do
    account = connect!(%{access_token: access_token(60), account_id: ctx.account_id})
    stub_refusal()

    expect(Fountain.Audit, :record_admin, fn attrs ->
      refute Repo.in_transaction?()
      assert attrs.event_type == "admin.platform_chatgpt.revoked"

      committed =
        ctx.repo
        |> independent(fn -> Repo.get!(Account, account.id) end)
        |> Task.await()

      assert committed.status == "revoked"
      assert committed.lock_version == account.lock_version + 1
      # Audit loss cannot roll back the already committed revocation.
      {:error, :unavailable}
    end)

    assert {:error, :revoked} = PlatformChatGPT.refresh_serialized(:if_stale)
    assert Repo.get!(Account, account.id).status == "revoked"
  end

  test "worker death releases the transaction lock for another connection", ctx do
    grant_id = Ecto.UUID.generate()
    holder = hold_lock(ctx.repo, grant_id)
    Task.shutdown(holder, :brutal_kill)
    assert {:ok, :recovered} = RefreshLock.run(grant_id, fn -> {:ok, :recovered} end)
  end

  # The holder keeps a database checkout for the whole provider exchange, so
  # the exchange has to be unable to outlast the transaction. Measured once
  # at 12/12: a provider that dripped for 11s and then went silent took 22.8s
  # and the pool force-disconnected the connection underneath it -- and the
  # dangerous case is not that one but the next, where the rotation lands at
  # ~21s, the connection is already gone, and the refresh token has moved
  # upstream with nothing able to commit it locally.
  #
  # The numbers live in two modules and the ceiling is a sum rather than a
  # maximum, which is how the first version got it wrong. Neither fact is
  # visible from either file alone, so assert the relationship here.
  test "the provider exchange cannot outlast the transaction that holds the connection" do
    assert Fountain.PlatformChatGPT.OAuth.refresh_timeout_ceiling_ms() <
             RefreshLock.transaction_timeout_ms()
  end

  # The moduledoc's strongest claim is that no session lock can leak into the
  # pool, and until this test nothing observed it: swapping
  # `pg_try_advisory_xact_lock` for `pg_try_advisory_lock` left all twelve
  # tests green. "worker death" passes either way because DBConnection drops
  # the whole connection when the client dies, and "rollback" passes because
  # advisory locks are re-entrant within one session. Both prove the lock is
  # released, neither proves it was scoped to the transaction. This asks the
  # connection itself, after the transaction has ended and it is back in the
  # pool for the next checkout to inherit.
  test "the lock is scoped to the transaction, not left on the pooled connection" do
    grant_id = Ecto.UUID.generate()

    # `Repo.checkout/1` pins one connection for the whole body, so the lock
    # and the `pg_backend_pid()` that looks for it are the same backend. Two
    # connections in this pool and a free choice of either made the check
    # miss a real session lock roughly half the time. This is a checkout and
    # not a transaction, so `run/3`'s "never inside a transaction" contract
    # still holds -- the xact lock has an enclosing transaction of its own.
    Repo.checkout(fn ->
      assert {:ok, :done} = RefreshLock.run(grant_id, fn -> {:ok, :done} end)
      assert advisory_locks_held() == 0

      # A rollback and a raise unwind by different routes; neither may strand
      # a lock on the connection they borrowed.
      assert {:error, :refresh_unavailable} =
               RefreshLock.run(grant_id, fn -> Repo.rollback(:failed) end)

      assert advisory_locks_held() == 0

      assert catch_throw(RefreshLock.run(grant_id, fn -> throw(:boom) end)) == :boom
      assert advisory_locks_held() == 0
    end)
  end

  test "rollback releases the lock without returning the callback's success" do
    grant_id = Ecto.UUID.generate()

    assert {:error, :refresh_unavailable} =
             RefreshLock.run(grant_id, fn -> Repo.rollback(:failed) end)

    assert {:ok, :recovered} = RefreshLock.run(grant_id, fn -> {:ok, :recovered} end)
  end

  @tag capture_log: true
  test "transaction deadline cannot return a token from an uncommitted refresh" do
    grant_id = Ecto.UUID.generate()

    assert {:error, :refresh_unavailable} =
             RefreshLock.run(
               grant_id,
               fn ->
                 Process.sleep(150)
                 {:ok, "uncommitted"}
               end,
               transaction_timeout: 50
             )

    assert {:ok, :recovered} = RefreshLock.run(grant_id, fn -> {:ok, :recovered} end)
  end

  test "a provider dripping response chunks cannot keep the refresh transaction open", ctx do
    original = connect!(%{access_token: access_token(60), account_id: ctx.account_id})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    old_url = Application.fetch_env(:fountain, :platform_chatgpt_auth_url)
    old_options = Application.fetch_env(:fountain, :platform_chatgpt_req_options)
    Application.put_env(:fountain, :platform_chatgpt_auth_url, "http://127.0.0.1:#{port}")
    Application.put_env(:fountain, :platform_chatgpt_req_options, [])

    on_exit(fn ->
      restore_env(:platform_chatgpt_auth_url, old_url)
      restore_env(:platform_chatgpt_req_options, old_options)
    end)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n"
          )

        drip(socket)
      end)

    try do
      started = System.monotonic_time(:millisecond)
      assert {:error, {:token, _timeout}} = PlatformChatGPT.refresh_serialized(:if_stale)
      elapsed = System.monotonic_time(:millisecond) - started
      # Chunks arrive every 250ms, so `:receive_timeout` never fires and
      # `:request_timeout` is what ends this. Bound it by the thing that
      # actually matters rather than by a copy of the constant: the whole
      # exchange has to finish inside the transaction holding the
      # connection. The lower bound only says it waited on the provider
      # instead of failing fast.
      assert elapsed >= 1_000
      assert elapsed < Fountain.PlatformChatGPT.OAuth.refresh_timeout_ceiling_ms()
      assert elapsed < RefreshLock.transaction_timeout_ms()
      current = Repo.get!(Account, original.id)
      assert current.lock_version == original.lock_version
      assert current.status == "active"
      assert {:ok, :released} = RefreshLock.run(original.id, fn -> {:ok, :released} end)
    after
      Task.shutdown(server, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  defp drip(socket) do
    case :gen_tcp.send(socket, "1\r\n \r\n") do
      :ok ->
        Process.sleep(250)
        drip(socket)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:fountain, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:fountain, key)

  defp independent(repo, fun) do
    Task.async(fn ->
      Repo.put_dynamic_repo(repo)
      fun.()
    end)
  end

  # Counts only locks held by the backend answering this query, which is why
  # the caller pins the connection first: on a free choice between two, the
  # query can land on the one that never ran the lock and see zero.
  defp advisory_locks_held do
    %{rows: [[held]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
      )

    held
  end

  defp hold_lock(repo, grant_id) do
    owner = self()

    holder =
      independent(repo, fn ->
        RefreshLock.run(grant_id, fn ->
          send(owner, :holding)
          await_release()
        end)
      end)

    assert_receive :holding, 2_000
    holder
  end

  defp await_release do
    receive do
      :release -> :ok
    after
      5_000 -> raise "refresh barrier timed out"
    end
  end
end
