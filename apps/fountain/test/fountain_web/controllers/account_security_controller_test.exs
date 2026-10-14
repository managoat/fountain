defmodule FountainWeb.AccountSecurityControllerTest do
  use FountainWeb.ConnCase, async: true
  use Oban.Testing, repo: Fountain.Repo

  import Phoenix.LiveViewTest

  alias Fountain.Accounts
  alias Fountain.Workers.EmailChangeEmail

  describe "the page" do
    test "renders both forms for a password account", %{conn: conn} do
      user = insert_verified_user()
      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/security")

      assert html =~ "Change password"
      assert html =~ "Change email address"
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

  describe "POST /account/security/email" do
    test "enqueues the confirmation and answers without an availability oracle", %{conn: conn} do
      user = insert_verified_user(%{"password" => "password-123"})

      conn =
        conn
        |> login_user(user)
        |> post(~p"/account/security/email", %{
          "new_email" => "next@example.com",
          "current_password" => "password-123"
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "confirmation link"
      assert_enqueued(worker: EmailChangeEmail, args: %{user_id: user.id})
    end

    test "a taken address gets the identical response and no job", %{conn: conn} do
      user = insert_verified_user(%{"password" => "password-123"})
      other = insert_verified_user()

      conn =
        conn
        |> login_user(user)
        |> post(~p"/account/security/email", %{
          "new_email" => other.email,
          "current_password" => "password-123"
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "confirmation link"
      refute_enqueued(worker: EmailChangeEmail)
    end

    test "blocks the 11th request in the shared bucket", %{conn: conn} do
      user = insert_verified_user(%{"password" => "password-123"})
      conn = login_user(conn, user)

      for i <- 1..10 do
        post(conn, ~p"/account/security/email", %{
          "new_email" => "n#{i}@example.com",
          "current_password" => "password-123"
        })
      end

      conn11 =
        post(conn, ~p"/account/security/email", %{
          "new_email" => "n11@example.com",
          "current_password" => "password-123"
        })

      assert conn11.status == 429
    end
  end

  describe "GET /account/email/confirm/:token" do
    test "completes the change and drops every session", %{conn: conn} do
      user = insert_verified_user()
      token = Accounts.email_change_token(user, "confirmed@example.com")

      conn = get(conn, ~p"/account/email/confirm/#{token}")

      assert redirected_to(conn) == ~p"/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "confirmed@example.com"
      assert Accounts.get_user(user.id).email == "confirmed@example.com"
    end

    test "a nonsense token reports invalid", %{conn: conn} do
      conn = get(conn, ~p"/account/email/confirm/garbage")

      assert redirected_to(conn) == ~p"/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid"
    end

    test "a claimed address reports unavailable and changes nothing", %{conn: conn} do
      user = insert_verified_user()
      token = Accounts.email_change_token(user, "raced@example.com")
      insert_verified_user(%{"email" => "raced@example.com"})

      conn = get(conn, ~p"/account/email/confirm/#{token}")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer available"
      assert Accounts.get_user(user.id).email == user.email
    end
  end
end
