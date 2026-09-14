defmodule Fountain.ConnectionsTest do
  use Fountain.DataCase, async: true

  alias Fountain.{Connections, Crypto}
  alias Fountain.Connections.{Connection, McpServers, OAuth, Platform, Provider}

  describe "connect/4" do
    test "stores the grant encrypted, active, under the provider's env key" do
      user = insert_verified_user()
      conn = insert_connection(user, account_email: "me@example.com", refresh_token: "r-1")

      assert conn.provider == "fixture-svc"
      assert conn.status == "active"
      assert conn.env_key == "FIXTURE_SVC_ACCESS_TOKEN"
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

    test "database uniqueness follows provider identity even when a tenant slug changes" do
      user = insert_verified_user()
      tenant_provider = insert_provider(user)
      {:ok, dek} = Crypto.load_tenant_key(user.id)

      for {provider, index} <- [
            {"fixture-svc", "connections_platform_account_index"},
            {tenant_provider, "connections_tenant_provider_account_index"}
          ] do
        existing = insert_connection(user, provider: provider)

        attrs = %{
          user_id: user.id,
          provider: if(existing.provider_id, do: "renamed", else: existing.provider),
          provider_id: existing.provider_id,
          account_email: existing.account_email,
          env_key: "DUPLICATE_GRANT",
          access_token: "duplicate"
        }

        assert {:error, changeset} =
                 %Connection{}
                 |> Connection.changeset(attrs, dek)
                 |> Repo.insert(mode: :savepoint)

        assert {"has already been taken", metadata} = changeset.errors[:user_id]
        assert metadata[:constraint_name] == index
      end
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
        assert req.request_path == "/oauth/token"
        {:ok, body, _} = Plug.Conn.read_body(req)
        params = URI.decode_query(body)
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "r-1"
        Req.Test.json(req, %{"access_token" => "a-new", "expires_in" => 3599})
      end)

      assert {:ok, "a-new"} = Connections.access_token(conn)

      # Cached: the next read does not hit the provider.
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
    test "tells the provider to forget the refresh token and marks the row" do
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

      assert_received {:revoked, "/oauth/revoke", "r-gone"}
    end
  end

  describe "synthetic_secrets/1 and env_keys/1" do
    test "active connections contribute their token under env_key; revoked ones do not" do
      user = insert_verified_user()
      Req.Test.stub(OAuth, fn conn -> Req.Test.json(conn, %{}) end)
      active = insert_connection(user, access_token: "a-live", account_email: "a@example.com")
      {:ok, _} = Connections.revoke(insert_connection(user, account_email: "b@example.com"))

      assert Connections.synthetic_secrets(user.id) == %{"FIXTURE_SVC_ACCESS_TOKEN" => "a-live"}

      assert Enum.sort(Connections.env_keys(user.id)) ==
               ["FIXTURE_SVC_ACCESS_TOKEN", "FIXTURE_SVC_ACCESS_TOKEN_2"]

      assert Connections.implicit_hosts(user.id, active.env_key) == ["svc.fixture.example"]

      assert Connections.implicit_hosts(user.id, "FIXTURE_SVC_ACCESS_TOKEN_2") ==
               ["svc.fixture.example"]

      assert Connections.implicit_hosts(user.id, "OTHER") == []
    end
  end

  describe "McpServers.resolve/4" do
    # A connection entry with no URL is an extension's to serve (ADR 0043,
    # #2152): core drops it whether or not it holds a callback token, and never
    # builds a `/api/mcp/...` URL for it. The Google extension's own suite
    # proves the server still reaches a turn, through
    # `conversation_mcp_servers/2`.
    test "drops a connection entry with no URL and leaves the rest" do
      id = Ecto.UUID.generate()

      servers = %{
        "gmail" => %{"connection" => id},
        "fs" => %{"command" => "npx", "args" => ["fs-server"]}
      }

      assert McpServers.resolve(servers, "conv-1", "tok") == %{"fs" => servers["fs"]}
      assert McpServers.resolve(servers, "conv-1", nil) == %{"fs" => servers["fs"]}
      assert McpServers.resolve(%{}, "conv-1", "tok") == %{}

      # The id is still the agent's to name: the extension's controller checks
      # the agent names the connection through this.
      assert McpServers.connection_ids(servers) == [id]
    end
  end

  describe "the platform providers (#1299, ADR 0054)" do
    test "a platform provider whose token expires still insists on a refresh token" do
      # Google's rule, kept by every config-backed provider (`user_id: nil`):
      # a repeat consent without a refresh token would be dead in an hour.
      platform = Platform.get("fixture-svc")

      Req.Test.stub(OAuth, fn conn ->
        Req.Test.json(conn, %{"access_token" => "ya29-1", "expires_in" => 3600})
      end)

      assert {:error, :no_refresh_token} =
               OAuth.exchange_code(platform, "code", "https://f.example/cb")
    end

    test "the same label on a platform provider and a tenant's is two connections, not one" do
      user = insert_verified_user()

      # The fixture extension's provider (ADR 0054) and the tenant's own
      # oauth2 provider: the label is scoped by provider, never global.
      own = insert_provider(user)
      tenant = insert_connection(user, provider: own, account_email: "me@example.com")
      fixture = insert_connection(user, provider: "fixture-svc", account_email: "me@example.com")

      assert tenant.id != fixture.id
      assert tenant.provider_id == own.id and fixture.provider_id == nil
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
      conn = insert_connection(user, provider: "fixture-svc", account_email: "jake")

      assert %Provider{slug: "fixture-svc", user_id: nil} = Connections.provider_for(conn)

      assert Connections.implicit_hosts(user.id, "FIXTURE_SVC_ACCESS_TOKEN") ==
               ["svc.fixture.example"]
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
