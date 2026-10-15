defmodule FountainWeb.AgentVersionController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Agents
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Agents"])

  operation(:index,
    summary: "List an agent's config versions",
    description:
      "The agent's config history (ADR 0029), newest first. A version is written on " <>
        "create and on every update that changes a config field, so version 1 is the " <>
        "config the agent was created with. Read-only: to go back to a version, update " <>
        "the agent with its config, which is written as a new version rather than " <>
        "rewriting history.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Versions", "application/json", Schemas.AgentVersionListResponse},
      not_found: {"Agent not found", "application/json", Schemas.Error}
    ]
  )

  def index(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    # Ownership: the scoped get_agent is the gate; the version list is
    # scoped again by user_id on its own query.
    case Agents.get_agent(id, user.id) do
      nil -> {:error, :not_found}
      agent -> render(conn, :index, versions: Agents.list_agent_versions(agent.id, user.id))
    end
  end

  operation(:show,
    summary: "Get one config version of an agent",
    description:
      "One version by number, with its full config. A conversation's " <>
        "`agent_version` names the number to look up here.",
    parameters: [
      id: [in: :path, type: :string, required: true],
      version: [in: :path, type: :integer, required: true, description: "1-based."]
    ],
    responses: [
      unprocessable_entity: {"Invalid request parameters", "application/json", Schemas.Error},
      ok: {"Version", "application/json", Schemas.AgentVersionResponse},
      not_found: {"Agent or version not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id, "version" => version}) do
    user = conn.assigns.current_user

    with {number, ""} <- Integer.parse(version),
         %{} = agent <- Agents.get_agent(id, user.id),
         %{} = found <- Agents.get_agent_version(agent.id, number, user.id) do
      render(conn, :show, version: found)
    else
      # A malformed number, another tenant's agent and a missing version all
      # read the same: nothing here for you.
      _ -> {:error, :not_found}
    end
  end
end
