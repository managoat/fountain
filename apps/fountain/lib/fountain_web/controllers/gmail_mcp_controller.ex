defmodule FountainWeb.GmailMcpController do
  @moduledoc """
  The MCP endpoint a sandbox calls to use a Google connection its agent
  names (#1178). Streamable-HTTP transport: one JSON-RPC message per POST, a
  JSON response back (or 202 for a notification) — the shape of
  `FountainWeb.TeamCommsMcpController`.

  The sandbox authenticates with its callback token, so `current_user` is
  the conversation's owner. This controller checks the conversation is the
  caller's, that its agent still names this connection (an agent edited to
  drop it stops the tools on the next call), and that the connection is the
  same tenant's; `Fountain.Connections.Mcp` resolves the token per call and
  answers `connection revoked` for one the tenant has cut.
  """
  use FountainWeb, :controller

  alias Fountain.{Agents, Audit, Connections, Conversations}
  alias Fountain.Connections.Mcp
  alias Fountain.Connections.McpServers

  def handle(conn, %{"conversation_id" => conv_id, "connection_id" => connection_id}) do
    user = conn.assigns.current_user

    case build_ctx(conv_id, connection_id, user) do
      {:ok, ctx} ->
        case Mcp.handle(conn.body_params, ctx) do
          :noreply -> send_resp(conn, 202, "")
          resp -> json(conn, resp)
        end

      {:error, status, message} ->
        conn |> put_status(status) |> json(%{error: message})
    end
  end

  defp build_ctx(conv_id, connection_id, user) do
    # A runtime path, so it gates on the broker, the way every other one does
    # (`Fountain.Conversations.Egress`). The rollout flag decides who may
    # connect an account, not whether a connection that exists still works:
    # gating this on the flag stopped the tools for a tenant whose flag went
    # off while their token kept being brokered elsewhere (#1693).
    with true <-
           Fountain.Broker.configured?() ||
             {:error, 403, "connections are not available here"},
         %Conversations.Conversation{} = conv <- get_conv(conv_id, user),
         :ok <- agent_names?(conv, connection_id),
         %Connections.Connection{} = connection <-
           Connections.get_connection(connection_id, user.id) || :no_connection,
         :ok <- google_connection?(connection) do
      {:ok, %{connection: connection, audit: audit_fn(connection, conv, user)}}
    else
      :no_conv -> {:error, 404, "conversation not found"}
      :not_named -> {:error, 404, "this conversation's agent does not use that connection"}
      :no_connection -> {:error, 404, "connection not found"}
      {:error, _, _} = err -> err
    end
  end

  # These are Gmail tools: another provider's token (#1299) would be sent to
  # the wrong API and fail confusingly. Its connection attaches by URL + env
  # key instead; say so where the model can read it.
  defp google_connection?(%Connections.Connection{provider: "google"}), do: :ok

  defp google_connection?(_),
    do:
      {:error, 400,
       "these tools serve Google connections only; attach this connection to a " <>
         "remote MCP server or use its brokered env key"}

  defp get_conv(conv_id, user),
    do: Conversations.get_conversation(conv_id, user.id) || :no_conv

  # Ownership established by the scoped get_conversation above: the agent is
  # the conversation's own, fetched to check it still names the connection.
  defp agent_names?(%Conversations.Conversation{agent_id: agent_id}, connection_id)
       when is_binary(agent_id) do
    case Agents._unsafe_get_agent(agent_id) do
      %{mcp_servers: servers} ->
        if connection_id in McpServers.connection_ids(servers), do: :ok, else: :not_named

      _ ->
        :not_named
    end
  end

  defp agent_names?(_conv, _connection_id), do: :not_named

  # A send is an effect, not a tenant-state mutation, so it is audited here
  # rather than in a context. Records that a message went out and how many
  # addresses it went to — never the recipients, subject or body (ADR 0013).
  defp audit_fn(connection, conv, user) do
    fn tool, summary ->
      Audit.record(%{
        user_id: user.id,
        action: "connection.used",
        resource_type: "connection",
        resource_id: connection.id,
        actor: "sprite",
        metadata:
          Map.merge(
            %{"tool" => tool, "provider" => connection.provider, "conversation_id" => conv.id},
            summary
          )
      })
    end
  end
end
