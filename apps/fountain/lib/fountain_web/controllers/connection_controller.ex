defmodule FountainWeb.ConnectionController do
  @moduledoc """
  `/api/connections` (ADR 0085): a user's OAuth grants to remote MCP
  servers. Create runs discovery and registration and returns the URL to
  open in a browser signed in to Managoat; the grant lands when the provider
  sends that browser back to `/connections/callback`.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Connections
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  tags(["Connections"])

  @id [id: [in: :path, type: :string, required: true, description: "Connection id."]]

  @auth_errors [
    unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
    forbidden: {"The presented key lacks full scope", "application/json", Schemas.Error}
  ]

  operation(:index,
    summary: "List connections",
    description: "The account's connections, newest first. Never carries a token or a secret.",
    responses:
      [ok: {"Connections", "application/json", Schemas.ConnectionListResponse}] ++ @auth_errors
  )

  def index(conn, _params) do
    render(conn, :index, connections: Connections.list(conn.assigns.current_user.id))
  end

  operation(:create,
    summary: "Connect a remote MCP server",
    description:
      "Discovers the server's authorization server from its URL (the MCP " <>
        "authorization spec), registers a client (a client ID metadata document, " <>
        "dynamic registration, or the client in the request), and stores a " <>
        "`pending` connection. Open `authorize_url` in a browser signed in to " <>
        "Managoat as the same account: the connection becomes `active` when the " <>
        "provider sends that browser back. A `client_required` refusal means the " <>
        "server lets no client register itself: register an app with the provider " <>
        "and send its `client_id` and `client_secret`.",
    request_body:
      {"The server and, when needed, a client", "application/json", Schemas.ConnectionRequest,
       required: true},
    responses:
      [
        created: {"Pending, with the URL to open", "application/json", Schemas.ConnectionLogin},
        conflict:
          {"The server is already connected (`connection_exists`, with `connection_id`)",
           "application/json", Schemas.Error},
        unprocessable_entity:
          {"The URL is not a connectable MCP server, or a client is required", "application/json",
           Schemas.Error}
      ] ++ @auth_errors
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    case Connections.create(user.id, params, Audited.attribution(conn)) do
      {:ok, connection, url} ->
        conn
        |> put_status(:created)
        |> render(:login, connection: connection, authorize_url: url)

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  operation(:show,
    summary: "Get a connection",
    parameters: @id,
    responses:
      [
        ok: {"The connection", "application/json", Schemas.Connection},
        not_found: {"No such connection on this account", "application/json", Schemas.Error}
      ] ++ @auth_errors
  )

  def show(conn, %{"id" => id}) do
    case Connections.get(id, conn.assigns.current_user.id) do
      nil -> {:error, :not_found}
      connection -> render(conn, :show, connection: connection)
    end
  end

  operation(:authorize,
    summary: "Reconnect a connection",
    description:
      "Starts another sign-in on the connection and returns the URL to open, as " <>
        "create does. The grant the connection holds stays in use until the new " <>
        "one replaces it, and is then revoked at the provider.",
    parameters: @id,
    responses:
      [
        ok: {"The URL to open", "application/json", Schemas.ConnectionLogin},
        not_found: {"No such connection on this account", "application/json", Schemas.Error}
      ] ++ @auth_errors
  )

  def authorize(conn, %{"id" => id}) do
    with {:ok, connection, url} <- Connections.authorize(conn.assigns.current_user.id, id) do
      render(conn, :login, connection: connection, authorize_url: url)
    end
  end

  operation(:delete,
    summary: "Disconnect",
    description:
      "Deletes the connection, then revokes its grant at the provider when the " <>
        "provider has a revocation endpoint. A conversation whose agent names it " <>
        "fails its next turn with `connection_reconnect_required`.",
    parameters: @id,
    responses:
      [
        no_content: "Deleted",
        not_found: {"No such connection on this account", "application/json", Schemas.Error}
      ] ++ @auth_errors
  )

  def delete(conn, %{"id" => id}) do
    with :ok <- Connections.delete(conn.assigns.current_user.id, id, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  defp refuse(conn, {:connection_exists, id} = reason) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "connection_exists",
      message: Connections.error_message(reason),
      connection_id: id
    })
  end

  defp refuse(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: code(reason), message: Connections.error_message(reason)})
  end

  defp code(:invalid_url), do: "invalid_url"
  defp code(:invalid_authorize_params), do: "invalid_authorize_params"
  defp code(:client_required), do: "client_required"
  defp code({:unsafe_url, _, _}), do: "unsafe_url"
  defp code({:registration, _, _}), do: "registration_failed"
  defp code(_), do: "discovery_failed"
end
