defmodule Fountain.Agents.AgentMcpAuthTest do
  @moduledoc "An agent's MCP entry names a connection under `auth` (ADR 0085)."
  use Fountain.DataCase, async: true

  alias Fountain.Agents.Agent
  alias Fountain.Connections
  alias Fountain.Connections.FakeProvider

  setup do
    FakeProvider.stub()
    user = insert_verified_user()
    {:ok, conn, _} = Connections.create(user.id, %{"url" => FakeProvider.server_url()})
    {:ok, user: user, conn: conn}
  end

  defp changeset(user, entry) do
    Agent.changeset(%Agent{}, %{
      "name" => "a",
      "runtime" => "claude",
      "model" => "anthropic/claude-sonnet-4-5",
      "user_id" => user.id,
      "mcp_servers" => %{"linear" => entry}
    })
  end

  defp entry(conn, overrides \\ %{}) do
    Map.merge(
      %{"type" => "http", "url" => conn.resource, "auth" => %{"connection" => conn.id}},
      overrides
    )
  end

  defp mcp_errors(cs), do: cs |> errors_on() |> Map.get(:mcp_servers, [])

  test "accepts the owner's connection on its own resource", %{user: user, conn: conn} do
    assert mcp_errors(changeset(user, entry(conn))) == []
    # One trailing slash and the host's case do not matter.
    assert mcp_errors(changeset(user, entry(conn, %{"url" => "https://MCP.example.com/mcp/"}))) ==
             []
  end

  test "refuses another account's connection", %{conn: conn} do
    other = insert_verified_user()
    assert [msg] = mcp_errors(changeset(other, entry(conn)))
    assert msg =~ "not a connection on this account"
  end

  test "refuses a URL that is not the connection's resource", %{user: user, conn: conn} do
    for url <- [
          "https://mcp.example.com/other",
          "https://evil.example.com/mcp",
          "http://mcp.example.com/mcp",
          "https://mcp.example.com:8443/mcp"
        ] do
      assert [msg] = mcp_errors(changeset(user, entry(conn, %{"url" => url}))), url
      assert msg =~ "url must be the connection's resource"
    end
  end

  test "refuses a non-http entry, an Authorization header and other auth shapes",
       %{user: user, conn: conn} do
    assert [msg] = mcp_errors(changeset(user, entry(conn, %{"type" => "sse"})))
    assert msg =~ "http server"

    assert [msg] =
             mcp_errors(changeset(user, entry(conn, %{"headers" => %{"authorization" => "x"}})))

    assert msg =~ "remove the header"

    assert [msg] =
             mcp_errors(
               changeset(user, entry(conn, %{"auth" => %{"connection" => conn.id, "x" => 1}}))
             )

    assert msg =~ "auth must be"
  end

  describe ~s["auth": "conversation" (ADR 0086)] do
    test "is accepted on an http or sse entry", %{user: user} do
      for type <- ["http", "sse"] do
        entry = %{"type" => type, "url" => "https://salon.example/mcp", "auth" => "conversation"}
        assert mcp_errors(changeset(user, entry)) == [], type
      end

      # Other headers are the entry's own.
      entry = %{
        "type" => "http",
        "url" => "https://salon.example/mcp",
        "auth" => "conversation",
        "headers" => %{"X-Room" => "r1"}
      }

      assert mcp_errors(changeset(user, entry)) == []
    end

    test "is refused on a stdio entry", %{user: user} do
      for entry <- [
            %{"command" => "npx", "auth" => "conversation"},
            %{"type" => "stdio", "command" => "npx", "auth" => "conversation"}
          ] do
        assert [msg] = mcp_errors(changeset(user, entry))
        assert msg =~ "http or sse server"
      end
    end

    test "is refused beside an Authorization header of the entry's own", %{user: user} do
      entry = %{
        "type" => "http",
        "url" => "https://salon.example/mcp",
        "auth" => "conversation",
        "headers" => %{"authorization" => "Bearer mine"}
      }

      assert [msg] = mcp_errors(changeset(user, entry))
      assert msg =~ "supplies Authorization; remove the header"
    end
  end

  test "the old top-level connection key stays refused", %{user: user, conn: conn} do
    assert [msg] = mcp_errors(changeset(user, %{"connection" => conn.id}))
    assert msg =~ "not a server"
  end

  test "entries without auth are untouched", %{user: user} do
    assert mcp_errors(changeset(user, %{"type" => "http", "url" => "https://x.example/mcp"})) ==
             []

    assert mcp_errors(changeset(user, %{"command" => "npx"})) == []
  end
end
