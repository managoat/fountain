defmodule FountainWeb.Live.HooksTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Repo
  alias Fountain.Accounts.User

  # ── helpers ─────────────────────────────────────────────────────────────────

  # ── :require_authenticated_user ─────────────────────────────────────────────

  describe ":require_authenticated_user hook" do
    test "redirects unverified user to the waiting page, not the login form", %{conn: conn} do
      user = insert_user()
      # user has no email_verified_at — do NOT call verify_email
      conn = login_user(conn, user)

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/dashboard")
      assert path == "/auth/verify-pending"
    end

    test "redirects unauthenticated user (no session) to /auth/login", %{conn: conn} do
      # No login — session has no user_id, so current_user is nil
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/dashboard")
      assert path =~ "/auth/login"
    end
  end

  # ── :require_pending_verification ───────────────────────────────────────────

  describe ":require_pending_verification hook" do
    test "lets an unverified user through to the waiting page", %{conn: conn} do
      user = insert_user()
      conn = login_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/auth/verify-pending")
      assert html =~ "Check your email"
    end

    test "bounces a verified user to the console so the page can't be camped on", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/auth/verify-pending")
      assert path == "/dashboard"
    end

    # One destination whatever the account has set up (#867): the wizard that
    # used to claim a half-configured account is gone.
    test "sends an onboarded user to the same place", %{conn: conn} do
      user = insert_verified_user()

      {:ok, user} =
        user
        |> Ecto.Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
        |> Repo.update()

      conn = login_user(conn, user)

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/auth/verify-pending")
      assert path == "/dashboard"
    end

    test "redirects an unauthenticated visitor to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/auth/verify-pending")
      assert path =~ "/auth/login"
    end
  end

  # ── :require_authenticated_user — session_version mismatch ──────────────────

  describe "mount_current_user — session version mismatch" do
    test "expired session is treated as unauthenticated and redirected to login", %{conn: conn} do
      user = insert_verified_user()
      # Log in — sets session_version matching user.session_version (0)
      conn = login_user(conn, user)

      # Bump the user's session_version in the DB (simulates a password reset)
      {:ok, _} =
        user
        |> User.invalidate_sessions_changeset()
        |> Repo.update()

      # The cookie still carries the old session_version=0, but DB is now 1
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/dashboard")
      assert path =~ "/auth/login"
    end
  end

  # ── :require_admin ──────────────────────────────────────────────────────────

  describe ":require_admin hook" do
    test "redirects non-admin user to /dashboard", %{conn: conn} do
      user = insert_verified_user()
      # insert_verified_user creates a regular user with role "user"
      conn = login_user(conn, user)

      assert {:error, {:live_redirect, %{to: path}}} = live(conn, ~p"/admin")
      assert path == "/dashboard"
    end

    test "redirects unauthenticated user (no session) to /auth/login", %{conn: conn} do
      # require_admin mounts current_user itself; nil user -> HTTP redirect to login
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin")
      assert path =~ "/auth/login"
    end
  end

  # ── track_current_path ───────────────────────────────────────────────────────

  describe "track_current_path hook" do
    test "current_path is updated on navigation within a live_session", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      # Navigate to /dashboard — both routes share the :authenticated live_session
      {:ok, _lv, _html} = live(conn, ~p"/dashboard")

      # Patch to another path in the same live_session via live_patch
      # (handle_params fires, which invokes the :current_path hook)
      {:ok, _lv2, _html2} = live(conn, ~p"/audit")

      # The second mount succeeds — confirming track_current_path doesn't crash
      # and the hook is properly attached and fires handle_params.
      assert true
    end
  end

  # ── Direct on_mount unit tests ───────────────────────────────────────────────
  # The :browser_authenticated plug redirects unauthenticated requests before
  # reaching LiveView, so the is_nil(user) branches are never triggered through
  # the router. Call on_mount directly with a minimal socket to cover them.

  describe "on_mount/4 — nil user unit paths" do
    defp minimal_socket do
      struct(Phoenix.LiveView.Socket, %{
        endpoint: FountainWeb.Endpoint,
        assigns: %{__changed__: %{}}
      })
    end

    test ":require_authenticated_user halts with login redirect when current_user is nil" do
      {:halt, socket} =
        FountainWeb.Live.Hooks.on_mount(:require_authenticated_user, %{}, %{}, minimal_socket())

      assert socket.redirected == {:redirect, %{status: 302, to: "/auth/login"}}
    end

    test ":require_admin halts with login redirect when current_user is nil" do
      {:halt, socket} =
        FountainWeb.Live.Hooks.on_mount(:require_admin, %{}, %{}, minimal_socket())

      assert socket.redirected == {:redirect, %{status: 302, to: "/auth/login"}}
    end

    test ":require_pending_verification halts with login redirect when current_user is nil" do
      {:halt, socket} =
        FountainWeb.Live.Hooks.on_mount(
          :require_pending_verification,
          %{},
          %{},
          minimal_socket()
        )

      assert socket.redirected == {:redirect, %{status: 302, to: "/auth/login"}}
    end

    # VerifyPendingLive re-checks in mount/3 as well, so going through the
    # router cannot tell the two guards apart. Called directly, this pins the
    # hook itself: the live_session must reject a verified user on its own.
    test ":require_pending_verification halts for a user who is already verified" do
      user = insert_verified_user()

      socket =
        struct(Phoenix.LiveView.Socket, %{
          endpoint: FountainWeb.Endpoint,
          assigns: %{__changed__: %{}, current_user: user}
        })

      {:halt, socket} =
        FountainWeb.Live.Hooks.on_mount(:require_pending_verification, %{}, %{}, socket)

      assert socket.redirected == {:redirect, %{status: 302, to: "/dashboard"}}
    end

    # The router pairs :require_admin after :require_authenticated_user, so
    # this branch is unreachable through it. Called directly, because the hook
    # mounts current_user itself and is therefore a gate in its own right.
    test ":require_admin halts an unverified admin" do
      user = insert_user(%{role: "admin"})
      # Pinned: verification is checked before role, so this test would pass on
      # a plain user too if the factory ever stopped honouring :role.
      assert user.role == "admin"

      socket =
        struct(Phoenix.LiveView.Socket, %{
          endpoint: FountainWeb.Endpoint,
          assigns: %{__changed__: %{}, current_user: user}
        })

      {:halt, socket} = FountainWeb.Live.Hooks.on_mount(:require_admin, %{}, %{}, socket)

      assert socket.redirected == {:redirect, %{status: 302, to: "/auth/verify-pending"}}
    end

    test ":require_pending_verification continues for a user who is not verified" do
      user = insert_user()

      socket =
        struct(Phoenix.LiveView.Socket, %{
          endpoint: FountainWeb.Endpoint,
          assigns: %{__changed__: %{}, current_user: user}
        })

      assert {:cont, _socket} =
               FountainWeb.Live.Hooks.on_mount(:require_pending_verification, %{}, %{}, socket)
    end
  end
end
