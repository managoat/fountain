defmodule FountainWeb.AccountLiveTest do
  @moduledoc """
  `/account`: the password section (its POST is `AccountSecurityController`,
  tested there) and self-serve deletion, each collapsed until opened.

  The deletion tests are about the guards rather than the teardown —
  `Deletion` has its own tests for what actually gets removed. Admin-side
  deletion is in `AccountDeletionLiveTest`.
  """

  use FountainWeb.ConnCase, async: false
  use Mimic

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Fountain.Accounts
  alias Fountain.Accounts.User
  alias Fountain.Repo

  setup :set_mimic_global

  setup do
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> :client end)
    stub(Sprites, :sprite, fn :client, name -> {:handle, name} end)
    stub(Sprites, :destroy, fn _ -> :ok end)
    stub(Fountain.Conversations.ConversationServer, :whereis, fn _ -> nil end)
    :ok
  end

  describe "the page" do
    test "both sections are collapsed until opened", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, html} = live(login_user(conn, user), ~p"/account")

      assert html =~ user.email
      assert html =~ "Change password"
      assert html =~ "Delete account"

      assert has_element?(lv, ~s|#password-toggle[aria-expanded="false"]|)
      assert has_element?(lv, ~s|#delete-toggle[aria-expanded="false"]|)
      refute has_element?(lv, "#change-password")
      refute has_element?(lv, "#delete-account")
    end

    test "a section opens and closes on its header", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account")

      lv |> element("#password-toggle") |> render_click()
      assert has_element?(lv, ~s|#password-toggle[aria-expanded="true"]|)
      assert has_element?(lv, "#change-password")
      # Opening one leaves the other alone.
      refute has_element?(lv, "#delete-account")

      lv |> element("#password-toggle") |> render_click()
      refute has_element?(lv, "#change-password")
    end

    test "?open= expands the named section", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account?open=password")

      assert has_element?(lv, "#change-password")
      refute has_element?(lv, "#delete-account")
    end

    test "an unknown ?open= value expands nothing", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account?open=bogus")

      refute has_element?(lv, "#change-password")
      refute has_element?(lv, "#delete-account")
    end

    test "requires authentication", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/account")
      assert path =~ "/auth/login"
    end

    test "the deletion warning does not mention a subscription", %{conn: conn} do
      user = insert_verified_user()
      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account?open=delete")

      assert html =~ "Destroys every running sandbox"
      refute html =~ "subscription"
    end
  end

  describe "change password" do
    test "the form POSTs to the controller", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account?open=password")

      assert has_element?(lv, ~s|#change-password[action="/account/security/password"]|)
      assert has_element?(lv, ~s|#change-password input[name="current_password"]|)
      assert has_element?(lv, ~s|#change-password input[name="new_password"]|)
    end

    test "an OAuth-only account gets an explanation, not the form", %{conn: conn} do
      {:ok, user, :new} =
        Accounts.upsert_oauth_user("github", "uid-acct-test", %{
          "email" => "oauth-acct@example.com"
        })

      {:ok, lv, html} = live(login_user(conn, user), ~p"/account?open=password")

      assert html =~ "signs in with GitHub"
      refute has_element?(lv, "#change-password")
    end

    test "after a failed POST the section comes back open with the error in it", %{conn: conn} do
      user = insert_verified_user(%{"password" => "old-password-123"})

      conn =
        conn
        |> login_user(user)
        |> post(~p"/account/security/password", %{
          "current_password" => "wrong",
          "new_password" => "new-password-456"
        })

      {:ok, lv, _html} = follow(conn)

      assert has_element?(lv, ~s|#password-toggle[aria-expanded="true"]|)
      assert has_element?(lv, "#change-password")
      assert lv |> element("#password #password-notice") |> render() =~ "incorrect"
      # Shown beside the form, not again as a toast.
      refute has_element?(lv, "#flash-error")
      refute has_element?(lv, "#delete-account")

      # The first, disconnected render too: no toast flashing up before the
      # socket connects.
      dead =
        build_conn()
        |> Plug.Test.init_test_session(get_session(conn))
        |> get(redirected_to(conn))
        |> html_response(200)

      assert dead =~ ~s|id="password-notice"|
      refute dead =~ ~s|id="flash-error"|
    end

    test "after a successful POST the section comes back open with the outcome", %{conn: conn} do
      user = insert_verified_user(%{"password" => "old-password-123"})

      conn =
        conn
        |> login_user(user)
        |> post(~p"/account/security/password", %{
          "current_password" => "old-password-123",
          "new_password" => "new-password-456"
        })

      {:ok, lv, _html} = follow(conn)

      assert has_element?(lv, "#change-password")
      assert lv |> element("#password-notice") |> render() =~ "Other sessions"
    end
  end

  describe "delete account" do
    test "typing the account's email arms the button inside the opened section", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account")

      lv |> element("#delete-toggle") |> render_click()
      assert has_element?(lv, "#delete-account button[type=submit][disabled]")

      lv
      |> element("#delete-account input[name=email]")
      |> render_change(%{"email" => user.email})

      # The re-render the keystroke causes leaves the section open and armed.
      assert has_element?(lv, ~s|#delete-toggle[aria-expanded="true"]|)
      refute has_element?(lv, "#delete-account button[type=submit][disabled]")

      capture_log(fn ->
        assert {:error, {:redirect, %{to: to}}} =
                 lv |> form("#delete-account", %{"email" => user.email}) |> render_submit()

        # Out through the controller, because a LiveView cannot drop the
        # session cookie itself — leaving a signed-in session for a user row
        # that no longer exists.
        assert to =~ "/auth/logout"
        assert to =~ "deleted=1"
      end)

      refute Repo.get(User, user.id)
    end

    test "closing the section disarms it", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account?open=delete")

      lv
      |> element("#delete-account input[name=email]")
      |> render_change(%{"email" => user.email})

      lv |> element("#delete-toggle") |> render_click()
      lv |> element("#delete-toggle") |> render_click()

      assert has_element?(lv, "#delete-account button[type=submit][disabled]")
    end

    test "the wrong email deletes nothing", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account?open=delete")

      html = render_submit(lv, "delete_account", %{"email" => "someone-else@example.com"})

      assert html =~ "Type your email address exactly to confirm"
      assert has_element?(lv, "#delete #delete-error")
      assert Repo.get(User, user.id)
    end

    test "an empty confirmation deletes nothing", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account")

      render_submit(lv, "delete_account", %{"email" => ""})

      assert Repo.get(User, user.id)
    end
  end

  # Follow the controller's redirect carrying the session it wrote, flash and
  # all. `recycle/1` does not: a session seeded by `init_test_session` is not
  # round-tripped through the cookie.
  defp follow(conn) do
    build_conn()
    |> Plug.Test.init_test_session(get_session(conn))
    |> live(redirected_to(conn))
  end
end
