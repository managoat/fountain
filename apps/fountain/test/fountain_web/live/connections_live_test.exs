defmodule FountainWeb.ConnectionsLiveTest do
  # Turns the broker on and off (global app env).
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Fountain.BrokerTestHelpers

  alias Fountain.Connections
  alias Fountain.Connections.{Google, OAuth}

  test "hidden and redirected where no broker is configured", %{conn: conn} do
    user = insert_verified_user()
    disable_broker()
    conn = login_user(conn, user)

    refute conn |> get(~p"/account") |> html_response(200) =~ ~s(href="/account/connections")
    assert {:error, {:live_redirect, %{to: "/account"}}} = live(conn, ~p"/account/connections")
  end

  test "lists connections, links to the flow, revokes and removes", %{conn: conn} do
    user = insert_verified_user()
    enable_connections()
    c = insert_connection(user, account_email: "me@example.com", access_token: "never-in-html")
    conn = login_user(conn, user)

    assert conn |> get(~p"/account") |> html_response(200) =~ ~s(href="/account/connections")

    {:ok, lv, html} = live(conn, ~p"/account/connections")
    assert html =~ "me@example.com"
    assert html =~ ~s(href="/connections/google/start")
    assert html =~ c.id
    assert html =~ "GOOGLE_ACCESS_TOKEN"
    refute html =~ "never-in-html"

    Req.Test.stub(OAuth, fn req -> Req.Test.json(req, %{}) end)

    html = lv |> element("#connection-#{c.id} button", "Revoke") |> render_click()
    assert html =~ "Revoked me@example.com"
    assert %{status: "revoked"} = Connections.get_connection(c.id, user.id)
    assert html =~ "Connect the account again"

    html = lv |> element("#connection-#{c.id} button", "Remove") |> render_click()
    assert html =~ "No connections yet"
    refute Connections.get_connection(c.id, user.id)
  end

  test "says so when Google is not configured on this deployment", %{conn: conn} do
    user = insert_verified_user()
    enable_connections()
    previous = Application.get_env(:fountain, :google_oauth_client_id)
    on_exit(fn -> Application.put_env(:fountain, :google_oauth_client_id, previous) end)
    Application.put_env(:fountain, :google_oauth_client_id, nil)

    {:ok, _lv, html} = conn |> login_user(user) |> live(~p"/account/connections")
    assert html =~ "Not configured on this deployment"
    refute html =~ ~s(href="/connections/google/start")
  end

  test "adds an OAuth app from a preset, shows its redirect URI and connect link, edits and deletes it",
       %{
         conn: conn
       } do
    user = insert_verified_user()
    enable_connections()
    {:ok, lv, html} = conn |> login_user(user) |> live(~p"/account/connections")
    assert html =~ "Providers"
    assert html =~ "Connect a remote MCP server"

    lv |> element("button[data-role=new-provider]") |> render_click()
    html = lv |> element("#provider-form button", "GitHub") |> render_click()
    assert html =~ "https://github.com/login/oauth/authorize"

    html =
      lv
      |> form("#provider-form", %{
        "provider" => %{
          "kind" => "oauth2",
          "name" => "GitHub",
          "slug" => "github",
          "authorize_url" => "https://github.com/login/oauth/authorize",
          "token_url" => "https://github.com/login/oauth/access_token",
          "userinfo_url" => "https://api.github.com/user",
          "account_label_path" => "login",
          "scopes" => "repo read:user",
          "client_id" => "Iv1.abc",
          "client_secret" => "never-in-html",
          "token_endpoint_auth" => "client_secret_post",
          "pkce" => "false",
          "env_key" => "",
          "token_hosts" => "api.github.com"
        }
      })
      |> render_submit()

    assert [p] = Connections.list_providers(user.id)
    assert p.slug == "github"
    assert html =~ "Saved GitHub"
    assert html =~ "/connections/#{p.id}/callback"
    assert html =~ ~s(href="/connections/#{p.id}/start")
    assert html =~ "GITHUB_ACCESS_TOKEN"
    refute html =~ "never-in-html"

    # Validation errors stay on the form.
    lv |> element("button[data-role=new-provider]") |> render_click()

    html =
      lv
      |> form("#provider-form", %{
        "provider" => %{
          "kind" => "oauth2",
          "name" => "Bad",
          "slug" => "bad",
          "authorize_url" => "http://x/a"
        }
      })
      |> render_submit()

    assert html =~ "authorize_url must be an https URL"
    assert [_] = Connections.list_providers(user.id)
    lv |> element("#provider-form button", "Cancel") |> render_click()

    html = lv |> element("#provider-#{p.id} button", "Edit") |> render_click()
    assert html =~ "Edit provider"

    html =
      lv
      |> form("#provider-form", %{"provider" => %{"name" => "GH", "client_secret" => ""}})
      |> render_submit()

    assert html =~ "Saved GH"

    assert Connections.get_provider(p.id, user.id).client_secret_ciphertext ==
             p.client_secret_ciphertext

    html = lv |> element("#provider-#{p.id} button", "Delete") |> render_click()
    assert html =~ "Deleted GH"
    assert Connections.list_providers(user.id) == []
  end

  test "discovers a remote MCP server and offers to connect it", %{conn: conn} do
    user = insert_verified_user()
    enable_connections()

    Req.Test.stub(OAuth, fn req ->
      case {req.method, req.request_path} do
        {"GET", "/mcp"} ->
          req
          |> Plug.Conn.put_resp_header(
            "www-authenticate",
            ~s(Bearer resource_metadata="https://mcp.example/.well-known/oauth-protected-resource/mcp")
          )
          |> Plug.Conn.send_resp(401, "")

        {"GET", "/.well-known/oauth-protected-resource/mcp"} ->
          Req.Test.json(req, %{"authorization_servers" => ["https://auth.example"]})

        {"GET", "/.well-known/oauth-authorization-server"} ->
          Req.Test.json(req, %{
            "issuer" => "https://auth.example",
            "authorization_endpoint" => "https://auth.example/authorize",
            "token_endpoint" => "https://auth.example/token",
            "registration_endpoint" => "https://auth.example/register"
          })

        {"POST", "/register"} ->
          Req.Test.json(req, %{"client_id" => "dcr", "client_secret" => "s"})
      end
    end)

    {:ok, lv, _html} = conn |> login_user(user) |> live(~p"/account/connections")

    # A chip from the verified registry (#1322) prefills the URL.
    html = lv |> element("#mcp-discover-form button", "Linear") |> render_click()
    assert html =~ ~s(value="https://mcp.linear.app/mcp")

    html =
      lv
      |> form("#mcp-discover-form", %{"mcp_url" => "https://mcp.example/mcp"})
      |> render_submit()

    assert html =~ "registered a client"
    assert [p] = Connections.list_providers(user.id)
    assert p.kind == "mcp"
    assert html =~ "registered automatically"
    # No userinfo on an MCP server: the connect form asks for an account name.
    assert html =~ ~s(action="/connections/#{p.id}/start")

    html =
      lv
      |> form("#mcp-discover-form", %{"mcp_url" => "http://mcp.example/mcp"})
      |> render_submit()

    assert html =~ "Discovery failed"
  end

  test "an expired connection offers a reconnect", %{conn: conn} do
    user = insert_verified_user()
    enable_connections()
    p = insert_provider(user, slug: "svc")
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

    c =
      insert_connection(user,
        provider: p,
        refresh_token: nil,
        expires_at: past,
        account_email: "me"
      )

    {:error, :expired} = Connections.access_token(c)

    {:ok, _lv, html} = conn |> login_user(user) |> live(~p"/account/connections")
    assert html =~ "expired"
    assert html =~ "Reconnect"
    assert html =~ ~s(href="/connections/#{p.id}/start?label=me")
  end
end
