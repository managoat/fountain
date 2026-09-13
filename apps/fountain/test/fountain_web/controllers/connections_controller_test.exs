defmodule FountainWeb.ConnectionsControllerTest do
  # Turns the broker on and off (global app env).
  use FountainWeb.ConnCase, async: false

  import Fountain.BrokerTestHelpers

  alias Fountain.Connections
  alias Fountain.Connections.{Google, OAuth}

  setup %{conn: conn} do
    user = insert_verified_user()
    enable_connections()
    {:ok, conn: login_user(conn, user), user: user}
  end

  test "start sends the browser to Google with offline access and a signed state", %{conn: conn} do
    conn = get(conn, ~p"/connections/google/start")
    assert redirected_to(conn) =~ "https://accounts.google.com/o/oauth2/v2/auth?"

    params = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["access_type"] == "offline"
    assert params["prompt"] == "consent"
    assert params["client_id"] == "google-test-client-id"
    assert params["redirect_uri"] =~ "/connections/google/callback"
    assert is_binary(params["state"])
    assert get_session(conn, :connections_oauth)["nonce"]
  end

  test "the round trip stores a connection on the signed-in account", %{conn: conn, user: user} do
    conn = get(conn, ~p"/connections/google/start")

    state =
      conn
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    Req.Test.stub(OAuth, fn req ->
      case req.request_path do
        "/token" ->
          {:ok, body, _} = Plug.Conn.read_body(req)
          form = URI.decode_query(body)
          assert form["grant_type"] == "authorization_code"
          assert form["code"] == "the-code"
          assert form["client_secret"] == "google-test-client-secret"

          Req.Test.json(req, %{
            "access_token" => "at-1",
            "refresh_token" => "rt-1",
            "expires_in" => 3599,
            "scope" => "openid email https://www.googleapis.com/auth/gmail.modify"
          })

        "/v1/userinfo" ->
          assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer at-1"]
          Req.Test.json(req, %{"email" => "jake@example.com", "email_verified" => true})
      end
    end)

    conn =
      conn
      |> recycle()
      |> get(~p"/connections/google/callback", %{"code" => "the-code", "state" => state})

    assert redirected_to(conn) == ~p"/account/connections"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Connected jake@example.com"

    assert [%{account_email: "jake@example.com", status: "active", scopes: scopes}] =
             Connections.list_connections(user.id)

    assert "https://www.googleapis.com/auth/gmail.modify" in scopes
    refute get_session(conn, :connections_oauth_nonce)
  end

  test "the slack round trip: user_scope out, authed_user token in (#1299)", %{
    conn: conn,
    user: user
  } do
    conn = get(conn, ~p"/connections/slack/start")
    assert redirected_to(conn) =~ "https://slack.com/oauth/v2/authorize?"

    params = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["scope"] == ""
    assert params["user_scope"] =~ "chat:write"
    assert params["client_id"] == "slack-test-client-id"
    assert params["redirect_uri"] =~ "/connections/slack/callback"
    state = params["state"]

    Req.Test.stub(OAuth, fn req ->
      case req.request_path do
        "/api/oauth.v2.access" ->
          Req.Test.json(req, %{
            "ok" => true,
            "authed_user" => %{
              "id" => "U1",
              "access_token" => "xoxp-7",
              "scope" => "channels:history,chat:write",
              "token_type" => "user"
            }
          })

        "/api/auth.test" ->
          Req.Test.json(req, %{"ok" => true, "user" => "jake", "team" => "goat"})
      end
    end)

    conn =
      conn
      |> recycle()
      |> get(~p"/connections/slack/callback", %{"code" => "the-code", "state" => state})

    assert redirected_to(conn) == ~p"/account/connections"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Connected jake"

    assert [%{provider: "slack", provider_id: nil, env_key: "SLACK_ACCESS_TOKEN"} = stored] =
             Connections.list_connections(user.id)

    # no refresh token and no expiry: good until revoked
    assert stored.refresh_token_ciphertext == nil
    assert stored.expires_at == nil
  end

  test "a callback whose state did not come from this session is refused", %{
    conn: conn,
    user: user
  } do
    state =
      Phoenix.Token.sign(FountainWeb.Endpoint, "connections:oauth_state", {user.id, "other"})

    Req.Test.stub(OAuth, fn _ -> flunk("no exchange for a bad state") end)

    conn = get(conn, ~p"/connections/google/callback", %{"code" => "c", "state" => state})
    assert redirected_to(conn) == ~p"/account/connections"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "did not start from this session"
    assert Connections.list_connections(user.id) == []
  end

  test "a consent Google answered without a refresh token is explained", %{conn: conn, user: user} do
    conn = get(conn, ~p"/connections/google/start")

    state =
      conn
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    Req.Test.stub(OAuth, fn req ->
      Req.Test.json(req, %{"access_token" => "at", "expires_in" => 10})
    end)

    conn =
      conn
      |> recycle()
      |> get(~p"/connections/google/callback", %{"code" => "c", "state" => state})

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no refresh token"
    assert Connections.list_connections(user.id) == []
  end

  test "a denied consent comes back as a flash", %{conn: conn} do
    conn = get(conn, ~p"/connections/google/callback", %{"error" => "access_denied"})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "access_denied"
  end

  test "an account the broker is not on for is sent to /account", %{conn: conn} do
    Application.delete_env(:fountain, :broker_listen_port)
    conn = get(conn, ~p"/connections/google/start")
    assert redirected_to(conn) == ~p"/account"
  end

  test "signed out, the flow is not reachable" do
    conn = build_conn() |> get(~p"/connections/google/start")
    assert redirected_to(conn) =~ "/auth/login"
  end

  test "a tenant provider runs the same round trip with PKCE and its own client", %{
    conn: conn,
    user: user
  } do
    p = insert_provider(user, slug: "github", pkce: true, client_id: "cid", client_secret: "csec")

    conn = get(conn, ~p"/connections/#{p.id}/start")
    url = redirected_to(conn)
    assert url =~ "https://svc.example/oauth/authorize?"
    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["client_id"] == "cid"
    assert params["code_challenge_method"] == "S256"
    assert params["redirect_uri"] =~ "/connections/#{p.id}/callback"
    verifier = get_session(conn, :connections_oauth)["verifier"]
    assert is_binary(verifier)

    Req.Test.stub(OAuth, fn req ->
      case req.request_path do
        "/oauth/token" ->
          {:ok, body, _} = Plug.Conn.read_body(req)
          form = URI.decode_query(body)
          assert form["code_verifier"] == verifier
          assert form["client_secret"] == "csec"

          Req.Test.json(req, %{
            "access_token" => "at",
            "refresh_token" => "rt",
            "expires_in" => 100
          })

        "/user" ->
          Req.Test.json(req, %{"login" => "octocat"})
      end
    end)

    conn = get(conn, ~p"/connections/#{p.id}/callback?code=c&state=#{params["state"]}")
    assert redirected_to(conn) == ~p"/account/connections"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Connected octocat."

    assert [%{provider: "github", provider_id: pid, env_key: "GITHUB_ACCESS_TOKEN"}] =
             Connections.list_connections(user.id)

    assert pid == p.id
  end

  test "a callback for another provider than the one started is refused", %{
    conn: conn,
    user: user
  } do
    p = insert_provider(user)
    conn = get(conn, ~p"/connections/google/start")

    state =
      conn
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    Req.Test.stub(OAuth, fn _ -> flunk("no exchange") end)

    conn = get(conn, ~p"/connections/#{p.id}/callback?code=c&state=#{state}")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "different provider"
    assert Connections.list_connections(user.id) == []
  end

  test "an unknown provider and an unconfigured one are explained", %{conn: conn, user: user} do
    conn1 = get(conn, ~p"/connections/#{Ecto.UUID.generate()}/start")
    assert Phoenix.Flash.get(conn1.assigns.flash, :error) == "Unknown provider."

    # An mcp provider whose server offers no registration has no client yet.
    Req.Test.stub(OAuth, fn req ->
      case req.request_path do
        "/mcp" ->
          Plug.Conn.send_resp(req, 401, "")

        "/.well-known/oauth-protected-resource/mcp" ->
          Req.Test.json(req, %{"authorization_servers" => ["https://auth.example"]})

        "/.well-known/oauth-authorization-server" ->
          Req.Test.json(req, %{
            "issuer" => "https://auth.example",
            "authorization_endpoint" => "https://auth.example/authorize",
            "token_endpoint" => "https://auth.example/token"
          })
      end
    end)

    {:ok, p} = Connections.discover_provider(user.id, "https://mcp.example/mcp")
    assert is_nil(p.client_id)
    conn2 = get(conn, ~p"/connections/#{p.id}/start")
    assert Phoenix.Flash.get(conn2.assigns.flash, :error) =~ "no OAuth client yet"
  end
end
