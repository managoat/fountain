defmodule FountainWeb.SecretController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.{Crypto, Environments}
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Secrets"])

  operation(:index,
    summary: "List secrets in an environment",
    parameters: [environment_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Secrets", "application/json", Schemas.SecretListResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def index(conn, %{"environment_id" => env_id}) do
    case Environments.get_environment(env_id, conn.assigns.current_user.id) do
      nil -> {:error, :not_found}
      # Ownership established by the scoped get_environment above.
      env -> render(conn, :index, secrets: Environments._unsafe_list_secrets(env))
    end
  end

  operation(:create,
    summary: "Upsert a secret",
    description:
      "Sets the value for `key`. If the key exists, the value is overwritten. " <>
        "Values are write-only — subsequent reads never return them.",
    parameters: [environment_id: [in: :path, type: :string, required: true]],
    request_body: {"Secret", "application/json", Schemas.SecretRequest},
    responses: [
      created: {"Secret", "application/json", Schemas.SecretResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def create(conn, %{"environment_id" => env_id} = params) do
    case Environments.get_environment(env_id, conn.assigns.current_user.id) do
      nil ->
        {:error, :not_found}

      env ->
        attrs = Map.take(params, ["key", "value"])
        {:ok, dek} = Crypto.load_tenant_key(conn.assigns.current_user.id)

        with {:ok, secret} <-
               Environments.upsert_secret(env, attrs, dek, Audited.attribution(conn)) do
          conn
          |> put_status(:created)
          |> render(:show, secret: secret)
        end
    end
  end

  operation(:delete,
    summary: "Delete a secret by key",
    parameters: [
      environment_id: [in: :path, type: :string, required: true],
      id: [in: :path, type: :string, required: true, description: "Secret key."]
    ],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"environment_id" => env_id, "id" => key}) do
    user = conn.assigns.current_user

    with %_{} = env <- Environments.get_environment(env_id, user.id),
         # Ownership established by the scoped get_environment above.
         %_{} = secret <- Environments._unsafe_get_secret(env_id, key) do
      {:ok, _} = Environments.delete_secret(env, secret, Audited.attribution(conn))

      send_resp(conn, :no_content, "")
    else
      _ -> {:error, :not_found}
    end
  end
end
