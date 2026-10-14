defmodule FountainWeb.TeamScheduleController do
  @moduledoc """
  Team schedules over the API (#825): the routines `/team` offers — a cron
  that runs a teammate with a prompt, in its thread or on a one-off computer
  — for a client that is not this web app.

  Every action is a thin wrapper over `Fountain.Team.Schedules`, under the
  same tenant scoping and audit attribution as the rest of `/api/team`. The
  `:agent_id` in the path is part of the identity: a schedule reached under
  another agent's path is a 404, the same as one that is not the caller's.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Team.Schedules
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Team"])

  @agent_id_param [agent_id: [in: :path, type: :string, required: true]]
  @id_params @agent_id_param ++ [id: [in: :path, type: :string, required: true]]

  operation(:index_all,
    summary: "List every schedule of the caller",
    description:
      "Every team schedule the caller owns, across teammates, soonest next run " <>
        "first. Times are UTC: `cron` is a five-field expression evaluated in UTC.",
    responses: [ok: {"Schedules", "application/json", Schemas.TeamScheduleListResponse}]
  )

  def index_all(conn, _params) do
    render(conn, :index, schedules: Schedules.list_schedules(conn.assigns.current_user.id))
  end

  operation(:index,
    summary: "List one teammate's schedules",
    parameters: @agent_id_param,
    responses: [ok: {"Schedules", "application/json", Schemas.TeamScheduleListResponse}]
  )

  def index(conn, %{"agent_id" => agent_id}) do
    render(conn, :index,
      schedules: Schedules.list_schedules(conn.assigns.current_user.id, agent_id)
    )
  end

  operation(:show,
    summary: "Show one schedule",
    parameters: @id_params,
    responses: [
      ok: {"Schedule", "application/json", Schemas.TeamScheduleResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"agent_id" => agent_id, "id" => id}) do
    with {:ok, schedule} <- fetch(conn, agent_id, id) do
      render(conn, :show, schedule: schedule)
    end
  end

  operation(:create,
    summary: "Create a schedule for a teammate",
    description:
      "`cron` is five fields in UTC (`0 9 * * 1-5` is 09:00 UTC on weekdays; " <>
        "`@daily`-style names work, `@reboot` does not). `one_off: false` (the " <>
        "default) sends the prompt into the teammate's own conversation as a typed " <>
        "message would; `one_off: true` opens a fresh conversation on a new computer " <>
        "each run, with the teammate's agent, environment and vault. The agent must be " <>
        "the caller's; it need not be on the team yet (an in-thread schedule then " <>
        "fails each run with `agent is not on the team` until it is). Audited as " <>
        "`team.schedule.created`.",
    parameters: @agent_id_param,
    request_body: {"Schedule attributes", "application/json", Schemas.TeamScheduleCreateRequest},
    responses: [
      created: {"Schedule", "application/json", Schemas.TeamScheduleResponse},
      not_found: {"Unknown agent", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

  def create(conn, %{"agent_id" => agent_id} = params) do
    user = conn.assigns.current_user

    attrs =
      params
      |> Map.take(["name", "cron", "prompt", "one_off", "enabled"])
      |> Map.put("agent_id", agent_id)

    with {:ok, schedule} <- Schedules.create_schedule(user.id, attrs, Audited.attribution(conn)) do
      conn
      |> put_status(:created)
      |> render(:show, schedule: schedule)
    end
  end

  operation(:update,
    summary: "Update a schedule",
    description:
      "Any of `name`, `cron`, `prompt`, `one_off`, `enabled`. A changed cron or a " <>
        "re-enable recomputes `next_run_at` and clears `last_error`. Audited as " <>
        "`team.schedule.updated` with the changed field names.",
    parameters: @id_params,
    request_body: {"Schedule attributes", "application/json", Schemas.TeamScheduleUpdateRequest},
    responses: [
      ok: {"Schedule", "application/json", Schemas.TeamScheduleResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"agent_id" => agent_id, "id" => id} = params) do
    attrs = Map.take(params, ["name", "cron", "prompt", "one_off", "enabled"])

    with {:ok, schedule} <- fetch(conn, agent_id, id),
         {:ok, updated} <- Schedules.update_schedule(schedule, attrs, Audited.attribution(conn)) do
      render(conn, :show, schedule: updated)
    end
  end

  operation(:delete,
    summary: "Delete a schedule",
    parameters: @id_params,
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"agent_id" => agent_id, "id" => id}) do
    with {:ok, schedule} <- fetch(conn, agent_id, id),
         {:ok, _} <- Schedules.delete_schedule(schedule, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  operation(:run,
    summary: "Run a schedule now",
    description:
      "The same path as the page's \"Run now\": the prompt goes where the schedule " <>
        "says (the teammate's thread, or a one-off computer) and `last_run_at`, " <>
        "`last_conversation_id` and `last_error` are stamped either way. The cron " <>
        "is untouched. 400 `conversation_busy` while the teammate's previous turn is " <>
        "still running, 503 while its computer is still starting, 404 when an " <>
        "in-thread schedule's agent is not on the team; the fleet ceiling " <>
        "refusal (`fleet_full`) is the same as `POST /api/conversations`. Audited as " <>
        "`team.schedule.fired`.",
    parameters: @id_params,
    responses: [
      accepted: {"Queued", "application/json", Schemas.TeamMessageResponse},
      not_found: {"Not found, or not on the team", "application/json", Schemas.Error},
      bad_request: {"A turn is still running", "application/json", Schemas.Error}
    ]
  )

  def run(conn, %{"agent_id" => agent_id, "id" => id}) do
    with {:ok, schedule} <- fetch(conn, agent_id, id),
         {:ok, conv} <- Schedules.run_schedule(schedule, Audited.attribution(conn)) do
      conn
      |> put_status(:accepted)
      |> json(%{status: "queued", conversation_id: conv.id})
    else
      {:error, :busy} -> {:error, "conversation_busy"}
      {:error, _} = err -> err
    end
  end

  # Tenant-scoped, and the path's agent must be the schedule's: a schedule
  # is addressed by (agent, id), so a mismatch is as much a 404 as another
  # tenant's row.
  defp fetch(conn, agent_id, id) do
    case Schedules.get_schedule(id, conn.assigns.current_user.id) do
      %{agent_id: ^agent_id} = schedule -> {:ok, schedule}
      _ -> {:error, :not_found}
    end
  end
end
