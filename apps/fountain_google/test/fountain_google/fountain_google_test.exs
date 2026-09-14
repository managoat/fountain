defmodule FountainGoogleTest do
  @moduledoc """
  Which conversations get the Gmail server, and what the sandbox is told
  (ADR 0043 `conversation_mcp_servers/2`, #2152).

  The host used to rewrite a connection-only `mcp_servers` entry into this
  server itself (`Fountain.Connections.McpServers.resolve/4`). It no longer
  knows the shape; the entry reaches a turn through the seam or not at all,
  so the last test here goes through `Fountain.Extensions` rather than
  calling this module directly.
  """
  # Turns the broker on and off (global app env).
  use Fountain.DataCase, async: false

  import Fountain.BrokerTestHelpers

  alias Fountain.Connections
  alias Fountain.Connections.OAuth

  setup do
    enable_broker()
    user = insert_verified_user()
    connection = insert_connection(user, account_email: "me@example.com")
    %{user: user, connection: connection}
  end

  defp conversation(user, mcp_servers) do
    agent = insert_agent(user_id: user.id, mcp_servers: mcp_servers)
    insert_conversation(%{user_id: user.id, agent: agent, status: "idle"})
  end

  test "a connection-only entry becomes the Gmail server, named after the agent's key", ctx do
    conv = conversation(ctx.user, %{"mail" => %{"connection" => ctx.connection.id}})

    assert [server] = FountainGoogle.conversation_mcp_servers(conv.id, "cb-token")

    assert server == %{
             name: "mail",
             type: "http",
             url:
               Fountain.PublicUrl.base() <>
                 "/api/mcp/gmail/#{conv.id}/#{ctx.connection.id}",
             headers: [%{name: "Authorization", value: "Bearer cb-token"}]
           }
  end

  test "an entry with a URL is the host's remote server and gets nothing here", ctx do
    conv =
      conversation(ctx.user, %{
        "remote" => %{
          "type" => "http",
          "url" => "https://mcp.example/sse",
          "connection" => ctx.connection.id
        },
        "plain" => %{"command" => "npx"}
      })

    assert FountainGoogle.conversation_mcp_servers(conv.id, "cb-token") == []
  end

  test "a connection that is not active, not Google, or not the tenant's is skipped", ctx do
    Req.Test.stub(OAuth, fn req -> Req.Test.json(req, %{}) end)
    {:ok, revoked} = Connections.revoke(insert_connection(ctx.user, account_email: "r@x.test"))
    # Another platform provider's connection: the fixture extension's, since
    # Slack and Microsoft are extensions of their own now and are not loaded
    # in this suite (#2152).
    other = insert_connection(ctx.user, provider: "fixture-svc", account_email: "jake")
    theirs = insert_connection(insert_verified_user())

    conv =
      conversation(ctx.user, %{
        "revoked" => %{"connection" => revoked.id},
        "other" => %{"connection" => other.id},
        "theirs" => %{"connection" => theirs.id},
        "gone" => %{"connection" => Ecto.UUID.generate()},
        "gmail" => %{"connection" => ctx.connection.id}
      })

    assert [%{name: "gmail"}] = FountainGoogle.conversation_mcp_servers(conv.id, "cb-token")
  end

  test "nothing without a broker, a token, an agent or a real conversation", ctx do
    conv = conversation(ctx.user, %{"gmail" => %{"connection" => ctx.connection.id}})

    assert FountainGoogle.conversation_mcp_servers(conv.id, "") == []
    assert FountainGoogle.conversation_mcp_servers(conv.id, nil) == []
    assert FountainGoogle.conversation_mcp_servers("not-a-uuid", "cb-token") == []
    assert FountainGoogle.conversation_mcp_servers(Ecto.UUID.generate(), "cb-token") == []

    agentless = insert_conversation(%{user_id: ctx.user.id, agent: nil, status: "idle"})
    assert FountainGoogle.conversation_mcp_servers(agentless.id, "cb-token") == []

    disable_broker()
    assert FountainGoogle.conversation_mcp_servers(conv.id, "cb-token") == []
  end

  test "the server reaches a turn through the seam, ahead of the host's own", ctx do
    conv = conversation(ctx.user, %{"gmail" => %{"connection" => ctx.connection.id}})

    # `Fountain.Extensions` fans out to every installed extension; this one
    # must be among them here, or the assertion below is about the fixtures.
    assert FountainGoogle.Extension in Fountain.Extensions.installed()

    servers = Fountain.Extensions.conversation_mcp_servers(conv.id, "cb-token")

    assert [%{name: "gmail", url: url}] = Enum.filter(servers, &(&1.name == "gmail"))
    assert url =~ "/api/mcp/gmail/#{conv.id}/#{ctx.connection.id}"

    # And `Conversations.McpServers.fountain_served/2` — what `session/new`
    # is built from — carries it, which is the whole point of the callback:
    # the host stopped writing this server and did not lose it.
    served = Fountain.Conversations.McpServers.fountain_served(conv, "cb-token")
    assert Enum.any?(served, &(&1.name == "gmail"))
  end
end
