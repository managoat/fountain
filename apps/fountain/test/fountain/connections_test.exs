defmodule Fountain.ConnectionsTest do
  use Fountain.DataCase, async: true

  alias Fountain.{Connections, Crypto}
  alias Fountain.Connections.{Connection, Google, McpServers, OAuth, Platform, Provider}

  describe "connect/4" do
    test "stores the grant encrypted, active, under the provider's env key" do
      user = insert_verified_user()
      conn = insert_connection(user, account_email: "me@example.com", refresh_token: "r-1")

      assert conn.provider == "google"
      assert conn.status == "active"
      assert conn.env_key == "GOOGLE_ACCESS_TOKEN"
      assert conn.account_email == "me@example.com"
      refute conn.refresh_token_ciphertext == "r-1"

      {:ok, dek} = Crypto.load_tenant_key(user.id)
      assert {:ok, "r-1"} = Crypto.decrypt(conn.refresh_token_ciphertext, dek)
    end

    test "the same account connected again replaces the tokens and reactivates" do
      user = insert_verified_user()
      Req.Test.stub(OAuth, fn conn -> Req.Test.json(conn, %{}) end)

      first = insert_connection(user, account_email: "me@example.com", refresh_token: "r-1")
      {:ok, revoked} = Connections.revoke(first)
      assert revoked.status == "revoked"

      second = insert_connection(user, account_email: "me@example.com", refresh_token: "r-2")
      assert second.id == first.id
      assert second.status == "active"
      assert is_nil(second.revoked_at)
      assert [_] = Connections.list_connections(user.id)
    end

    test "is tenant-scoped on read" do
      a = insert_verified_user()
      b = insert_verified_user()
      conn = insert_connection(a)

      assert Connections.get_connection(conn.id, a.id)
      refute Connections.get_connection(conn.id, b.id)
      assert Connections.list_connections(b.id) == []
      refute Connections.get_connection("not-a-uuid", a.id)
    end
  end

  describe "access_token/1" do
    test "returns the cached token while it is fresh, without a network call" do
      user = insert_verified_user()
      conn = insert_connection(user, access_token: "a-fresh")
      Req.Test.stub(OAuth, fn _ -> flunk("should not refresh a fresh token") end)

      assert {:ok, "a-fresh"} = Connections.access_token(conn)
    end

    test "refreshes near expiry and caches the new token" do
      user = insert_verified_user()

      conn =
        insert_connection(user,
          access_token: "a-old",
          refresh_token: "r-1",
          expires_at:
            DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
        )

      Req.Test.stub(OAuth, fn req ->
        assert req.request_path == "/token"
        {:ok, body, _} = Plug.Conn.read_body(req)
        params = URI.decode_query(body)
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "r-1"
        Req.Test.json(req, %{"access_token" => "a-new", "expires_in" => 3599})
      end)

      assert {:ok, "a-new"} = Connections.access_token(conn)

      # Cached: the next read does not hit Google.
      Req.Test.stub(OAuth, fn _ -> flunk("second read should be cached") end)
      fresh = Connections.get_connection(conn.id, user.id)
      assert {:ok, "a-new"} = Connections.access_token(fresh)
      assert DateTime.diff(fresh.expires_at, DateTime.utc_now()) > 3000
    end

    test "invalid_grant marks the connection revoked and audits it" do
      user = insert_verified_user()

      conn =
        insert_connection(user,
          expires_at:
            DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)
        )

      Req.Test.stub(OAuth, fn req ->
        req |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, :revoked} = Connections.access_token(conn)
      assert %{status: "revoked"} = Connections.get_connection(conn.id, user.id)

      actions = user.id |> Fountain.Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "connection.revoked" in actions
    end

    test "a revoked connection answers :revoked without a network call" do
      user = insert_verified_user()
      Req.Test.stub(OAuth, fn conn -> Req.Test.json(conn, %{}) end)
      {:ok, revoked} = Connections.revoke(insert_connection(user))
      Req.Test.stub(OAuth, fn _ -> flunk("no call for a revoked connection") end)

      assert {:error, :revoked} = Connections.access_token(revoked)
    end
  end

  describe "revoke/2" do
    test "tells Google to forget the refresh token and marks the row" do
      user = insert_verified_user()
      conn = insert_connection(user, refresh_token: "r-gone")
      test_pid = self()

      Req.Test.stub(OAuth, fn req ->
        {:ok, body, _} = Plug.Conn.read_body(req)
        send(test_pid, {:revoked, req.request_path, URI.decode_query(body)["token"]})
        Req.Test.json(req, %{})
      end)

      assert {:ok, %Connection{status: "revoked", revoked_at: %DateTime{}}} =
               Connections.revoke(conn, actor: "ui")

      assert_received {:revoked, "/revoke", "r-gone"}
    end
  end

  describe "synthetic_secrets/1 and env_keys/1" do
    test "active connections contribute their token under env_key; revoked ones do not" do
      user = insert_verified_user()
      Req.Test.stub(OAuth, fn conn -> Req.Test.json(conn, %{}) end)
      active = insert_connection(user, access_token: "a-live", account_email: "a@example.com")
      {:ok, _} = Connections.revoke(insert_connection(user, account_email: "b@example.com"))

      assert Connections.synthetic_secrets(user.id) == %{"GOOGLE_ACCESS_TOKEN" => "a-live"}

      assert Enum.sort(Connections.env_keys(user.id)) ==
               ["GOOGLE_ACCESS_TOKEN", "GOOGLE_ACCESS_TOKEN_2"]

      assert Connections.implicit_hosts(user.id, active.env_key) == Google.token_hosts()
      assert Connections.implicit_hosts(user.id, "GOOGLE_ACCESS_TOKEN_2") == Google.token_hosts()
      assert Connections.implicit_hosts(user.id, "OTHER") == []
    end
  end

  describe "McpServers.resolve/3" do
    test "rewrites a connection entry into the Fountain-served HTTP server and leaves the rest" do
      id = Ecto.UUID.generate()

      servers = %{
        "gmail" => %{"connection" => id},
        "fs" => %{"command" => "npx", "args" => ["fs-server"]}
      }

      resolved = McpServers.resolve(servers, "conv-1", "tok")

      assert resolved["fs"] == servers["fs"]

      assert %{"type" => "http", "url" => url, "headers" => %{"Authorization" => "Bearer tok"}} =
               resolved["gmail"]

      assert String.ends_with?(url, "/api/mcp/gmail/conv-1/#{id}")
      assert McpServers.connection_ids(servers) == [id]
    end

    test "drops connection entries when there is no token yet" do
      servers = %{"gmail" => %{"connection" => Ecto.UUID.generate()}, "x" => %{"command" => "x"}}
      assert McpServers.resolve(servers, "conv-1", nil) == %{"x" => %{"command" => "x"}}
      assert McpServers.resolve(%{}, "conv-1", "tok") == %{}
    end
  end

  describe "OAuth.authorize_url/3 for Google" do
    test "asks for offline access with a forced consent, so a refresh token comes back" do
      url =
        OAuth.authorize_url(
          Google.provider(),
          "https://f.example/connections/google/callback",
          "st"
        )

      %URI{query: q} = URI.parse(url)
      params = URI.decode_query(q)

      assert params["access_type"] == "offline"
      assert params["prompt"] == "consent"
      assert params["state"] == "st"
      assert params["redirect_uri"] == "https://f.example/connections/google/callback"
      assert params["scope"] =~ "gmail.modify"
      assert params["scope"] =~ "auth/calendar"
    end
  end

  describe "the other platform providers (#1299)" do
    test "a slack exchange lifts authed_user, needs no refresh token, labels via auth.test" do
      slack = Platform.get("slack")

      Req.Test.stub(OAuth, fn conn ->
        case conn.request_path do
          "/api/oauth.v2.access" ->
            Req.Test.json(conn, %{
              "ok" => true,
              "app_id" => "A1",
              "authed_user" => %{
                "id" => "U1",
                "access_token" => "xoxp-99",
                "scope" => "channels:history,chat:write",
                "token_type" => "user"
              }
            })

          "/api/auth.test" ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxp-99"]
            Req.Test.json(conn, %{"ok" => true, "user" => "jake", "team" => "goat"})
        end
      end)

      assert {:ok, grant} = OAuth.exchange_code(slack, "code", "https://f.example/cb")
      assert grant.access_token == "xoxp-99"
      assert grant.refresh_token == nil
      assert grant.expires_at == nil
      assert grant.scopes == ["channels:history", "chat:write"]
      assert grant.account_email == "jake"
    end

    test "a platform provider whose token expires still insists on a refresh token" do
      google = Platform.get("google")

      Req.Test.stub(OAuth, fn conn ->
        Req.Test.json(conn, %{"access_token" => "ya29-1", "expires_in" => 3600})
      end)

      assert {:error, :no_refresh_token} =
               OAuth.exchange_code(google, "code", "https://f.example/cb")
    end

    test "the same label on two platform providers is two connections, not one" do
      user = insert_verified_user()

      # The host's Google and the fixture extension's provider (ADR 0054):
      # an extension's row is a platform provider to this context too.
      google = insert_connection(user, account_email: "me@example.com")
      fixture = insert_connection(user, provider: "fixture-svc", account_email: "me@example.com")

      assert google.id != fixture.id
      assert google.provider_id == nil and fixture.provider_id == nil
      assert fixture.provider == "fixture-svc"
      assert fixture.env_key == "FIXTURE_SVC_ACCESS_TOKEN"
      assert length(Connections.list_connections(user.id)) == 2

      # reconnecting the fixture account replaces the fixture row only
      again = insert_connection(user, provider: "fixture-svc", account_email: "me@example.com")
      assert again.id == fixture.id
      assert length(Connections.list_connections(user.id)) == 2
    end

    test "provider_for and implicit_hosts read the registry through the slug" do
      user = insert_verified_user()
      conn = insert_connection(user, provider: "slack", account_email: "jake")

      assert %Provider{slug: "slack", user_id: nil} = Connections.provider_for(conn)
      assert Connections.implicit_hosts(user.id, "SLACK_ACCESS_TOKEN") == ["slack.com"]
    end
  end

  describe "agent mcp_servers validation" do
    test "a connection entry must carry a connection id" do
      user = insert_verified_user()

      assert {:error, cs} =
               Fountain.Agents.create_agent(
                 agent_attrs(%{
                   "user_id" => user.id,
                   "mcp_servers" => %{"gmail" => %{"connection" => 12}}
                 })
               )

      assert %{mcp_servers: [msg]} = errors_on(cs)
      assert msg =~ "connection id"

      assert {:ok, _} =
               Fountain.Agents.create_agent(
                 agent_attrs(%{
                   "user_id" => user.id,
                   "mcp_servers" => %{"gmail" => %{"connection" => Ecto.UUID.generate()}}
                 })
               )
    end
  end
end
