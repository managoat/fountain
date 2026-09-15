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
        "Resources are reconciled in a fixed order — environments, vaults, agents, " <>
        "teammates, schedules, webhooks — so a spec may name another document " <>
        "whatever the file's order: an agent's `environment`, a teammate's " <>
        "`agent`, `environment` and `vault`, and a schedule's `teammate`. Every " <>
        "kind is keyed by the document's `name`, except `Webhook`, which is " <>
        "keyed by `spec.url`. A `Webhook` created here returns its signing " <>
        "secret once, on that result row, and a manifest that holds one needs a " <>
        "full-scope credential. A `Teammate` " <>
        "is read as a whole declaration, so an absent `environment` or `vault` " <>
        "clears that binding, and moving either retires the computer the old " <>
        "binding named (refused with an error on that row while a turn is running " <>
        "on it). Two Teammate documents may not name the same agent. Apply is " <>
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

    # `POST /api/webhooks` is behind RequireFullScope, so a manifest that mints
    # an endpoint is held to the same bar. Checked over the whole manifest
    # before any resource is written, so a refused request writes none of the
    # others either.
    conn =
      if Enum.any?(resources, &match?(%{"kind" => "Webhook"}, &1)) do
        FountainWeb.Plugs.RequireFullScope.call(conn, [])
      else
        conn
      end

    if conn.halted do
      conn
    else
      with {:ok, results} <-
             Manifest.apply_manifest(user.id, resources, Audited.attribution(conn)) do
        render(conn, :create, results: results)
      end
    end
  end
end
