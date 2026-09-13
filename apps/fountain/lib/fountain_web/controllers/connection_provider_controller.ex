defmodule FountainWeb.ConnectionProviderController do
  @moduledoc """
  Connection providers (#1186): where a tenant's connections get their
  tokens — their own OAuth app at a service, or a remote MCP server whose
  authorization Fountain discovered.

      GET    /api/connection-providers               — the platform providers plus the tenant's own
      POST   /api/connection-providers               — define an `oauth2` provider,
                                                       or discover an `mcp` one from its URL
      GET    /api/connection-providers/:id           — one (`google` is the platform provider)
      PATCH  /api/connection-providers/:id           — edit a tenant provider
      DELETE /api/connection-providers/:id           — delete it and its connections
      POST   /api/connection-providers/:id/discover  — run MCP discovery again

  Every route answers 404 `connections_not_enabled` for an account the broker
  is not on for, like connections themselves. The three routes that define or
  change a provider need the `connections` rollout flag as well; listing one
  and deleting one do not, so an account that already has providers can always
  see them and take them away (#1693). The client secret is write-only.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Connections
  alias Fountain.Connections.Provider
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug :require_connections

  tags(["Connections"])

  operation(:index,
    summary: "List connection providers",
    description:
      "The platform providers (Google, Microsoft, Slack) followed by the " <>
        "tenant's own. Each " <>
        "carries the redirect URI to register at the service and the env var " <>
        "its tokens are brokered under. Only for accounts the egress broker " <>
        "is on for (ADR 0019); 404 otherwise.",
    responses: [
      ok: {"Providers", "application/json", Schemas.ConnectionProviderListResponse},
      not_found:
        {"Connections are not enabled for this account", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :index, providers: Connections.all_providers(user.id))
  end

  operation(:create,
    summary: "Define a connection provider",
    description:
      "`kind: oauth2` takes the tenant's own app registration: authorize and " <>
        "token URLs, scopes, client id and secret. `kind: mcp` takes only " <>
        "`mcp_url`: Fountain fetches the server's protected-resource metadata " <>
        "(RFC 9728), the authorization server's metadata (RFC 8414) and " <>
        "registers a client there (RFC 7591) where it can; pass `client_id` " <>
        "and `client_secret` for a server without registration. Every URL " <>
        "must be https and public.",
    request_body:
      {"Provider", "application/json", Schemas.ConnectionProviderRequest, required: true},
    responses: [
      created: {"Provider", "application/json", Schemas.ConnectionProvider},
      unprocessable_entity: {"Validation or discovery failed", "application/json", Schemas.Error},
      not_found:
        {"Connections are not enabled for this account", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user
    attrs = provider_attrs(params)

    result =
      case attrs do
        %{"kind" => "mcp", "mcp_url" => url} when is_binary(url) ->
          Connections.discover_provider(user.id, url, attrs, Audited.attribution(conn))

        %{"kind" => "mcp"} ->
          {:error, {:discovery, "mcp_url is required for an mcp provider"}}

        _ ->
          Connections.create_provider(user.id, attrs, Audited.attribution(conn))
      end

    case result do
      {:ok, provider} -> conn |> put_status(:created) |> render(:show, provider: provider)
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
      {:error, reason} -> discovery_error(conn, reason)
    end
  end

  operation(:show,
    summary: "Get a connection provider",
    parameters: [id: [in: :path, type: :string, description: "Provider id, or `google`"]],
    responses: [
      ok: {"Provider", "application/json", Schemas.ConnectionProvider},
      not_found: {"Not found", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Connections.get_provider(id, user.id) do
      nil -> {:error, :not_found}
      provider -> render(conn, :show, provider: provider)
    end
  end

  operation(:update,
    summary: "Edit a connection provider",
    description:
      "Any field but `kind`. A blank or absent `client_secret` keeps the " <>
        "stored one. The platform provider cannot be edited.",
    parameters: [id: [in: :path, type: :string, description: "Provider id"]],
    request_body:
      {"Provider", "application/json", Schemas.ConnectionProviderRequest, required: true},
    responses: [
      ok: {"Provider", "application/json", Schemas.ConnectionProvider},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with %Provider{user_id: uid} = provider when is_binary(uid) <-
           Connections.get_provider(id, user.id) || {:error, :not_found},
         {:ok, provider} <-
           Connections.update_provider(
             provider,
             provider_attrs(params),
             Audited.attribution(conn)
           ) do
      render(conn, :show, provider: provider)
    else
      %Provider{} -> {:error, :not_found}
      other -> other
    end
  end

  operation(:delete,
    summary: "Delete a connection provider",
    description:
      "Deletes the provider and every connection on it, revoking each at the " <>
        "provider first (best effort). The platform provider cannot be deleted.",
    parameters: [id: [in: :path, type: :string, description: "Provider id"]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with %Provider{user_id: uid} = provider when is_binary(uid) <-
           Connections.get_provider(id, user.id) || {:error, :not_found},
         {:ok, _} <- Connections.delete_provider(provider, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    else
      %Provider{} -> {:error, :not_found}
      other -> other
    end
  end

  operation(:discover,
    summary: "Run MCP discovery again",
    description:
      "For an `mcp` provider: fetch the server's metadata chain again and " <>
        "update the endpoints. The registered client is kept while the " <>
        "server names the same authorization server.",
    parameters: [id: [in: :path, type: :string, description: "Provider id"]],
    responses: [
      ok: {"Provider", "application/json", Schemas.ConnectionProvider},
      unprocessable_entity: {"Discovery failed", "application/json", Schemas.Error},
      not_found: {"Not found, or not an mcp provider", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def discover(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with %Provider{kind: "mcp"} = provider <-
           Connections.get_provider(id, user.id) || {:error, :not_found} do
      case Connections.rediscover_provider(provider, Audited.attribution(conn)) do
        {:ok, provider} -> render(conn, :show, provider: provider)
        {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
        {:error, reason} -> discovery_error(conn, reason)
      end
    else
      %Provider{} -> {:error, :not_found}
      other -> other
    end
  end

  @fields ~w(slug name kind authorize_url token_url revoke_url userinfo_url account_label_path
             scopes client_id client_secret token_endpoint_auth pkce env_key token_hosts mcp_url)

  defp provider_attrs(params), do: Map.take(params, @fields)

  defp discovery_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "discovery_failed",
      detail: FountainWeb.ConnectionProviderJSON.describe(reason)
    })
  end

  # Defining a provider, editing one and re-running discovery all add a way to
  # get a credential, so they need the rollout flag. Listing and deleting are
  # management of what is already there and ask the broker only (#1693).
  #
  # The plug covers every action, so an action left off this list gets the
  # weaker gate rather than no gate. That default is right for one that reads
  # or removes and wrong for one that creates: an action that adds a way to a
  # credential belongs here in the commit that adds it.
  @creating [:create, :update, :discover]

  defp require_connections(conn, _opts) do
    user_id = conn.assigns.current_user.id

    allowed? =
      if action_name(conn) in @creating,
        do: Fountain.Connections.enabled_for?(user_id),
        else: Fountain.Connections.manageable_for?()

    if allowed? do
      conn
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "connections_not_enabled"})
      |> halt()
    end
  end
end
