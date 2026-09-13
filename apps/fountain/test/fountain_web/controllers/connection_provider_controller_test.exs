defmodule FountainWeb.ConnectionProviderControllerTest do
  # Turns the broker on and off (global app env).
  use FountainWeb.ConnCase, async: false

  import Fountain.BrokerTestHelpers

  alias Fountain.Connections
  alias Fountain.Connections.OAuth

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, {_key, raw}} = Fountain.Accounts.create_api_key(user.id, "t")
    enable_connections()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("accept", "application/json")

    {:ok, conn: conn, user: user}
  end

  @github %{
    "kind" => "oauth2",
    "slug" => "github",
    "name" => "GitHub",
    "authorize_url" => "https://github.com/login/oauth/authorize",
    "token_url" => "https://github.com/login/oauth/access_token",
    "userinfo_url" => "https://api.github.com/user",
    "account_label_path" => "login",
    "scopes" => ["repo"],
    "client_id" => "Iv1.abc",
    "client_secret" => "top-secret",
    "token_hosts" => ["api.github.com"]
  }

  test "an account the broker is not on for gets 404 on every route", %{conn: conn} do
    Application.delete_env(:fountain, :broker_listen_port)

    assert %{"error" => "connections_not_enabled"} =
             conn |> get("/api/connection-providers") |> json_response(404)

    assert %{"error" => "connections_not_enabled"} =
             conn |> post("/api/connection-providers", @github) |> json_response(404)
  end

  test "creates, lists, shows, edits and deletes an oauth2 provider without ever returning the secret",
       %{
         conn: conn,
         user: user
       } do
    created = conn |> post("/api/connection-providers", @github) |> json_response(201)
    assert created["slug"] == "github"
    assert created["env_key"] == "GITHUB_ACCESS_TOKEN"
    assert created["has_client_secret"] == true
    assert created["configured"] == true
    assert created["platform"] == false
    assert created["redirect_uri"] =~ "/connections/#{created["id"]}/callback"
    assert created["connect_url"] =~ "/connections/#{created["id"]}/start"
    refute inspect(created) =~ "top-secret"

    assert %{"data" => [google, microsoft, slack, github]} =
             conn |> get("/api/connection-providers") |> json_response(200)

    assert google["id"] == "google"
    assert microsoft["id"] == "microsoft"
    assert slack["id"] == "slack"
    assert github["id"] == created["id"]

    assert conn
           |> get("/api/connection-providers/google")
           |> json_response(200)
           |> Map.fetch!("platform")

    # The same list answers on the connections route, for older clients.
    assert %{"data" => [_, _, _, _]} =
             conn |> get("/api/connections/providers") |> json_response(200)

    updated =
      conn
      |> patch("/api/connection-providers/#{created["id"]}", %{
        "name" => "GH",
        "client_secret" => ""
      })
      |> json_response(200)

    assert updated["name"] == "GH"
    assert updated["has_client_secret"] == true

    assert %{"errors" => %{"token_url" => [_]}} =
             conn
             |> patch("/api/connection-providers/#{created["id"]}", %{"token_url" => "http://x/y"})
             |> json_response(422)

    # The platform provider is read-only.
    assert conn
           |> patch("/api/connection-providers/google", %{"name" => "x"})
           |> json_response(404)

    assert conn |> delete("/api/connection-providers/google") |> json_response(404)

    assert conn |> delete("/api/connection-providers/#{created["id"]}") |> response(204)
    assert Connections.list_providers(user.id) == []
  end

  test "is tenant-scoped and needs a full-scope key", %{conn: conn, user: user} do
    other = insert_verified_user()
    enable_connections()
    theirs = insert_provider(other)

    assert conn |> get("/api/connection-providers/#{theirs.id}") |> json_response(404)

    assert conn
           |> patch("/api/connection-providers/#{theirs.id}", %{"name" => "x"})
           |> json_response(404)

    assert conn |> delete("/api/connection-providers/#{theirs.id}") |> json_response(404)

    {_k, sprite_key} = insert_sprite_api_key(user)

    build_conn()
    |> put_req_header("authorization", "Bearer #{sprite_key}")
    |> put_req_header("accept", "application/json")
    |> get("/api/connection-providers")
    |> json_response(403)
  end

  test "creates an mcp provider by discovery, and re-runs it on request", %{conn: conn} do
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

    created =
      conn
      |> post("/api/connection-providers", %{
        "kind" => "mcp",
        "mcp_url" => "https://mcp.example/mcp"
      })
      |> json_response(201)

    assert created["kind"] == "mcp"
    assert created["issuer"] == "https://auth.example"
    assert created["client_source"] == "dcr"
    assert created["client_id"] == "dcr"
    assert created["registration_endpoint"] == "https://auth.example/register"
    assert created["token_hosts"] == ["mcp.example"]
    assert created["pkce"] == true

    assert conn
           |> post("/api/connection-providers/#{created["id"]}/discover")
           |> json_response(200)

    assert %{"error" => "discovery_failed", "detail" => detail} =
             conn
             |> post("/api/connection-providers", %{
               "kind" => "mcp",
               "mcp_url" => "http://mcp.example/mcp"
             })
             |> json_response(422)

    assert detail =~ "https"

    assert %{"error" => "discovery_failed"} =
             conn |> post("/api/connection-providers", %{"kind" => "mcp"}) |> json_response(422)
  end

  test "a connection on a tenant provider carries the provider id", %{conn: conn, user: user} do
    p = insert_provider(user, slug: "github")
    c = insert_connection(user, provider: p, account_email: "octocat")

    shown = conn |> get("/api/connections/#{c.id}") |> json_response(200)
    assert shown["provider"] == "github"
    assert shown["provider_id"] == p.id
    assert shown["env_key"] == "GITHUB_ACCESS_TOKEN"
  end
end
