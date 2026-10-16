defmodule FountainWeb.AccountConnectionsTest do
  @moduledoc "The Connections section of `/account` (`AccountLive.Connections`, ADR 0085)."
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Connections
  alias Fountain.Connections.FakeProvider

  @page "/account?open=connections"

  setup %{conn: conn} do
    FakeProvider.stub()
    user = insert_verified_user()
    {:ok, conn: login_user(conn, user), user: user}
  end

  test "connecting by URL sends the browser to the provider", %{conn: conn, user: user} do
    {:ok, lv, html} = live(conn, @page)
    assert html =~ "No connections yet"

    assert {:error, {:redirect, %{to: "https://auth.example.com/authorize?" <> _}}} =
             lv
             |> form("#connect-mcp-server", url: FakeProvider.server_url())
             |> render_submit()

    assert [%{status: "pending"}] = Connections.list(user.id)
  end

  test "a server with no registration asks for a client, then takes it", %{conn: conn, user: user} do
    FakeProvider.stub(registration: false, cimd: false)
    {:ok, lv, _html} = live(conn, @page)

    html = lv |> form("#connect-mcp-server", url: FakeProvider.server_url()) |> render_submit()
    assert html =~ "Client ID"
    assert html =~ "/connections/callback"

    assert {:error, {:redirect, %{to: url}}} =
             lv
             |> form("#connect-mcp-server",
               url: FakeProvider.server_url(),
               client_id: "mine",
               client_secret: "s",
               authorize_params: "access_type=offline\nprompt=consent"
             )
             |> render_submit()

    q = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert q["client_id"] == "mine"
    assert q["access_type"] == "offline"
    assert [%{registration: "pasted"}] = Connections.list(user.id)
  end

  test "a refused URL is explained in place", %{conn: conn} do
    {:ok, lv, _html} = live(conn, @page)

    html =
      lv
      |> form("#connect-mcp-server", url: "https://private.example.com/mcp")
      |> render_submit()

    assert html =~ "must not resolve to a private address"
  end

  test "lists, reconnects and disconnects", %{conn: conn, user: user} do
    {:ok, pending, _} = Connections.create(user.id, %{"url" => FakeProvider.server_url()})
    {:ok, lv, html} = live(conn, @page)
    assert html =~ pending.id
    assert html =~ "not finished"

    assert {:error, {:redirect, %{to: "https://auth.example.com/authorize?" <> _}}} =
             lv
             |> element("#connection-#{pending.id} button", "Finish connecting")
             |> render_click()

    {:ok, lv, _html} = live(conn, @page)
    html = lv |> element("#connection-#{pending.id} button", "Disconnect") |> render_click()
    assert html =~ "No connections yet"
    assert Connections.list(user.id) == []
  end
end
