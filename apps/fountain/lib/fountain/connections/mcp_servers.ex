defmodule Fountain.Connections.McpServers do
  @moduledoc """
  How a connection is named in an agent's `mcp_servers`, and how that entry
  becomes the server the sandbox actually talks to (#1178, #1186).

  The shape core serves is a **remote server the tenant supplies**, naming a
  connection instead of a token:

      %{"linear" => %{"type" => "http", "url" => "https://mcp.linear.app/mcp",
                      "connection" => "<connection id>"}}

  At spawn, `resolve/4` keeps its URL and gives it
  `Authorization: Bearer <placeholder>` for the connection's `env_key`. The
  placeholder is the same one the sandbox's environment holds, so the broker
  attaches the real token to that host (`remote_hosts/2` is the implicit
  bearer binding the conversation adds), and a rotated token is re-uploaded
  at each turn kick. No token enters the sandbox.

  An entry with a connection and **no URL** is an extension's to serve
  (ADR 0043 `conversation_mcp_servers/2`, #2152):

      %{"gmail" => %{"connection" => "<connection id>"}}

  Core does not know what such an entry means. `resolve/4` drops it, so the
  agent's own list never carries a half-built server, and an installed
  extension that recognises the connection's provider hands the sandbox an
  HTTP server of its own at every turn kick — authenticated by the
  conversation's callback token, which the sandbox already holds. On a
  deployment without that extension the agent runs without the server.

  The remote shape is the same thing a tenant would write for any remote MCP
  server, so it flows through `.mcp.json` (claude) and `session/new`
  (everyone else) without a new contract.
  """

  alias Fountain.Broker

  @doc "True for the remote-server shape: a URL of the tenant's plus a connection."
  def remote_entry?(%{"connection" => id, "url" => url}) when is_binary(id) and is_binary(url),
    do: true

  def remote_entry?(_), do: false

  @doc "The connection ids an agent's `mcp_servers` names."
  def connection_ids(nil), do: []

  def connection_ids(mcp_servers) when is_map(mcp_servers) do
    for {_name, %{"connection" => id}} <- mcp_servers, is_binary(id), uniq: true, do: id
  end

  @doc """
  Rewrite every remote connection entry into the HTTP server the sandbox
  calls, and drop every connection entry that has no URL.

  `connections` maps a connection id to its `%Connection{}` (active ones
  only; the caller fetched them tenant-scoped). A remote entry whose
  connection is unknown or not active is dropped, and the agent runs without
  that server. A connection entry with no URL is dropped whatever the
  connections say: it is an extension's to serve, not this module's (see the
  moduledoc). Every other entry passes through untouched.

  `conversation_id` and `token` are accepted for the callers that have them
  and are not read: nothing core builds here needs the conversation's
  callback token any more.
  """
  def resolve(mcp_servers, conversation_id, token, connections \\ %{})

  def resolve(mcp_servers, _conversation_id, _token, _connections)
      when not is_map(mcp_servers) or map_size(mcp_servers) == 0,
      do: mcp_servers

  def resolve(mcp_servers, _conversation_id, _token, connections) when is_map(mcp_servers) do
    Enum.reduce(mcp_servers, %{}, fn
      {name, %{"connection" => id, "url" => url} = entry}, acc
      when is_binary(id) and is_binary(url) ->
        case Map.get(connections, id) do
          %{env_key: key} -> Map.put(acc, name, remote_server(entry, key))
          _ -> acc
        end

      {_name, %{"connection" => id}}, acc when is_binary(id) ->
        acc

      {name, entry}, acc ->
        Map.put(acc, name, entry)
    end)
  end

  @doc """
  The implicit bearer bindings the remote entries need: `%{env_key =>
  [host]}`, one host per server URL, for the connections the entries name.
  """
  def remote_hosts(mcp_servers, connections) when is_map(mcp_servers) and is_map(connections) do
    mcp_servers
    |> Enum.filter(fn {_name, entry} -> remote_entry?(entry) end)
    |> Enum.reduce(%{}, fn {_name, %{"connection" => id, "url" => url}}, acc ->
      case {Map.get(connections, id), URI.parse(url).host} do
        {%{env_key: key}, host} when is_binary(host) and host != "" ->
          Map.update(acc, key, [host], &Enum.uniq([host | &1]))

        _ ->
          acc
      end
    end)
  end

  def remote_hosts(_, _), do: %{}

  # The tenant's entry, minus the connection it named, plus the bearer the
  # broker will replace. A header the tenant set themselves is kept.
  defp remote_server(entry, env_key) do
    headers =
      (entry["headers"] || %{})
      |> Map.put_new("Authorization", "Bearer " <> Broker.placeholder(env_key))

    entry
    |> Map.delete("connection")
    |> Map.put_new("type", "http")
    |> Map.put("headers", headers)
  end
end
