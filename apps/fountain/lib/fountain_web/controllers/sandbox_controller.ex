defmodule FountainWeb.SandboxController do
  @moduledoc """
  The caller's sandboxes — the machines their conversations run on.

  A sandbox is created by `POST /api/conversations`, one per conversation;
  this is where a client learns which machines it has. Read-only: the reset
  of a persistent home (`DELETE /api/sandboxes/:id`, #1071) went with homes
  (#2676).
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Sandboxes"])

  operation(:index,
    summary: "List sandboxes",
    description:
      "Every sandbox the caller has provisioned, newest first, each with the conversations " <>
        "on it and which of them is mid-turn. `status` filters by a comma-separated list; " <>
        "without it every status is listed, terminated ones included.",
    parameters: [
      status: [
        in: :query,
        type: :string,
        required: false,
        description: "Comma-separated: pending, starting, ready, suspended, terminated, failed."
      ]
    ],
    responses: [
      ok: {"Sandboxes", "application/json", Schemas.SandboxListResponse},
      bad_request: {"Unknown status", "application/json", Schemas.Error}
    ]
  )

  def index(conn, params) do
    user = conn.assigns.current_user

    with {:ok, statuses} <- parse_statuses(params["status"]) do
      render(conn, :index, sandboxes: Conversations.list_sandboxes(user.id, status: statuses))
    end
  end

  operation(:show,
    summary: "Get a sandbox",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Sandbox", "application/json", Schemas.SandboxResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_sandbox_with_conversations(id, user.id) do
      nil -> {:error, :not_found}
      sandbox -> render(conn, :show, sandbox: sandbox)
    end
  end

  defp parse_statuses(nil), do: {:ok, nil}
  defp parse_statuses(""), do: {:ok, nil}

  defp parse_statuses(raw) when is_binary(raw) do
    statuses = raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    if statuses != [] and Enum.all?(statuses, &(&1 in Sandbox.statuses())),
      do: {:ok, statuses},
      else: {:error, "invalid_status"}
  end
end
