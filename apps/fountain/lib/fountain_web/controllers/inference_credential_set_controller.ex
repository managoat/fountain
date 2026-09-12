defmodule FountainWeb.InferenceCredentialSetController do
  @moduledoc """
  Named inference credential sets over the API (ADR 0053 decision 1).

  An account holds one or more, exactly one of them the default, and an agent
  or a launch may name another. This is the whole surface: create, rename,
  promote to default, delete, and write or clear one provider's credential
  inside a named set.

  `FountainWeb.InferenceCredentialController` is the same write against the
  account's default set, and stays: it is the older, shorter path, every
  existing client uses it, and an account that never makes a second set has
  no reason to learn about sets at all.

  Values are never returned here, not even truncated. `providers` says which
  credentials a set holds and nothing about what they are.

  Behind `:require_full_scope` like every other account-level write: a
  sandbox's per-conversation token must not be able to point the account's
  agents at a different provider account.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.InferenceCredentials
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Inference credentials"])

  operation(:index,
    summary: "List inference credential sets",
    description: "The default set first, then by name. Values are never returned.",
    responses: [
      ok: {"Credential sets", "application/json", Schemas.InferenceCredentialSetListResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    sets = InferenceCredentials.list_sets(conn.assigns.current_user.id)
    render(conn, :index, sets: sets)
  end

  operation(:create,
    summary: "Create an inference credential set",
    description:
      "Creates an empty set. The first set an account has is its default, " <>
        "whoever asked for it; every later one is not until it is promoted.",
    request_body:
      {"Credential set", "application/json", Schemas.InferenceCredentialSetCreateRequest},
    responses: [
      created: {"Credential set", "application/json", Schemas.InferenceCredentialSetResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid or duplicate name", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, set} <-
           InferenceCredentials.create_set(user.id, params["name"], Audited.attribution(conn)) do
      conn
      |> put_status(:created)
      |> render(:show, set: set)
    end
  end

  operation(:update,
    summary: "Rename an inference credential set, or make it the default",
    description:
      "Omitting a field leaves it alone. `is_default: false` is refused: a set " <>
        "stops being the default when another becomes it, never on its own, " <>
        "because an account with no default has nothing to read a credential from.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Changes", "application/json", Schemas.InferenceCredentialSetUpdateRequest},
    responses: [
      ok: {"Credential set", "application/json", Schemas.InferenceCredentialSetResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"No such set", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid or duplicate name", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with %{} = set <- InferenceCredentials.get_set(id, user.id) || {:error, :not_found},
         :ok <- refuse_undefaulting(params),
         {:ok, set} <- maybe_rename(set, params, conn),
         {:ok, set} <- maybe_promote(set, params, conn) do
      render(conn, :show, set: set)
    end
  end

  operation(:delete,
    summary: "Delete an inference credential set",
    description:
      "Refused for the default set: something has to answer which credential " <>
        "runs this account. Promote another first. Agents and conversations " <>
        "that named the deleted set fall back to the default rather than being " <>
        "deleted with it.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"No such set", "application/json", Schemas.Error},
      unprocessable_entity:
        {"The default set cannot be deleted", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with %{} = set <- InferenceCredentials.get_set(id, user.id) || {:error, :not_found},
         {:ok, _} <- InferenceCredentials.delete_set(set, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    else
      {:error, :is_default} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "the default credential set cannot be deleted; promote another one first",
          reason: "is_default"
        })

      other ->
        other
    end
  end

  ## Private

  # `is_default: false` has no meaning the database can hold: the partial
  # unique index allows one default per account and nothing allows zero.
  # Refused rather than ignored, so a client that believes it demoted a set
  # finds out here instead of at the next conversation.
  defp refuse_undefaulting(%{"is_default" => false}), do: {:error, :cannot_undefault}
  defp refuse_undefaulting(_params), do: :ok

  defp maybe_rename(set, %{"name" => name}, conn) when is_binary(name),
    do: InferenceCredentials.rename_set(set, name, Audited.attribution(conn))

  defp maybe_rename(set, _params, _conn), do: {:ok, set}

  defp maybe_promote(set, %{"is_default" => true}, conn),
    do: InferenceCredentials.set_default(set, Audited.attribution(conn))

  defp maybe_promote(set, _params, _conn), do: {:ok, set}
end
