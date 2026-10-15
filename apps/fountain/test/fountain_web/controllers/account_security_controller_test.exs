defmodule FountainWeb.AccountSecurityControllerTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  describe "the page" do
    test "renders the password form for a password account", %{conn: conn} do
      user = insert_verified_user()
      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/security")

      assert html =~ "Change password"
      refute html =~ "Change email address"
      assert html =~ user.email
    end

    test "explains instead of offering forms to an OAuth-only account", %{conn: conn} do
      {:ok, user, :new} =
        Accounts.upsert_oauth_user("github", "uid-sec-test", %{"email" => "oauth-sec@example.com"})

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/security")

      assert html =~ "signs in with GitHub"
      refute html =~ "Update password"
    end

    test "requires authentication", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/account/security")
      assert path =~ "/auth/login"
    end
  end

  describe "POST /account/security/password" do
    test "changes the password and keeps THIS session alive", %{conn: conn} do
      user = insert_verified_user(%{"password" => "old-password-123"})

      conn =
        conn
        |> login_user(user)
        |> post(~p"/account/security/password", %{
          "current_password" => "old-password-123",
          "new_password" => "new-password-456"
        })

      assert redirected_to(conn) == ~p"/account/security"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Other sessions"

      # The session cookie was re-issued against the bumped session_version —
      # a stale one would bounce the very next request to login.
      updated = Accounts.get_user(user.id)
      assert get_session(conn, :session_version) == updated.session_version
      assert updated.session_version > user.session_version

      assert {:ok, _} = Accounts.authenticate_user(user.email, "new-password-456")
    end

    test "a wrong current password changes nothing", %{conn: conn} do
      user = insert_verified_user(%{"password" => "old-password-123"})

      conn =
        conn
        |> login_user(user)
        |> post(~p"/account/security/password", %{
          "current_password" => "wrong",
          "new_password" => "new-password-456"
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "incorrect"
      assert {:ok, _} = Accounts.authenticate_user(user.email, "old-password-123")
    end

    test "unauthenticated requests bounce to login", %{conn: conn} do
      conn =
        post(conn, ~p"/account/security/password", %{
          "current_password" => "x",
          "new_password" => "y"
        })

      assert redirected_to(conn) == ~p"/auth/login"
    end
  end

  describe "the rate limit" do
    test "blocks the 11th request in the bucket", %{conn: conn} do
      user = insert_verified_user(%{"password" => "password-123"})
      conn = login_user(conn, user)

      for _ <- 1..10 do
        post(conn, ~p"/account/security/password", %{
          "current_password" => "wrong",
          "new_password" => "another-password-456"
        })
      end

      conn11 =
        post(conn, ~p"/account/security/password", %{
          "current_password" => "wrong",
          "new_password" => "another-password-456"
        })

      assert conn11.status == 429
    end
  end
end
