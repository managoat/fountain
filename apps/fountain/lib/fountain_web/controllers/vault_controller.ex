defmodule FountainWeb.VaultController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Vaults
  alias Fountain.Vaults.Vault
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Vaults"])

  operation(:index,
    summary: "List vaults",
    responses: [
      ok: {"Vaults", "application/json", Schemas.VaultListResponse}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :index, vaults: Vaults.list_vaults_with_counts(user.id))
  end

  operation(:show,
    summary: "Get a vault",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Vault", "application/json", Schemas.VaultResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Vaults.get_vault_with_counts(id, user.id) do
      nil -> {:error, :not_found}
      vault -> render(conn, :show, vault: vault)
    end
  end

  operation(:create,
    summary: "Create a vault",
    request_body: {"Vault attributes", "application/json", Schemas.VaultRequest},
    responses: [
      created: {"Vault", "application/json", Schemas.VaultResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.put(params, "user_id", user.id)

    with {:ok, %Vault{} = vault} <- Vaults.create_vault(attrs, Audited.attribution(conn)) do
      conn
      |> put_status(:created)
      |> render(:show, vault: Vaults.get_vault_with_counts(vault.id, user.id))
    end
  end

  operation(:update,
    summary: "Update a vault (partial)",
    description: "Every field is optional; the server merges into the existing record.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Partial vault attributes", "application/json", Schemas.VaultUpdate},
    responses: [
      ok: {"Vault", "application/json", Schemas.VaultResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    attrs = params |> Map.delete("id") |> Map.delete("user_id")

    case Vaults.get_vault(id, user.id) do
      nil ->
        {:error, :not_found}

      vault ->
        with {:ok, vault} <- Vaults.update_vault(vault, attrs, Audited.attribution(conn)) do
          # Re-read for the counts: a response that advertises secret_count
          # must not report the struct default after a write.
          render(conn, :show, vault: Vaults.get_vault_with_counts(vault.id, user.id))
        end
    end
  end

  operation(:delete,
    summary: "Delete a vault",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict:
        {"An agent is mid-turn on a persistent sandbox built on this vault", "application/json",
         Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Vaults.get_vault(id, user.id) do
      nil ->
        {:error, :not_found}

      vault ->
        with {:ok, _} <- Vaults.delete_vault(vault, Audited.attribution(conn)) do
          send_resp(conn, :no_content, "")
        end
    end
  end
end
