defmodule FountainWeb.Plugs.TenantSessionAuthTest do
  use FountainWeb.ConnCase, async: true

  alias FountainWeb.Plugs.TenantSessionAuth

  describe "call/2" do
    test "sets current_user when session is valid", %{conn: conn} do
      user = insert_verified_user()

      conn =
        conn
        |> login_user(user)
        |> TenantSessionAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "clears an unverified session and sends it to login with the reason", %{conn: conn} do
      user = insert_user()

      conn =
        conn
        |> login_user(user)
        |> Phoenix.Controller.fetch_flash([])
        |> TenantSessionAuth.call([])

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
      refute conn.assigns[:current_user]
      refute Plug.Conn.get_session(conn, :user_id)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Confirm your email address"
    end

    test "redirects to /auth/login when session is absent", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> TenantSessionAuth.call([])

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
    end

    test "redirects when session_version is stale (after password reset)", %{conn: conn} do
      user = insert_verified_user()

      # Simulate session stored with old version
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)
        |> Plug.Conn.put_session(:session_version, user.session_version - 1)
        |> TenantSessionAuth.call([])

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
    end

    test "redirects when user_id doesn't exist", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, Ecto.UUID.generate())
        |> Plug.Conn.put_session(:session_version, 0)
        |> TenantSessionAuth.call([])

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
    end

    test "redirects when user_id is an integer instead of a string", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, 12_345)
        |> Plug.Conn.put_session(:session_version, 0)
        |> TenantSessionAuth.call([])

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
    end

    test "redirects when session_version is a string instead of an integer", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, Ecto.UUID.generate())
        |> Plug.Conn.put_session(:session_version, "1")
        |> TenantSessionAuth.call([])

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
    end
  end
end
