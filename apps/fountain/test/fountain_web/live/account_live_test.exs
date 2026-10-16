defmodule FountainWeb.AccountLiveTest do
  @moduledoc "Account navigation, password changes and self-serve deletion."
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
    test "defaults to API keys and renders section navigation with a mobile picker", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, html} = live(login_user(conn, user), "/account")
      assert html =~ user.email
      assert has_element?(lv, "#user-header a[aria-current=page]", "Account")
      refute has_element?(lv, "#app-sidebar")
      assert has_element?(lv, "#section-picker option[selected][value=api-keys]")
      refute has_element?(lv, "#api-keys[hidden]")
      assert has_element?(lv, "#security[hidden]")
      refute has_element?(lv, "button[aria-expanded]")
    end

    test "section links patch history and mobile selection uses the same route", %{conn: conn} do
      {:ok, lv, _} = live(login_user(conn, insert_verified_user()), "/account")
      lv |> element("a[data-section=connections]") |> render_click()
      assert_patch(lv, "/account?open=connections")
      refute has_element?(lv, "#connections[hidden]")
      assert has_element?(lv, "#api-keys[hidden]")
      render_change(lv, "select_section", %{"section" => "bindings"})
      assert_patch(lv, "/account?open=bindings")
      refute has_element?(lv, "#bindings[hidden]")
      render_patch(lv, "/account?open=connections")
      assert has_element?(lv, "a[data-section=connections][aria-current=page]")
    end

    test "legacy security sections and unknown values are normalized", %{conn: conn} do
      conn = login_user(conn, insert_verified_user())

      for section <- ["password", "delete", "security"] do
        {:ok, lv, _} = live(conn, "/account?open=" <> section)
        refute has_element?(lv, "#security[hidden]")
      end

      {:ok, lv, _} = live(conn, "/account?open=https://evil.test&server=https://evil.test")
      refute has_element?(lv, "#api-keys[hidden]")
    end

    test "requires authentication", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, "/account")
      assert path =~ "/auth/login"
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

      assert open?(lv, "password")
      assert open?(lv, "password")
      assert lv |> element("#password #password-notice") |> render() =~ "incorrect"
      # Shown beside the form, not again as a toast.
      refute has_element?(lv, "#flash-error")
      assert open?(lv, "delete")

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

      assert open?(lv, "password")
      assert lv |> element("#password-notice") |> render() =~ "Other sessions"
    end
  end

  describe "delete account" do
    test "typing the account's email arms the button inside the opened section", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account")

      lv |> element("a[data-section=security]") |> render_click()
      assert has_element?(lv, "#delete-account button[type=submit][disabled]")

      lv
      |> element("#delete-account input[name=email]")
      |> render_change(%{"email" => user.email})

      # The re-render the keystroke causes leaves the section open and armed.
      assert open?(lv, "delete")
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

      lv |> element("a[data-section=api-keys]") |> render_click()
      lv |> element("a[data-section=security]") |> render_click()

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

  # A collapsed section's body is hidden, not removed (its components keep
  # their state), so "open" is the absence of `hidden`.
  defp open?(lv, id) do
    assert has_element?(lv, "##{id}-body")
    not has_element?(lv, "##{id}[hidden]")
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
