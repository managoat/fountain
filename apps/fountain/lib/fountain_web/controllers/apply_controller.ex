defmodule FountainWeb.ApplyController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Manifest
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Apply"])

  operation(:create,
    summary: "Apply a compiled manifest (bulk upsert)",
    description:
      "Applies all resources from a compiled fountain.yml manifest in one request. " <>
        "Resources are reconciled in a fixed order — environments, vaults, agents " <>
        "— so an agent's `environment` may name an Environment document " <>
        "whatever the file's order. Every kind is keyed by the document's " <>
        "`name`. Apply is " <>
        "additive: a document dropped from the manifest leaves its record in " <>
        "place. Application is best-effort per resource: the response is 200 even " <>
        "when an individual resource fails validation, is refused by its context " <>
        "or raises, with per-resource errors in the result entries.",
    request_body: {"Compiled manifest", "application/json", Schemas.ApplyRequest},
    responses: [
      ok: {"Per-resource results", "application/json", Schemas.ApplyResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def create(conn, %{"resources" => resources}) do
    user = conn.assigns.current_user

    with {:ok, results} <-
           Manifest.apply_manifest(user.id, resources, Audited.attribution(conn)) do
      render(conn, :create, results: results)
    end
  end
end
