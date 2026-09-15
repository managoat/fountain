defmodule FountainWeb.VaultSecretController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.{Crypto, Vaults}
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Vault Secrets"])

  operation(:index,
    summary: "List secrets in a vault",
    parameters: [vault_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Vault Secrets", "application/json", Schemas.VaultSecretListResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def index(conn, %{"vault_id" => vault_id}) do
    user = conn.assigns.current_user

    case Vaults.get_vault(vault_id, user.id) do
      nil -> {:error, :not_found}
      # Ownership established by the scoped get_vault above.
      vault -> render(conn, :index, secrets: Vaults._unsafe_list_secrets(vault))
    end
  end

  operation(:create,
    summary: "Upsert a vault secret",
    description:
      "Sets the value for `key`. If the key exists, the value is overwritten. " <>
        "Values are write-only — subsequent reads never return them.",
    parameters: [vault_id: [in: :path, type: :string, required: true]],
    request_body: {"Vault Secret", "application/json", Schemas.VaultSecretRequest},
    responses: [
      created: {"Vault Secret", "application/json", Schemas.VaultSecretResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def create(conn, %{"vault_id" => vault_id} = params) do
    user = conn.assigns.current_user

    case Vaults.get_vault(vault_id, user.id) do
      nil ->
        {:error, :not_found}

      vault ->
        attrs = Map.take(params, ["key", "value", "expires_at"])
        {:ok, dek} = Crypto.load_tenant_key(user.id)

        with {:ok, secret} <- Vaults.upsert_secret(vault, attrs, dek, Audited.attribution(conn)) do
          conn
          |> put_status(:created)
          |> render(:show, secret: secret)
        end
    end
  end

  operation(:update,
    summary: "Update a vault secret's expiry",
    description:
      "Changes expiry without replacing the value. Null clears expiry; omission keeps it. " <>
        "Expiry is advisory and does not revoke the credential.",
    parameters: [
      vault_id: [in: :path, type: :string, required: true],
      id: [in: :path, type: :string, required: true, description: "Secret key."]
    ],
    request_body: {"Secret metadata", "application/json", Schemas.VaultSecretMetadataRequest},
    responses: [
      ok: {"Vault Secret", "application/json", Schemas.VaultSecretResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"vault_id" => vault_id, "id" => key} = params) do
    user = conn.assigns.current_user

    with %_{} = vault <- Vaults.get_vault(vault_id, user.id),
         {:ok, secret} <-
           Vaults.update_secret_metadata(
             vault,
             key,
             Map.take(params, ["expires_at"]),
             Audited.attribution(conn)
           ) do
      render(conn, :show, secret: secret)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  operation(:delete,
    summary: "Delete a vault secret by key",
    parameters: [
      vault_id: [in: :path, type: :string, required: true],
      id: [in: :path, type: :string, required: true, description: "Secret key."]
    ],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"vault_id" => vault_id, "id" => key}) do
    user = conn.assigns.current_user

    with %_{} = vault <- Vaults.get_vault(vault_id, user.id),
         # Ownership established by the scoped get_vault above.
         %_{} = secret <- Vaults._unsafe_get_secret(vault_id, key) do
      {:ok, _} = Vaults.delete_secret(vault, secret, Audited.attribution(conn))

      send_resp(conn, :no_content, "")
    else
      _ -> {:error, :not_found}
    end
  end
end
