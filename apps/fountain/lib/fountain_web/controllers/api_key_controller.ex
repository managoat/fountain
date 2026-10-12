defmodule FountainWeb.ApiKeyController do
  @moduledoc """
  API key issuance, listing, and revocation for the authenticated user.

  GET    /api/auth/api-keys      — list active keys (never returns key material)
  POST   /api/auth/api-keys      — create a new key (returns plaintext once)
  DELETE /api/auth/api-keys/:id  — revoke a key
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Accounts
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  tags(["Auth"])

  operation(:index,
    summary: "List active API keys",
    description:
      "Metadata only — key material is returned once, at creation, and is not " <>
        "recoverable. Most of a busy tenant's list is auto-issued " <>
        "`sprite:<conversation_id>` tokens; `scopes` and `expires_at` are what " <>
        "tell those apart from a key a person minted.",
    responses: [
      ok: {"Active keys", "application/json", Schemas.ApiKeyListResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden:
        {"The presented key lacks key-management scope", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :index, keys: Accounts.list_api_keys(user.id))
  end

  operation(:create,
    summary: "Mint an API key",
    description:
      "The response is the only time the plaintext key is available. A key " <>
        "minted here carries `full` scope, so it can do everything the " <>
        "presenting key can — including minting more.",
    request_body: {"Key name", "application/json", Schemas.ApiKeyRequest, required: true},
    responses: [
      created: {"The new key, with plaintext", "application/json", Schemas.ApiKeyCreatedResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden:
        {"The presented key lacks key-management scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Missing or invalid name", "application/json", Schemas.Error}
    ]
  )

  def create(conn, %{"name" => name}) when is_binary(name) and name != "" do
    user = conn.assigns.current_user

    case Accounts.create_api_key(user.id, name, Audited.attribution(conn)) do
      {:ok, {key_record, raw_key}} ->
        conn
        |> put_status(:created)
        |> render(:created, key: key_record, raw_key: raw_key)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(FountainWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "name is required"})
  end

  operation(:delete,
    summary: "Revoke an API key",
    description:
      "Immediate — the key stops authenticating on the next request. Revoking " <>
        "the key you are presenting is allowed and is the last thing that key does.",
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Key id."]
    ],
    responses: [
      no_content: "Revoked",
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden:
        {"The presented key lacks key-management scope", "application/json", Schemas.Error},
      not_found: {"No such key on this account", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Accounts.revoke_api_key(user.id, id, Audited.attribution(conn)) do
      {:ok, _key} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "API key not found"})
    end
  end
end
