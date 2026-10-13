defmodule FountainWeb.Plugs.TenantAPIAuthTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Accounts
  alias FountainWeb.Plugs.TenantAPIAuth

  # Explicit, because `assert_receive`'s 100 ms default is a bet on how fast a
  # task gets scheduled on a loaded runner — and losing that bet fails a test
  # about a race with a race of its own. The `refute_receive` below keeps the
  # default: that one is a window we want short.
  @receive_timeout 5_000

  describe "call/2" do
    test "sets current_user when valid Bearer key is provided", %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> TenantAPIAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "returns 401 when no Authorization header", %{conn: conn} do
      conn = TenantAPIAuth.call(conn, [])

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "missing"
      assert body["reason"] == "api_key_invalid"
    end

    test "returns 401 for malformed Authorization header", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "NotBearer token")
        |> TenantAPIAuth.call([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["reason"] == "api_key_invalid"
    end

    test "returns 401 with api_key_invalid for unknown key", %{conn: conn} do
      conn =
        conn
        |> authed_with_key("ftn_" <> String.duplicate("0", 64))
        |> TenantAPIAuth.call([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["reason"] == "api_key_invalid"
    end

    test "returns 401 with api_key_revoked for revoked key", %{conn: conn} do
      user = insert_verified_user()
      {record, raw_key} = insert_api_key(user)
      {:ok, _} = Fountain.Accounts.revoke_api_key(user.id, record.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> TenantAPIAuth.call([])

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "revoked"
      assert body["reason"] == "api_key_revoked"
    end

    # Every minting path refuses an unverified account, so a key in this state
    # can only be a legacy one — minted before #314 closed
    # `POST /api/auth/token`. insert_api_key/1 goes straight to the context,
    # which is exactly how those keys came to exist.
    test "returns 403 with email_unverified for a key held by an unverified account", %{
      conn: conn
    } do
      user = insert_user()
      {_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> TenantAPIAuth.call([])

      assert conn.halted
      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["reason"] == "email_unverified"
    end

    test "the same key works once the account verifies", %{conn: conn} do
      user = insert_user()
      {_record, raw_key} = insert_api_key(user)
      {:ok, _verified} = Fountain.Accounts.verify_email(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> TenantAPIAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "cross-tenant key does not authenticate another user", %{conn: conn} do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      {_record, raw_key_a} = insert_api_key(user_a)

      conn =
        conn
        |> authed_with_key(raw_key_a)
        |> TenantAPIAuth.call([])

      refute conn.halted
      # user_a's key does not return user_b
      refute conn.assigns.current_user.id == user_b.id
    end
  end

  # #1040. The stamp is best-effort and nothing awaits it, so it must not be
  # able to fail the request it rode in on. It used to run in a `Task.async`,
  # which links to the caller: a pool blip under load raised in the task, the
  # exit signal followed the link back to the conn process, and under the SQL
  # Sandbox that process is the test — which is how a passing test failed on a
  # write it never asserted on.
  describe "the last_used_at stamp" do
    test "runs in a process other than the one serving the request", %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      test_pid = self()

      stub(Accounts, :touch_api_key, fn key ->
        send(test_pid, {:touched, key, self()})
        :ok
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> TenantAPIAuth.call([])

      assert_receive {:touched, ^raw_key, task_pid}, @receive_timeout
      refute task_pid == test_pid
      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "is skipped for a key stamped within the last minute (#2563)", %{conn: conn} do
      user = insert_verified_user()
      {record, raw_key} = insert_api_key(user)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      record |> Ecto.Changeset.change(last_used_at: now) |> Fountain.Repo.update!()

      test_pid = self()
      stub(Accounts, :touch_api_key, fn key -> send(test_pid, {:touched, key}) && :ok end)

      conn = conn |> authed_with_key(raw_key) |> TenantAPIAuth.call([])

      refute conn.halted
      refute_receive {:touched, _}, 200
    end

    test "a raise inside it kills neither the request nor the test that made it", %{conn: conn} do
      # Trapped so a link, if one came back, shows up as an assertable message
      # rather than as this test dying with an unrelated EXIT.
      Process.flag(:trap_exit, true)

      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      test_pid = self()

      stub(Accounts, :touch_api_key, fn _key ->
        send(test_pid, {:touching, self()})
        raise "connection not available and request was dropped from queue"
      end)

      log =
        capture_log(fn ->
          conn =
            conn
            |> authed_with_key(raw_key)
            |> TenantAPIAuth.call([])

          assert_receive {:touching, task_pid}, @receive_timeout

          # Sync on the task actually dying, so the assertions below are about
          # a crash that has already happened rather than one still in flight.
          ref = Process.monitor(task_pid)
          assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @receive_timeout

          refute_receive {:EXIT, ^task_pid, _reason}

          refute conn.halted
          assert conn.assigns.current_user.id == user.id
        end)

      # Supervised, so the crash is reported rather than propagated.
      assert log =~ "connection not available and request was dropped from queue"
    end
  end
end
