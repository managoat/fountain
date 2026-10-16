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

  test "every destination is in the sidebar itself, not behind a disclosure", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    for path <- [
          ~p"/dashboard",
          ~p"/audit",
          ~p"/docs",
          ~p"/auth/logout"
        ] do
      assert html =~ ~s|href="#{path}"|, "#{path} is missing from the sidebar"
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
          "/account",
          "/account/inference-credentials",
          "/account/bindings"
        ] do
      refute html =~ ~s|href="#{path}"|, "#{path} is still linked from the console"
    end
  end

  test "the email is shown but is no longer a control", %{conn: conn, user: user} do
    {:ok, lv, html} = live(conn, ~p"/dashboard")

    assert html =~ user.email
    assert has_element?(lv, ~s|#app-sidebar a[href="#{Fountain.Apps.account_url()}"]|, "Account")
    refute has_element?(lv, "#app-sidebar a[data-phx-link]", "Account")
    # The old popup was a <details><summary>; nothing in the sidebar opens now.
    assert lv |> element("#app-sidebar summary") |> has_element?() == false
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
