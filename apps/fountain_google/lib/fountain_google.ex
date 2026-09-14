defmodule FountainGoogle do
  @moduledoc """
  The Gmail tools Fountain serves to a conversation whose agent names a Google
  connection (#1178), as a first-party extension (ADR 0043, #2152).

  The host holds the connection — `Fountain.Connections` runs the OAuth flow,
  keeps the refresh token and mints access tokens — and this extension turns
  it into a capability: an HTTP MCP server at
  `POST /api/mcp/gmail/:conversation_id/:connection_id` whose tools act on the
  mailbox server-side (`FountainGoogle.Mcp` over `FountainGoogle.Gmail`). No
  Google token ever enters the sandbox.

  This module is the one function the seam asks for: which conversations get
  the server, and what the sandbox is told.
  """

  alias Fountain.{Agents, Connections, Conversations}

  @doc """
  The MCP server entries to inject into a conversation's `session/new` so the
  sandboxed agent can use the Gmail tools (ADR 0043 `conversation_mcp_servers/2`).

  One entry per `mcp_servers` entry of the conversation's agent that names a
  connection **and no URL** — the shape `%{"gmail" => %{"connection" => id}}`,
  which the host's `Fountain.Connections.McpServers` no longer rewrites and
  instead leaves for an extension to serve. An entry with a URL is a remote
  server the tenant runs and stays the host's. The connection must be the
  tenant's, `active`, and on the Google platform provider: another provider's
  token would be sent to the wrong API, and its connection attaches by URL and
  brokered env key instead. The server is named after the agent's own key, so
  the model sees the name the agent's author chose.

  Returns `[]` for everything else, including a deployment that does not
  broker egress — the same gate every other runtime path has
  (`Fountain.Broker.configured?/0`), and the one `FountainGoogle.McpController`
  refuses on with a 403, so a server that would only ever answer 403 is not
  handed out. Called on every turn kick, so a connection revoked or an agent
  edited between turns takes effect at the next one.

  Ownership: a system-level call from `ConversationServer`, which established
  ownership of the conversation at provision; the `_unsafe_` fetch is scoped
  again by the tenant-scoped `Agents.get_agent/2` and
  `Connections.get_connection/2` that follow, both against the conversation's
  own `user_id`.
  """
  @spec conversation_mcp_servers(String.t(), String.t()) :: [map()]
  def conversation_mcp_servers(conversation_id, token)
      when is_binary(conversation_id) and is_binary(token) and token != "" do
    with true <- Fountain.Broker.configured?(),
         %Conversations.Conversation{agent_id: agent_id, user_id: user_id}
         when is_binary(agent_id) <- fetch_conv(conversation_id),
         %Agents.Agent{mcp_servers: servers} when is_map(servers) <-
           Agents.get_agent(agent_id, user_id) do
      for {name, %{"connection" => id} = entry} <- servers,
          is_binary(id),
          not is_binary(entry["url"]),
          connection = google_connection(id, user_id),
          do: server(name, conversation_id, connection, token)
    else
      _ -> []
    end
  end

  def conversation_mcp_servers(_conversation_id, _token), do: []

  # A malformed id must yield [] (no tools), not a crash — the cast raises.
  defp fetch_conv(conversation_id) do
    # ownership: system-level call from ConversationServer, which owns the
    # conversation; the agent and connection fetched next are re-scoped by the
    # conversation's user_id, and the result only ever names a server that
    # authenticates with that same conversation's callback token.
    Conversations._unsafe_get_conversation(conversation_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  # `nil` is what a `for` filter needs to skip the entry: a connection that is
  # gone, another tenant's, revoked or expired, or on another provider.
  defp google_connection(id, user_id) do
    case Connections.get_connection(id, user_id) do
      %Connections.Connection{status: "active", provider: "google"} = connection -> connection
      _other -> nil
    end
  end

  defp server(name, conversation_id, %Connections.Connection{id: connection_id}, token) do
    %{
      name: name,
      type: "http",
      url: Fountain.PublicUrl.base() <> "/api/mcp/gmail/#{conversation_id}/#{connection_id}",
      headers: [%{name: "Authorization", value: "Bearer " <> token}]
    }
  end
end
