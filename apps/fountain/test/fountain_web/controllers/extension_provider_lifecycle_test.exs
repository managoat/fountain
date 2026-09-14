defmodule FountainWeb.ExtensionProviderLifecycleTest do
  # Extension removal is global state; these lifecycle tests run serially.
  use FountainWeb.ConnCase, async: false

  import Fountain.BrokerTestHelpers
  import Phoenix.LiveViewTest

  alias Fountain.Connections
  alias Fountain.Connections.{OAuth, Platform, Provider}
  alias Fountain.Conversations.Egress

  defmodule McpExtension do
    @moduledoc false
    use Fountain.Extension, id: :fixture_mcp_provider

    @impl true
    def connection_providers do
      [provider] = Fountain.ExtensionFixtures.Enabled.connection_providers()

      [
        %{
          provider
          | id: "fixture-mcp",
            slug: "fixture-mcp",
            kind: "mcp",
            mcp_url: "https://svc.fixture.example/mcp"
        }
      ]
    end
  end

  setup do
    previous = Application.get_env(:fountain, :extensions, [])
    on_exit(fn -> Application.put_env(:fountain, :extensions, previous) end)
    enable_connections()
    :ok
  end

  test "removing an extension with fresh and stale grants omits its credentials and permits local cleanup" do
    user = insert_verified_user()
    other = insert_verified_user()
    # A tenant's own provider survives any extension coming or going; it is
    # the connection that must keep working when the fixture's is gone.
    retained =
      insert_connection(user, provider: insert_provider(user), access_token: "retained-token")

    other_connection = insert_connection(other)

    connections =
      for expires_at <- [
            nil,
            DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
          ] do
        {:ok, connection} =
          Connections.connect(user.id, Platform.get("fixture-svc"), %{
            account_email: Ecto.UUID.generate(),
            access_token: "extension-token",
            refresh_token: "extension-refresh",
            expires_at: expires_at
          })

        connection
      end

    [fresh, stale] = connections
    assert {:ok, "extension-token"} = Connections.access_token(fresh)
    assert Connections.implicit_hosts(user.id, fresh.env_key) == ["svc.fixture.example"]

    Application.put_env(:fountain, :extensions, [])

    Req.Test.stub(OAuth, fn _ ->
      flunk("unavailable providers must not receive OAuth requests")
    end)

    for connection <- connections do
      assert Connections.provider_for(connection) == nil
      assert {:error, :provider_unavailable} = Connections.access_token(connection)
      assert Connections.implicit_hosts(user.id, connection.env_key) == []
      assert Egress.connection_bindings(user.id, connection.env_key, %{}) == []
    end

    assert Connections.synthetic_secrets(user.id) == %{retained.env_key => "retained-token"}

    agent = %{
      mcp_servers: %{
        "remote" => %{
          "type" => "http",
          "url" => "https://remote.example/mcp",
          "connection" => fresh.id
        }
      }
    }

    assert {secrets, bindings, [key]} = Egress.add_connection_secrets(user.id, %{}, %{}, agent)
    assert key == retained.env_key
    assert secrets == %{key => "retained-token"}
    assert Map.keys(bindings) == [key]
    assert Connections.get_connection(other_connection.id, user.id) == nil

    assert {:ok, %{status: "revoked"}} = Connections.revoke(fresh)
    assert %{status: "revoked"} = Connections.get_connection(fresh.id, user.id)
    assert {:ok, _} = Connections.delete(stale)
    assert Connections.get_connection(stale.id, user.id) == nil
    assert %{status: "active"} = Connections.get_connection(other_connection.id, other.id)
  end

  test "config-backed MCP providers reject context, API and forged LiveView rediscovery", %{
    conn: conn
  } do
    Application.put_env(:fountain, :extensions, [McpExtension])
    user = insert_verified_user()
    {:ok, {_key, raw}} = Fountain.Accounts.create_api_key(user.id, "test")
    provider = Connections.get_provider("fixture-mcp", user.id)
    assert %Provider{kind: "mcp", user_id: nil} = provider
    Req.Test.stub(OAuth, fn _ -> flunk("config-backed providers must not run discovery") end)

    assert {:error, :not_found} = Connections.rediscover_provider(provider)

    assert %{"error" => "not_found"} =
             conn
             |> authed_with_key(raw)
             |> put_req_header("accept", "application/json")
             |> post("/api/connection-providers/fixture-mcp/discover")
             |> json_response(404)

    {:ok, view, _html} = conn |> login_user(user) |> live(~p"/account/connections")
    assert render_click(view, "rediscover", %{"id" => "fixture-mcp"}) =~ "That provider is gone."
    assert Connections.list_providers(user.id) == []
  end
end
