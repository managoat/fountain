defmodule FountainWeb.AccountOAuthAppsTest do
  @moduledoc "The OAuth apps section of `/account` (#1125, `AccountLive.OAuthApps`)."
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.OAuth

  test "registers an app and shows its generated client_id", %{conn: conn} do
    user = insert_verified_user()
    {:ok, view, _html} = conn |> login_user(user) |> live(~p"/account?open=oauth-apps")

    html =
      view
      |> element("button", "Register an app")
      |> render_click()

    assert html =~ "Redirect URIs"

    html =
      view
      |> form("#oauth-app-form", %{
        "name" => "Notes",
        "redirect_uris" => "https://abc.sprites.app/callback\nhttp://localhost:5173/callback"
      })
      |> render_submit()

    assert [client] = OAuth.list_clients(user.id)

    assert client.redirect_uris == [
             "https://abc.sprites.app/callback",
             "http://localhost:5173/callback"
           ]

    assert html =~ client.client_id
    assert html =~ "In development"
    # A loopback redirect was registered, so the card must not imply that
    # :5173 is the only origin CORS will admit.
    assert html =~ "(loopback: any port)"
  end

  test "shows the validation error rather than saving", %{conn: conn} do
    user = insert_verified_user()
    {:ok, view, _html} = conn |> login_user(user) |> live(~p"/account?open=oauth-apps")

    view |> element("button", "Register an app") |> render_click()

    html =
      view
      |> form("#oauth-app-form", %{
        "name" => "Notes",
        "redirect_uris" => "http://notes.test/callback"
      })
      |> render_submit()

    assert html =~ "must be https, unless loopback"
    assert OAuth.list_clients(user.id) == []
  end

  test "edits and deletes, and never shows another account's app", %{conn: conn} do
    user = insert_verified_user()
    mine = insert_oauth_client(user_id: user.id, name: "Mine")
    theirs = insert_oauth_client(name: "Theirs")

    {:ok, view, html} = conn |> login_user(user) |> live(~p"/account?open=oauth-apps")

    assert html =~ "Mine"
    refute html =~ theirs.client_id

    view |> element("button[phx-value-id='#{mine.id}'][phx-click=edit]") |> render_click()

    view
    |> form("#oauth-app-form", %{
      "name" => "Renamed",
      "redirect_uris" => "https://new.test/callback"
    })
    |> render_submit()

    assert OAuth.get_client_record(mine.id, user.id).name == "Renamed"

    view |> element("button[phx-value-id='#{mine.id}'][phx-click=delete]") |> render_click()

    assert OAuth.list_clients(user.id) == []
  end

  test "a published app offers neither Edit nor Delete", %{conn: conn} do
    user = insert_verified_user()
    client = insert_oauth_client(user_id: user.id, name: "Published", published: true)

    {:ok, view, html} = conn |> login_user(user) |> live(~p"/account?open=oauth-apps")

    assert html =~ "Published"
    refute has_element?(view, "button[phx-value-id='#{client.id}'][phx-click=edit]")
    refute has_element?(view, "button[phx-value-id='#{client.id}'][phx-click=delete]")
  end

  # The cancel that closed the form and a submit already in flight arrive in
  # that order; the save must not take the view down with it.
  test "a save with no form open is a no-op, not a crash", %{conn: conn} do
    user = insert_verified_user()

    {:ok, view, _html} = conn |> login_user(user) |> live(~p"/account?open=oauth-apps")

    assert view
           |> with_target("#oauth-apps-panel")
           |> render_click("save", %{"name" => "Ghost", "redirect_uris" => "https://x.test/c"})

    assert OAuth.list_clients(user.id) == []
    assert render(view) =~ "OAuth apps"
  end
end
