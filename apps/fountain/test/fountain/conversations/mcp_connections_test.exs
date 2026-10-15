defmodule Fountain.Conversations.McpConnectionsTest do
  @moduledoc """
  A connection's token on its way to a remote MCP server (ADR 0085): the
  entry rewrite, the broker's custody, the turn gate and the in-turn refresh.
  `async: false`: `Fountain.Broker` is stubbed globally, as in the egress tests.
  """
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.{Broker, Connections}
  alias Fountain.Connections.{Connection, FakeProvider}
  alias Fountain.Conversations.{Egress, McpConnections, Redaction}
  alias Fountain.Repo

  setup do
    user = insert_verified_user()
    {:ok, user: user}
  end

  test "rewrite makes a connection entry an HTTP server with the bearer placeholder" do
    id = Ecto.UUID.generate()

    agent = %{
      mcp_servers: %{
        "linear" => %{
          "type" => "http",
          "url" => "https://mcp.example.com/mcp",
          "headers" => %{"authorization" => "Bearer smuggled", "X-Other" => "kept"},
          "auth" => %{"connection" => id}
        },
        "local" => %{"command" => "npx", "args" => ["x"]}
      }
    }

    assert [%{id: ^id, host: "mcp.example.com", key: key}] = McpConnections.refs(agent)
    assert Connections.reserved_key?(key)

    rewritten = McpConnections.rewrite(agent)
    linear = rewritten.mcp_servers["linear"]
    refute Map.has_key?(linear, "auth")

    assert linear["headers"] == %{
             "Authorization" => "Bearer " <> Broker.placeholder(key),
             "X-Other" => "kept"
           }

    assert rewritten.mcp_servers["local"] == agent.mcp_servers["local"]

    assert [%{name: "linear", headers: headers} | _] =
             Managoat.Runtimes.ACP.mcp_servers(rewritten)

    assert %{name: "Authorization", value: "Bearer __managoat_connection_" <> _} =
             Enum.find(headers, &(&1.name == "Authorization"))
  end

  test "attach gives the broker the token and a bearer binding to that host only", %{user: user} do
    FakeProvider.stub()
    conn = connect!(user)
    [ref] = McpConnections.refs(agent_for(conn))

    {brokered, bindings, expiries} = McpConnections.attach(user.id, [ref], %{"A" => "b"}, %{})

    assert brokered == %{"A" => "b", ref.key => "access-1"}
    assert [%{host: "mcp.example.com", auth_type: "bearer", key: key}] = bindings[ref.key]
    assert key == ref.key
    assert %DateTime{} = expiries[conn.id]

    assert :ok = McpConnections.gate(user.id, [ref])
  end

  test "an unusable connection is not brokered and refuses the turn", %{user: user} do
    FakeProvider.stub()
    {:ok, pending, _} = Connections.create(user.id, %{"url" => FakeProvider.server_url()})
    [ref] = McpConnections.refs(agent_for(pending))
    id = pending.id

    {brokered, bindings, _} = McpConnections.attach(user.id, [ref], %{}, %{})
    assert brokered == %{}
    assert Map.has_key?(bindings, ref.key)

    assert {:error, {:connection_reconnect_required, ^id}} = McpConnections.gate(user.id, [ref])

    # Another account's id is no better.
    other = insert_verified_user()
    assert {:error, {:connection_reconnect_required, _}} = McpConnections.gate(other.id, [ref])
  end

  test "next_refresh_ms is ten minutes before the earliest expiry" do
    assert McpConnections.next_refresh_ms(%{}) == nil
    assert McpConnections.next_refresh_ms(%{"a" => nil}) == nil

    in_an_hour = DateTime.add(DateTime.utc_now(), 3600)

    ms =
      McpConnections.next_refresh_ms(%{"a" => in_an_hour, "b" => DateTime.add(in_an_hour, 600)})

    assert_in_delta ms, 50 * 60_000, 2_000

    # Already due: retried soon rather than never.
    assert McpConnections.next_refresh_ms(%{"a" => DateTime.utc_now()}) == 30_000
  end

  describe "during a turn" do
    setup %{user: user} do
      FakeProvider.stub()
      conn = connect!(user)
      [ref] = McpConnections.refs(agent_for(conn))
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      c = insert_conversation(user_id: user.id)
      on_exit(fn -> Redaction.delete(c.id) end)

      {brokered, bindings, expiries} = McpConnections.attach(user.id, [ref], %{}, %{})
      # An hour left: nothing refreshed yet.
      assert brokered[ref.key] == "access-1"

      state = %{
        conversation_id: c.id,
        user_id: user.id,
        tenant_key: dek,
        broker: %{
          vault: "c-test",
          token: "av_live",
          expires_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        brokered: brokered,
        tenant_keys: [],
        secret_sources: nil,
        broker_bindings: bindings,
        inference_credentials: %{},
        broker_network: :unrestricted,
        sprite_env: [],
        connections: [ref],
        connection_expiries: expiries,
        connection_timer: nil
      }

      {:ok, state: state, ref: ref, conn: conn}
    end

    test "a token near its expiry is refreshed and reaches the live rules", %{
      state: state,
      ref: ref
    } do
      test = self()

      stub(Broker, :refresh, fn _conv, brokered, bindings, _opts ->
        send(test, {:rules, brokered, bindings})
        {:ok, 1}
      end)

      stub(Broker, :prepare, fn _, _, _, _ -> flunk("a live rewrite needs no new session") end)

      # The stored token expires within ten minutes, so the reread refreshes it.
      Repo.update_all(
        from(c in Connection, where: c.id == ^ref.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), 120) |> DateTime.truncate(:second)]
      )

      next = Egress.refresh_live(state)

      assert "access-r" <> _ = token = next.brokered[ref.key]
      assert_receive {:rules, %{} = brokered, bindings}
      assert brokered[ref.key] == token
      assert [%{auth_type: "bearer", host: "mcp.example.com"}] = bindings[ref.key]

      assert Redaction.redact(state.conversation_id, "echo #{token}") == "echo [REDACTED]"

      next = McpConnections.schedule(next)
      assert is_reference(next.connection_timer)
      Process.cancel_timer(next.connection_timer)
    end

    test "nothing moved, nothing rewritten", %{state: state} do
      stub(Broker, :refresh, fn _, _, _, _ -> flunk("nothing moved") end)
      assert Egress.refresh_live(state) == state
    end
  end

  test "the API answers a refused turn with 409 and the connection's id" do
    id = Ecto.UUID.generate()

    conn =
      Phoenix.ConnTest.build_conn()
      |> FountainWeb.FallbackController.call({:error, {:connection_reconnect_required, id}})

    assert conn.status == 409

    assert %{"error" => "connection_reconnect_required", "connection_id" => ^id} =
             Jason.decode!(conn.resp_body)
  end

  defp connect!(user) do
    {:ok, _pending, url} = Connections.create(user.id, %{"url" => FakeProvider.server_url()})
    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
    {:ok, conn} = Connections.complete(user.id, %{"state" => state, "code" => "good-code"})
    conn
  end

  defp agent_for(conn) do
    %{
      mcp_servers: %{
        "linear" => %{
          "type" => "http",
          "url" => conn.resource,
          "auth" => %{"connection" => conn.id}
        }
      }
    }
  end
end
