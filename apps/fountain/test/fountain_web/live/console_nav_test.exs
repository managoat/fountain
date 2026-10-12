defmodule FountainWeb.ConsoleNavTest do
  @moduledoc """
  The console's sidebar (#875).

  Account, API keys, inference keys, runners, billing, security, the audit log
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
          ~p"/agents",
          ~p"/environments",
          ~p"/vaults",
          ~p"/account",
          ~p"/api-keys",
          ~p"/account/inference-credentials",
          ~p"/account/runners",
          ~p"/account/security",
          ~p"/audit",
          ~p"/help",
          ~p"/auth/logout"
        ] do
      assert html =~ ~s|href="#{path}"|, "#{path} is missing from the sidebar"
    end
  end

  test "the email is shown but is no longer a control", %{conn: conn, user: user} do
    {:ok, lv, html} = live(conn, ~p"/dashboard")

    assert html =~ user.email
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

    test "no billing page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      refute html =~ ~s|href="/account/billing"|
    end
  end

  test "the current page is marked, wherever in the sidebar it lives", %{conn: conn} do
    # `exact` on /account matters: /account/security must not light both up.
    {:ok, _lv, html} = live(conn, ~p"/account/security")

    assert [_ | _] =
             Regex.scan(~r|<a[^>]+href="/account/security"[^>]*class="([^"]*)"|, html)
             |> Enum.filter(fn [_, class] -> class =~ "font-medium" end)

    refute Regex.scan(~r|<a[^>]+href="/account"[^>]*class="([^"]*)"|, html)
           |> Enum.any?(fn [_, class] -> class =~ "font-medium" end)
  end
end
