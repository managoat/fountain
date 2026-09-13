defmodule FountainWeb.SecretBindingController do
  @moduledoc """
  Secret bindings (ADR 0019 gate 1b): which hosts a secret is attached to at
  the egress broker, and how.

      GET    /api/secret-bindings            — the account's bindings
      GET    /api/secret-bindings/presets    — the catalog the console prefills from
      POST   /api/secret-bindings            — bind a secret to a host
      PATCH  /api/secret-bindings/:id        — change one
      DELETE /api/secret-bindings/:id        — unbind

  Every route answers 404 `brokerage_not_enabled` for an account the broker is
  not on for: the feature does not exist there, and the console does not show
  it either. Binding a secret and changing one need the `connections` rollout
  flag as well, because both point a credential at a host. The doors that take
  a credential away do not, and an account whose flag is off keeps all of
  them: `DELETE` unbinds, and `PATCH` with `enabled: false` and nothing else
  disables. `enabled: true` is on the other side — it attaches the credential
  again — as is any edit that carries another field (#1693).
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.SecretBindings
  alias Fountain.SecretBindings.Catalog
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug :require_brokerage

  tags(["Secret bindings"])

  operation(:index,
    summary: "List secret bindings",
    description:
      "Every binding on the account: a secret name, the host it is attached " <>
        "to at the egress broker, and the auth shape. A secret with at least " <>
        "one enabled binding reaches the sandbox as a placeholder; one with " <>
        "none reaches it in the clear. Only on a deployment that runs the " <>
        "broker (ADR 0019); 404 otherwise.",
    responses: [
      ok: {"Bindings", "application/json", Schemas.SecretBindingListResponse},
      not_found: {"Brokerage is not enabled for this account", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :index, bindings: SecretBindings.list_bindings(user.id))
  end

  operation(:presets,
    summary: "List binding presets",
    description:
      "The broker's service catalog: known hosts with their auth shape and " <>
        "the secret name each usually goes by. Suggestions the console " <>
        "prefills from; a binding is still yours to save.",
    responses: [
      ok: {"Presets", "application/json", Schemas.SecretBindingPresetListResponse},
      not_found: {"Brokerage is not enabled for this account", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def presets(conn, _params) do
    render(conn, :presets, presets: Catalog.presets())
  end

  operation(:create,
    summary: "Bind a secret to a host",
    request_body: {"Binding", "application/json", Schemas.SecretBindingRequest, required: true},
    responses: [
      created: {"Binding", "application/json", Schemas.SecretBinding},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error},
      not_found: {"Brokerage is not enabled for this account", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, binding} <-
           SecretBindings.create_binding(
             user.id,
             binding_attrs(params),
             Audited.attribution(conn)
           ) do
      conn |> put_status(:created) |> render(:show, binding: binding)
    end
  end

  operation(:update,
    summary: "Change a binding",
    parameters: [id: [in: :path, type: :string, description: "Binding id"]],
    request_body: {"Binding", "application/json", Schemas.SecretBindingRequest, required: true},
    responses: [
      ok: {"Binding", "application/json", Schemas.SecretBinding},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error},
      not_found:
        {"No such binding, or brokerage is not enabled", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with %{} = binding <- SecretBindings.get_binding(id, user.id) || {:error, :not_found},
         {:ok, binding} <-
           SecretBindings.update_binding(
             binding,
             binding_attrs(params),
             Audited.attribution(conn)
           ) do
      render(conn, :show, binding: binding)
    end
  end

  operation(:delete,
    summary: "Unbind a secret from a host",
    parameters: [id: [in: :path, type: :string, description: "Binding id"]],
    responses: [
      no_content: "Deleted",
      not_found:
        {"No such binding, or brokerage is not enabled", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with %{} = binding <- SecretBindings.get_binding(id, user.id) || {:error, :not_found},
         {:ok, _} <- SecretBindings.delete_binding(binding, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  @fields ~w(key host auth_type header prefix username headers enabled)

  defp binding_attrs(params), do: Map.take(params, @fields)

  # Binding a secret and editing a binding both send a credential somewhere it
  # was not going before, so they need the rollout flag. Listing and unbinding
  # ask the broker only — an account that holds bindings can always see them
  # and take them apart, which is the one thing the single gate made
  # impossible (#1693).
  #
  # The plug covers every action, so an action left off this list gets the
  # weaker gate rather than no gate. That default is right for one that reads
  # or removes and wrong for one that creates: an action that adds a way to a
  # credential belongs here in the commit that adds it.
  @creating [:create, :update]

  # `update` is the one action its name cannot classify. `enabled: false` on
  # its own is the soft off switch, the same act as `delete` and not a new
  # credential path, so it is the edit a flag-off account may still make. Any
  # other field — a host, an auth shape, or `enabled: true` — points a
  # credential at somewhere, and the console's Enable button is gated the same
  # way (`FountainWeb.SecretBindingsLive.Index`).
  defp creating?(conn) do
    case action_name(conn) do
      :update -> not disabling_only?(conn.params)
      action -> action in @creating
    end
  end

  defp disabling_only?(params) do
    case Map.take(params, @fields) do
      %{"enabled" => enabled} = attrs when map_size(attrs) == 1 -> enabled in [false, "false"]
      _ -> false
    end
  end

  defp require_brokerage(conn, _opts) do
    user_id = conn.assigns.current_user.id

    allowed? =
      if creating?(conn),
        do: Fountain.Connections.enabled_for?(user_id),
        else: Fountain.Connections.manageable_for?()

    if allowed? do
      conn
    else
      conn
      |> put_status(:not_found)
      |> json(%{
        error: "brokerage_not_enabled",
        message: "Egress credential brokerage is not enabled for this account."
      })
      |> halt()
    end
  end
end
