defmodule FountainWeb.AdminControllerTest do
  @moduledoc """
  The operator surface over the API (#527).

  Every admin operation was AdminLive-only, so nothing could be scripted — no
  bulk trial extension, no suspension from an incident runbook. These tests pin
  the three gates (auth, full scope, admin role), the refusals the UI has, and
  the privilege-trail events, which are what make a scripted action as visible
  as a clicked one.
  """

  # async: false — the "billing actions when billing is disabled" block below
  # flips `:credits_enabled`, which is application env and therefore global to
  # the VM, not to this test. Run async, it made every concurrent test that
  # reads `Credits.enabled?/0` see `false` for the duration, which is how
  # AdminUserDetailLiveTest's billing section intermittently vanished
  # (#576). Every other module that mutates this env is already async: false.
  use FountainWeb.ConnCase, async: false
  use Mimic

  alias Fountain.Accounts
  alias Fountain.Audit.AdminEvent
  alias Fountain.Repo

  setup do
    admin = insert_verified_user()
    {:ok, admin} = Accounts.update_user_role(admin, "admin")
    {_rec, key} = insert_api_key(admin)
    target = insert_verified_user()
    {:ok, admin: admin, key: key, target: target}
  end

  defp admin_events, do: Repo.all(AdminEvent)

  defp event_types, do: admin_events() |> Enum.map(& &1.event_type)

  describe "the gate" do
    test "a non-admin key is refused everywhere", %{target: target} do
      {_rec, plain_key} = insert_api_key(target)

      for path <- [
            "/api/admin/users",
            "/api/admin/sandboxes",
            "/api/admin/audit",
            "/api/admin/events"
          ] do
        body =
          build_conn()
          |> authed_with_key(plain_key)
          |> get(path)
          |> json_response(403)

        assert body["error"] == "admin_required"
      end
    end

    test "a non-admin cannot act on another account", %{conn: conn, admin: admin, target: target} do
      {_rec, plain_key} = insert_api_key(target)

      conn
      |> authed_with_key(plain_key)
      |> post_json("/api/admin/users/#{admin.id}/role", %{"role" => "user"})
      |> json_response(403)

      assert Accounts.get_user(admin.id).role == "admin"
    end

    test "an admin's sprite-scoped token is refused — role is not enough", %{
      conn: conn,
      admin: admin,
      target: target
    } do
      # Operator powers need a human-held credential, not the token a sandbox
      # is holding on the admin's behalf.
      {_rec, sprite_key} = insert_sprite_api_key(admin)

      body =
        conn
        |> authed_with_key(sprite_key)
        |> post_json("/api/admin/users/#{target.id}/suspend", %{"suspended" => true})
        |> json_response(403)

      assert body["reason"] == "insufficient_scope"
      refute Accounts.suspended?(Accounts.get_user(target.id))
    end

    test "unauthenticated is 401", %{conn: conn} do
      conn
      |> put_req_header("accept", "application/json")
      |> get("/api/admin/users")
      |> json_response(401)
    end
  end

  describe "GET /api/admin/users" do
    test "lists accounts with operator metadata and pagination", %{conn: conn, key: key} do
      body = conn |> authed_with_key(key) |> get("/api/admin/users") |> json_response(200)

      assert body["meta"]["total"] >= 2
      assert body["meta"]["page"] == 1

      row = hd(body["data"])
      assert row["email"]
      assert row["role"]
      assert Map.has_key?(row, "active_sandboxes")
      assert Map.has_key?(row, "suspended")
      assert Map.has_key?(row, "max_concurrent_sandboxes")
    end

    test "filters by email, role and verification", %{conn: conn, key: key, target: target} do
      by_email =
        conn
        |> authed_with_key(key)
        |> get("/api/admin/users?q=#{target.email}")
        |> json_response(200)

      assert Enum.map(by_email["data"], & &1["email"]) == [target.email]

      admins =
        build_conn()
        |> authed_with_key(key)
        |> get("/api/admin/users?role=admin")
        |> json_response(200)

      assert Enum.all?(admins["data"], &(&1["role"] == "admin"))

      unverified_user = insert_user()

      unverified =
        build_conn()
        |> authed_with_key(key)
        |> get("/api/admin/users?verified=false")
        |> json_response(200)

      assert unverified_user.id in Enum.map(unverified["data"], & &1["id"])

      # The status vocabulary retired with the subscription (ADR 0031); comped
      # is the one billing distinction left, and `?status=` is rejected rather
      # than silently ignored.
      {:ok, comped_user} = Fountain.Billing.comp_account(insert_verified_user())

      comped =
        build_conn()
        |> authed_with_key(key)
        |> get("/api/admin/users?comped=true")
        |> json_response(200)

      assert Enum.map(comped["data"], & &1["id"]) == [comped_user.id]

      billed =
        build_conn()
        |> authed_with_key(key)
        |> get("/api/admin/users?comped=false")
        |> json_response(200)

      refute comped_user.id in Enum.map(billed["data"], & &1["id"])
      assert target.id in Enum.map(billed["data"], & &1["id"])

      assert build_conn()
             |> authed_with_key(key)
             |> get("/api/admin/users?status=trialing")
             |> json_response(422)
    end

    test "per_page is capped", %{conn: conn, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> get("/api/admin/users?per_page=9999")
        |> json_response(200)

      assert body["meta"]["per_page"] == 100
    end

    test "show reports the account's privilege trail", %{conn: conn, key: key, target: target} do
      build_conn()
      |> authed_with_key(key)
      |> post_json("/api/admin/users/#{target.id}/sandbox-limit", %{"limit" => 3})
      |> json_response(200)

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/admin/users/#{target.id}")
        |> json_response(200)

      assert body["data"]["id"] == target.id
      assert Enum.any?(body["data"]["admin_events"], &(&1["event_type"] =~ "sandbox_limit"))
    end

    test "an unknown id is 404, not a crash", %{conn: conn, key: key} do
      conn
      |> authed_with_key(key)
      |> get("/api/admin/users/#{Ecto.UUID.generate()}")
      |> json_response(404)

      build_conn()
      |> authed_with_key(key)
      |> get("/api/admin/users/not-a-uuid")
      |> json_response(404)
    end
  end

  describe "role" do
    test "grants and revokes, recording each distinctly", %{
      conn: conn,
      key: key,
      target: target
    } do
      conn
      |> authed_with_key(key)
      |> post_json("/api/admin/users/#{target.id}/role", %{"role" => "admin"})
      |> json_response(200)

      assert Accounts.get_user(target.id).role == "admin"
      assert "admin.role.granted" in event_types()

      build_conn()
      |> authed_with_key(key)
      |> post_json("/api/admin/users/#{target.id}/role", %{"role" => "user"})
      |> json_response(200)

      assert Accounts.get_user(target.id).role == "user"
      assert "admin.role.revoked" in event_types()
    end

    test "refuses to change your own role — a scripted lockout", %{
      conn: conn,
      admin: admin,
      key: key
    } do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/admin/users/#{admin.id}/role", %{"role" => "user"})
        |> json_response(422)

      assert body["error"] == "cannot_change_own_role"
      assert Accounts.get_user(admin.id).role == "admin"
    end
  end

  describe "sandbox limit" do
    test "sets the cap and records it", %{conn: conn, key: key, target: target} do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/admin/users/#{target.id}/sandbox-limit", %{"limit" => 0})
        |> json_response(200)

      assert body["data"]["max_concurrent_sandboxes"] == 0
      assert "admin.sandbox_limit.changed" in event_types()
    end

    test "refuses a negative limit", %{conn: conn, key: key, target: target} do
      conn
      |> authed_with_key(key)
      |> post_json("/api/admin/users/#{target.id}/sandbox-limit", %{"limit" => -1})
      |> json_response(422)

      assert admin_events() == []
    end
  end

  describe "suspend" do
    test "suspends and unsuspends, recording both", %{conn: conn, key: key, target: target} do
      conn
      |> authed_with_key(key)
      |> post_json("/api/admin/users/#{target.id}/suspend", %{"suspended" => true})
      |> json_response(200)

      assert Accounts.suspended?(Accounts.get_user(target.id))
      assert "admin.account.suspended" in event_types()

      build_conn()
      |> authed_with_key(key)
      |> post_json("/api/admin/users/#{target.id}/suspend", %{"suspended" => false})
      |> json_response(200)

      refute Accounts.suspended?(Accounts.get_user(target.id))
      assert "admin.account.unsuspended" in event_types()
    end

    test "refuses self-suspension", %{conn: conn, admin: admin, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/admin/users/#{admin.id}/suspend", %{"suspended" => true})
        |> json_response(422)

      assert body["error"] == "cannot_suspend_self"
      refute Accounts.suspended?(Accounts.get_user(admin.id))
    end

    test "suspending an already-suspended account is a no-op, not an error", %{
      key: key,
      target: target
    } do
      for _ <- 1..2 do
        build_conn()
        |> authed_with_key(key)
        |> post_json("/api/admin/users/#{target.id}/suspend", %{"suspended" => true})
        |> json_response(200)
      end

      assert Accounts.suspended?(Accounts.get_user(target.id))
    end
  end

  describe "delete" do
    test "deletes another account and records it", %{conn: conn, key: key, target: target} do
      body =
        conn
        |> authed_with_key(key)
        |> delete("/api/admin/users/#{target.id}")
        |> json_response(200)

      assert body["deleted"] == true
      refute Accounts.get_user(target.id)
      assert "admin.account.deleted" in event_types()
    end

    test "refuses self-deletion", %{conn: conn, admin: admin, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> delete("/api/admin/users/#{admin.id}")
        |> json_response(422)

      assert body["error"] == "cannot_delete_self"
      assert Accounts.get_user(admin.id)
    end
  end

  describe "billing actions when billing is disabled" do
    setup do
      previous = Application.get_env(:fountain, :credits_enabled)
      Application.put_env(:fountain, :credits_enabled, false)
      on_exit(fn -> Application.put_env(:fountain, :credits_enabled, previous) end)
      :ok
    end

    test "comp and credit grants are refused", %{key: key, target: target} do
      # The UI hides the buttons; events could still be sent by hand (#399).
      for {path, payload} <- [
            {"comp", %{"comped" => true}},
            {"credits", %{"cents" => 100}}
          ] do
        body =
          build_conn()
          |> authed_with_key(key)
          |> post_json("/api/admin/users/#{target.id}/#{path}", payload)
          |> json_response(404)

        assert body["billing"] == "disabled"
      end

      assert admin_events() == []
    end

    test "non-billing actions still work", %{conn: conn, key: key, target: target} do
      conn
      |> authed_with_key(key)
      |> post_json("/api/admin/users/#{target.id}/sandbox-limit", %{"limit" => 2})
      |> json_response(200)
    end
  end

  describe "trails" do
    test "cross-tenant audit events carry the tenant they belong to", %{
      conn: conn,
      key: key,
      target: target
    } do
      {:ok, _} =
        Fountain.Audit.record(%{
          action: "agent.created",
          resource_type: "agent",
          actor: "ui",
          user_id: target.id
        })

      body = conn |> authed_with_key(key) |> get("/api/admin/audit") |> json_response(200)

      row = Enum.find(body["data"], &(&1["action"] == "agent.created"))
      assert row["user_id"] == target.id
    end

    test "the privilege trail lists actor and target", %{conn: conn, key: key, target: target} do
      build_conn()
      |> authed_with_key(key)
      |> post_json("/api/admin/users/#{target.id}/role", %{"role" => "admin"})
      |> json_response(200)

      body = conn |> authed_with_key(key) |> get("/api/admin/events") |> json_response(200)

      row = hd(body["data"])
      assert row["event_type"] == "admin.role.granted"
      assert row["target_user_id"] == target.id
      assert row["actor_user_id"]
    end
  end

  describe "sandboxes" do
    test "lists live sandboxes with owner metadata only", %{conn: conn, key: key, target: target} do
      sandbox = insert_sandbox(user_id: target.id)

      body = conn |> authed_with_key(key) |> get("/api/admin/sandboxes") |> json_response(200)

      row = Enum.find(body["data"], &(&1["id"] == sandbox.id))
      assert row["user_email"] == target.email
      assert Map.has_key?(row, "conversation_count")
      refute Map.has_key?(row, "conversations")
    end

    test "reaping an unknown sandbox is 404", %{conn: conn, key: key} do
      conn
      |> authed_with_key(key)
      |> post("/api/admin/sandboxes/#{Ecto.UUID.generate()}/reap")
      |> json_response(404)
    end

    test "a reap the machine's owner refuses is a retryable 503", %{conn: conn, key: key} do
      # ADR 0058 stage 5b made `{:error, :sandbox_unavailable}` reachable here:
      # the reaper's own expiry of the same row holds its lease across the
      # provider call, and an operator's reap in that window is refused. The
      # clause used not to exist, so the action raised — a 500 on an operation
      # that declares none, which this repo's schema guard rejects on the way
      # out. Falls through to `FallbackController` now, which is where the
      # retryable shape already lived.
      sandbox = insert_sandbox(status: "ready")
      stub(Fountain.Machines.Destroy, :run, fn _id, _opts -> {:error, :machine_busy} end)

      conn =
        ExUnit.CaptureLog.with_log(fn ->
          conn |> authed_with_key(key) |> post("/api/admin/sandboxes/#{sandbox.id}/reap")
        end)
        |> elem(0)

      assert json_response(conn, 503) == %{"error" => "sandbox_unavailable"}
      assert get_resp_header(conn, "retry-after") == ["30"]
      assert Fountain.Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
    end
  end
end
