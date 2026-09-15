defmodule FountainWeb.AgentController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Agents
  alias Fountain.Agents.Agent
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Agents"])

  operation(:index,
    summary: "List agents",
    parameters: [
      search: [
        in: :query,
        type: :string,
        required: false,
        description: "Case-insensitive substring match on the agent name."
      ],
      runtime: [
        in: :query,
        type: :string,
        required: false,
        description: "Comma-separated runtimes, e.g. `claude,codex`."
      ],
      environment_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Comma-separated environment ids."
      ],
      has_skills: [
        in: :query,
        type: :boolean,
        required: false,
        description: "Only agents with at least one skill."
      ],
      has_mcp: [
        in: :query,
        type: :boolean,
        required: false,
        description: "Only agents with at least one MCP server."
      ]
    ],
    responses: [
      ok: {"Agents", "application/json", Schemas.AgentListResponse}
    ]
  )

  # docs/api.md has documented ?search= and ?runtime= since launch, and the
  # filters have been implemented in Agents.list_agents/2 the whole time — but
  # this action passed `[]` and ignored every param, so the documented
  # behaviour only ever worked in the LiveView.
  def index(conn, params) do
    user = conn.assigns.current_user
    render(conn, :index, agents: Agents.list_agents_with_counts(user.id, agent_filters(params)))
  end

  defp agent_filters(params) do
    [
      search: params["search"] || "",
      runtimes: csv(params["runtime"]),
      env_ids: csv(params["environment_id"]),
      has_skills: truthy(params["has_skills"]),
      has_mcp: truthy(params["has_mcp"])
    ]
  end

  defp csv(nil), do: []
  defp csv(""), do: []

  defp csv(value) when is_binary(value),
    do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp csv(value) when is_list(value), do: value
  defp csv(_), do: []

  defp truthy(v) when v in [true, "true", "1"], do: true
  defp truthy(_), do: false

  operation(:show,
    summary: "Get an agent",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Agent", "application/json", Schemas.AgentResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Agents.get_agent_with_counts(id, user.id) do
      nil -> {:error, :not_found}
      agent -> render(conn, :show, agent: agent)
    end
  end

  operation(:create,
    summary: "Create an agent",
    request_body: {"Agent attributes", "application/json", Schemas.AgentRequest},
    responses: [
      created: {"Agent", "application/json", Schemas.AgentResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user
    # Force the new agent's user_id to the authenticated user; ignore any
    # client-supplied user_id to prevent owner spoofing.
    attrs = Map.put(params, "user_id", user.id)

    with {:ok, %Agent{} = agent} <- Agents.create_agent(attrs, Audited.attribution(conn)) do
      conn
      |> put_status(:created)
      |> render(:show, agent: Agents.get_agent_with_counts(agent.id, user.id))
    end
  end

  operation(:update,
    summary: "Update an agent (partial)",
    description:
      "Every field is optional; the server merges into the existing record. Moving " <>
        "`environment_id` retires the agent's persistent sandboxes built on the old " <>
        "environment, so the update is refused with `409 sandbox_mid_turn` while a " <>
        "conversation on one of them is running a turn.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Partial agent attributes", "application/json", Schemas.AgentUpdate},
    responses: [
      ok: {"Agent", "application/json", Schemas.AgentResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict:
        {"An agent is mid-turn on a persistent sandbox the change retires", "application/json",
         Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    # Strip user_id from update attrs so the owner can't be reassigned.
    attrs = params |> Map.delete("id") |> Map.delete("user_id")

    case Agents.get_agent(id, user.id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, agent} <- Agents.update_agent(agent, attrs, Audited.attribution(conn)) do
          render(conn, :show, agent: Agents.get_agent_with_counts(agent.id, user.id))
        end
    end
  end

  operation(:delete,
    summary: "Delete an agent",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Agents.get_agent(id, user.id) do
      nil ->
        {:error, :not_found}

      agent ->
        {:ok, _} = Agents.delete_agent(agent, Audited.attribution(conn))
        send_resp(conn, :no_content, "")
    end
  end
end
