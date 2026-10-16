defmodule FountainWeb.ConsoleNavTest do
  @moduledoc """
  The console's sidebar (#875).

  Account, API keys, inference keys, billing, the audit log
  and admin used to live in a popup behind the user's email address. A
  destination you cannot see is one you do not know you have, so they are
  sections now — and being sections, they are assertable.
  """

  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, conn: login_user(conn, user), user: user}
  end

  test "every destination is in the lightweight layout", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    for path <- [
          ~p"/dashboard",
          ~p"/audit",
          ~p"/docs",
          ~p"/auth/logout"
        ] do
      assert html =~ ~s|href="#{path}"|, "#{path} is missing from the page"
    end
  end

  # ADR 0076: agents, environments and vaults are configured in the
  # Conversations app, the CLI and the API, and help is the manual.
  test "links no retired console page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    for path <- [
          "/agents",
          "/environments",
          "/vaults",
          "/help",
          "/account/inference-credentials",
          "/account/bindings"
        ] do
      refute html =~ ~s|href="#{path}"|, "#{path} is still linked from the console"
    end
  end

  test "the email is shown but is no longer a control", %{conn: conn, user: user} do
    {:ok, lv, html} = live(conn, ~p"/dashboard")

    assert html =~ user.email
    assert has_element?(lv, ~s|#user-header a[href="#{Fountain.Apps.account_url()}"]|, "Account")
    refute has_element?(lv, "#user-header a[data-phx-link]", "Account")
    # The old popup was a <details><summary>; nothing in the sidebar opens now.
    refute has_element?(lv, "#app-sidebar")
  end

  test "the build version is still reachable — it is what a bug report quotes", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    vsn = :fountain |> Application.spec(:vsn) |> to_string()
    assert html =~ "v#{vsn}"
  end

  describe "what a deployment does not have, it does not offer" do
    test "admin only for an admin", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      refute html =~ ~s|href="/admin"|

      admin = insert_verified_user(role: "admin")
      {:ok, _lv, html} = live(login_user(build_conn(), admin), ~p"/dashboard")
      assert html =~ ~s|href="/admin"|
    end
  end

  test "audit uses the user header and offers a way back", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/audit")
    assert has_element?(lv, "#user-header")
    refute has_element?(lv, "#app-sidebar")
    assert has_element?(lv, ~s|main a[href="/dashboard"]|)
  end

  test "admin shares the console header and account-style sections, including nested pages", %{
    conn: conn
  } do
    admin = insert_verified_user(role: "admin")
    conn = login_user(conn, admin)

    member = insert_verified_user()

    for path <- ["/admin", "/admin/users", "/admin/users/#{member.id}"] do
      {:ok, lv, _html} = live(conn, path)
      assert has_element?(lv, "#user-header")
      refute has_element?(lv, "#app-sidebar")
      assert has_element?(lv, ~s|#user-header a[href="/admin"][aria-current="page"]|)
      assert has_element?(lv, ~s|#admin-settings nav[aria-label="Admin sections"]|)
      assert has_element?(lv, ~s|#admin-sections a[href="/admin/keys"]|)
      selected = if path == "/admin", do: path, else: "/admin/users"
      assert has_element?(lv, ~s|#admin-sections a[href="#{selected}"][aria-current="page"]|)
      assert has_element?(lv, ~s|#admin-section-picker option[value="#{selected}"][selected]|)
      assert has_element?(lv, ~s|#user-header a[href="/account"]|)
    end
  end

  test "the current page is marked, wherever in the sidebar it lives", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert [_ | _] =
             Regex.scan(
               ~r|<a[^>]+href="/dashboard"[^>]*class="([^"]*)"|,
               html
             )
             |> Enum.filter(fn [_, class] -> class =~ "font-medium" end)

    refute Regex.scan(~r|<a[^>]+href="/account"[^>]*class="([^"]*)"|, html)
           |> Enum.any?(fn [_, class] -> class =~ "font-medium" end)
  end
end
