defmodule FountainWeb.SandboxController do
  @moduledoc """
  The caller's sandboxes — the machines their conversations run on.

  A sandbox is created by `POST /api/conversations` and reused by passing its
  id back as `sandbox_id` (ADR 0023 gate 3); this is where a client learns
  which machines it has, and which conversations are on each. The one write
  is `DELETE /api/sandboxes/:id`, which resets a persistent home (#1071).
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias FountainWeb.Audited
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

  operation(:delete,
    summary: "Reset a sandbox",
    description:
      "Destroy a persistent sandbox — the agent's home — so the next launch on the same " <>
        "agent, environment and vault builds a clean machine. The conversations on it are " <>
        "kept, idle; each one's next prompt lands on the fresh home. Only a `persistent` " <>
        "sandbox that is not `terminated` or `failed` resets (`422 sandbox_not_resettable`), " <>
        "and not while any conversation on it is mid-turn (`409 sandbox_mid_turn`). " <>
        "A reset the provider does not confirm keeps its fence and the sandbox's " <>
        "capacity, and answers `409 sandbox_reset_pending`; retrying it is safe.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Reset",
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict: {"A conversation on it is mid-turn", "application/json", Schemas.Error},
      unprocessable_entity: {"Not a live persistent sandbox", "application/json", Schemas.Error},
      # ADR 0058 stage 5c: the destroy runs through the machine's owner, which
      # refuses while another teardown of the same machine holds its lease.
      # Retryable, and `FallbackController` sends a `retry-after` with it.
      service_unavailable:
        {"Another teardown of this sandbox is running", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    # Ownership: the scoped get_sandbox establishes it; reset_sandbox trusts
    # the row it is handed.
    with %Sandbox{} = sandbox <- Conversations.get_sandbox(id, user.id) || {:error, :not_found},
         {:ok, _} <- Conversations.reset_sandbox(sandbox, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    else
      # Rendered here rather than through `FallbackController`, whose
      # `:sandbox_unavailable` carries a *generic* sentence — it serves several
      # operations that mean different things by the word, so it can only say
      # the outcome they share. On *this* one the word has a precise meaning
      # worth spending a sentence on: the fence has committed, so the reset is
      # accepted and Fountain will finish it — a caller that reads a generic
      # 503 as "nothing happened, send it again" gets a permanent
      # `409 sandbox_reset_pending` instead, since the fence it just wrote is
      # what refuses the repeat. The CLI prints the body verbatim.
      {:error, :sandbox_unavailable} ->
        conn
        |> put_resp_header("retry-after", "30")
        |> put_status(:service_unavailable)
        |> json(%{
          error: "sandbox_unavailable",
          message:
            "another teardown of this sandbox is running; the reset is fenced and " <>
              "Fountain completes it, and sending it again answers sandbox_reset_pending"
        })

      other ->
        other
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
