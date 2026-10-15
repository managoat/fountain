defmodule FountainWeb.OAuthClientController do
  @moduledoc """
  The OAuth clients an account registered for itself (#1125).

      GET    /api/oauth/clients      — the account's clients
      POST   /api/oauth/clients      — register one
      GET    /api/oauth/clients/:id  — one of them
      PATCH  /api/oauth/clients/:id  — rename it, or change its redirect URIs
      DELETE /api/oauth/clients/:id  — unregister it

  Full scope, for the reason API key management is full scope: a client is a
  standing way to obtain a full-scope key with one consent, so a sandbox's
  per-conversation token must not be able to leave one behind (see
  `Fountain.Accounts.ApiKey`).

  Registering here is enough to *use* the client: it can sign in its owner at
  `/oauth/authorize`, and its redirect origins are admitted by CORS, so no
  operator has to touch `OAUTH_CLIENTS` or `API_CORS_ORIGINS`.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.OAuth
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  tags(["OAuth clients"])

  operation(:index,
    summary: "List OAuth clients",
    description:
      "The OAuth clients this account registered. Each one is in development " <>
        "mode until an operator publishes it, which means it signs in its " <>
        "owner and refuses every other account.",
    responses: [
      ok: {"Clients", "application/json", Schemas.OAuthClientListResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :index, clients: OAuth.list_clients(user.id))
  end

  operation(:create,
    summary: "Register an OAuth client",
    description:
      "Register an app that can offer \"Sign in with Managoat\". The response " <>
        "carries the generated `client_id` to put in the app. Redirect URIs " <>
        "match exactly, must be https unless they are loopback, and a loopback " <>
        "URI matches on any port. The client starts in development mode, so it " <>
        "signs in nobody but you. A sandbox's public HTTPS URL is valid.",
    request_body: {"Client", "application/json", Schemas.OAuthClientRequest, required: true},
    responses: [
      created: {"Client", "application/json", Schemas.OAuthClient},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, client} <-
           OAuth.create_client(user.id, client_attrs(params), Audited.attribution(conn)) do
      conn |> put_status(:created) |> render(:show, client: client)
    end
  end

  operation(:show,
    summary: "Get an OAuth client",
    parameters: [id: [in: :path, type: :string, description: "Client record id"]],
    responses: [
      ok: {"Client", "application/json", Schemas.OAuthClient},
      not_found: {"No such client", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with %{} = client <- OAuth.get_client_record(id, user.id) || {:error, :not_found} do
      render(conn, :show, client: client)
    end
  end

  operation(:update,
    summary: "Change an OAuth client",
    description:
      "Rename the client or replace its redirect URIs. `client_id` never " <>
        "changes. Publishing is not a self-serve operation, and a published " <>
        "client can only be changed by an operator.",
    parameters: [id: [in: :path, type: :string, description: "Client record id"]],
    request_body:
      {"Client changes", "application/json", Schemas.OAuthClientUpdateRequest, required: true},
    responses: [
      ok: {"Client", "application/json", Schemas.OAuthClient},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error},
      not_found: {"No such client", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with %{} = client <- OAuth.get_client_record(id, user.id) || {:error, :not_found},
         {:ok, client} <-
           OAuth.update_client(client, client_attrs(params), Audited.attribution(conn)) do
      render(conn, :show, client: client)
    end
  end

  operation(:delete,
    summary: "Unregister an OAuth client",
    description:
      "Deleting a client stops new sign-ins through it. Keys it already " <>
        "issued are ordinary API keys and outlive it — revoke those under " <>
        "the API keys endpoint. A published client can only be removed by " <>
        "an operator, because every account signs in through it.",
    parameters: [id: [in: :path, type: :string, description: "Client record id"]],
    responses: [
      no_content: "Deleted",
      unprocessable_entity: {"Refused", "application/json", Schemas.Error},
      not_found: {"No such client", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with %{} = client <- OAuth.get_client_record(id, user.id) || {:error, :not_found},
         {:ok, _} <- OAuth.delete_client(client, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  defp client_attrs(params), do: Map.take(params, ~w(name redirect_uris))
end
