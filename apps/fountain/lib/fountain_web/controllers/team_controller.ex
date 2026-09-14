defmodule FountainWeb.TeamController do
  @moduledoc """
  The team over the API: the same roster `/team` shows, for a client that
  is not this web app (#810).

  Every action is a thin wrapper over `Fountain.Team`; nothing here decides
  anything the LiveView does not. `stream/2` is the one addition — one SSE
  connection carrying every teammate's events plus a `team` event when the
  roster changes, so a client follows the whole team on a single socket
  instead of one per conversation.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.{Conversations, Team}
  alias Fountain.Conversations.LogEvent
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  # Before the cast: `label` is a repeated key. See the plug's moduledoc.
  plug FountainWeb.Plugs.RepeatedQueryParam, "label" when action in [:conversations]

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Team"])

  operation(:index,
    summary: "List the team",
    description:
      "One entry per agent on the team, most recently active first: the agent, its " <>
        "current conversation (the newest live one, or the newest finished one when " <>
        "none is live), presence, unread state and the roster preview. A teammate is a " <>
        "conversation bound to the reserved channel `fountain:team`.",
    responses: [ok: {"Team", "application/json", Schemas.TeammateListResponse}]
  )

  def index(conn, _params) do
    render(conn, :index, teammates: Team.list_teammates(conn.assigns.current_user.id))
  end

  operation(:show,
    summary: "Show one teammate",
    parameters: [agent_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Teammate", "application/json", Schemas.TeammateResponse},
      not_found: {"Not on the team", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"agent_id" => agent_id}) do
    case Team.get_teammate(conn.assigns.current_user.id, agent_id) do
      nil -> {:error, :not_found}
      teammate -> render(conn, :show, teammate: teammate)
    end
  end

  operation(:create,
    summary: "Add an agent to the team",
    description:
      "Opens the agent's team conversation — which provisions its sandbox — with an " <>
        "optional name (the conversation title), environment (provision from it instead " <>
        "of the agent's own; must satisfy `allowed_environment_ids`) and vault (must " <>
        "satisfy `allowed_vault_ids`). 201 with the teammate; 200 when the agent was " <>
        "already on the team (its live conversation is returned, the attributes ignored).",
    request_body: {"Add attributes", "application/json", Schemas.TeamAddRequest},
    responses: [
      created: {"Teammate", "application/json", Schemas.TeammateResponse},
      ok: {"Teammate (already on the team)", "application/json", Schemas.TeammateResponse},
      not_found: {"Unknown agent, environment or vault", "application/json", Schemas.Error},
      unprocessable_entity: {"Not allowed by the agent", "application/json", Schemas.Error}
    ]
  )

  def create(conn, %{"agent_id" => agent_id} = params) do
    user = conn.assigns.current_user
    already? = Team.get_teammate(user.id, agent_id) != nil
    attrs = Map.take(params, ["name", "environment_id", "vault_id"])
    opts = [source: "api"] ++ Audited.attribution(conn)

    with {:ok, _conv} <- Team.add_teammate(user.id, agent_id, attrs, opts),
         %{} = teammate <- Team.get_teammate(user.id, agent_id) || {:error, :not_found} do
      conn
      |> put_status(if(already?, do: :ok, else: :created))
      |> render(:show, teammate: teammate)
    end
  end

  operation(:update,
    summary: "Rename a teammate",
    description:
      "Sets what the teammate is called — its conversation's title (#831). `name` " <>
        "null or blank goes back to the agent's name. The name carries over to the " <>
        "fresh conversation opened when this one is past resuming. Audited as " <>
        "`team.renamed`; the stream sends `team` so clients re-list.",
    parameters: [agent_id: [in: :path, type: :string, required: true]],
    request_body: {"Rename", "application/json", Schemas.TeamRenameRequest},
    responses: [
      ok: {"Teammate", "application/json", Schemas.TeammateResponse},
      not_found: {"Not on the team", "application/json", Schemas.Error},
      unprocessable_entity: {"Name too long", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"agent_id" => agent_id} = params) do
    user = conn.assigns.current_user

    with {:ok, _conv} <-
           Team.rename_teammate(user.id, agent_id, params["name"], Audited.attribution(conn)),
         %{} = teammate <- Team.get_teammate(user.id, agent_id) || {:error, :not_found} do
      render(conn, :show, teammate: teammate)
    end
  end

  operation(:conversations,
    summary: "List a teammate's conversations",
    description:
      "Every conversation the agent has had on the team, newest first (#832): the " <>
        "current one flagged `current: true`, the retired ones — a previous computer's " <>
        "thread, read-only — behind it. Each is a full conversation object; read a " <>
        "retired thread with `GET /api/conversations/:id/events`. 404 when the agent is " <>
        "not on the team.",
    parameters: [
      agent_id: [in: :path, type: :string, required: true],
      label: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string}},
        style: :form,
        explode: true,
        required: false,
        description:
          "Only conversations carrying these `key:value` labels (#1637). Repeatable and " <>
            "AND-combined, exactly as on `GET /api/conversations`. 400 " <>
            "`invalid_label_filter` on a value with no colon or an empty key."
      ]
    ],
    responses: [
      ok: {"Conversations", "application/json", Schemas.TeammateConversationListResponse},
      bad_request: {"Invalid label filter", "application/json", Schemas.Error},
      not_found: {"Not on the team", "application/json", Schemas.Error}
    ]
  )

  def conversations(conn, %{"agent_id" => agent_id}) do
    user = conn.assigns.current_user

    with {:ok, labels} <- FountainWeb.LabelFilter.from(conn),
         %{conversation: current} <- Team.get_teammate(user.id, agent_id) || {:error, :not_found} do
      render(conn, :conversations,
        conversations: Team.list_teammate_conversations(user.id, agent_id, labels: labels),
        current_id: current.id
      )
    end
  end

  operation(:fresh_conversation,
    summary: "Open a fresh conversation on the teammate's computer",
    description:
      "Retires the teammate's current conversation — it stays in its history, past " <>
        "resuming — and opens a new one on the **same sandbox**: the next message starts " <>
        "a fresh runtime session on the same disk, files and installed tools intact. " <>
        "Nothing is provisioned and nothing is interrupted: 400 `conversation_busy` " <>
        "while a turn is running (interrupt first), 503 `provisioning` while the " <>
        "computer is still starting. When the computer is gone (sandbox terminated or " <>
        "failed, or the conversation already past resuming) a new sandbox is " <>
        "provisioned instead, as `POST /api/team` does. 201 with the teammate and its " <>
        "new conversation; the stream sends `team`. Audited as `team.conversation.rotated`.",
    parameters: [agent_id: [in: :path, type: :string, required: true]],
    responses: [
      created: {"Teammate", "application/json", Schemas.TeammateResponse},
      not_found: {"Not on the team", "application/json", Schemas.Error},
      bad_request: {"A turn is still running", "application/json", Schemas.Error},
      service_unavailable: {"The computer is still starting", "application/json", Schemas.Error}
    ]
  )

  def fresh_conversation(conn, %{"agent_id" => agent_id}) do
    user = conn.assigns.current_user
    opts = [source: "api"] ++ Audited.attribution(conn)

    with {:ok, _conv} <- Team.open_fresh_conversation(user.id, agent_id, opts),
         %{} = teammate <- Team.get_teammate(user.id, agent_id) || {:error, :not_found} do
      conn
      |> put_status(:created)
      |> render(:show, teammate: teammate)
    else
      {:error, :busy} -> {:error, "conversation_busy"}
      {:error, _} = err -> err
    end
  end

  operation(:delete,
    summary: "Remove an agent from the team",
    description:
      "Terminates the live conversation (its sandbox goes with it) and unbinds every " <>
        "conversation the agent had under the team channel; the rows stay in " <>
        "`GET /api/conversations`.",
    parameters: [agent_id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Removed",
      not_found: {"Not on the team", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"agent_id" => agent_id}) do
    user = conn.assigns.current_user

    with :ok <- Team.remove_teammate(user.id, agent_id, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  operation(:message,
    summary: "Message a teammate",
    description:
      "A turn on the teammate's conversation. A parked or reaped sandbox wakes; a " <>
        "conversation past resuming is replaced by a fresh one under the same binding, " <>
        "seeded with this message, so the response names the conversation the message " <>
        "went to. 400 `conversation_busy` while the previous turn is still running " <>
        "(the same shape as `POST /api/conversations/:id/prompts`), 503 while the " <>
        "computer is still starting.\n\n" <>
        "`labels` merges onto the conversation the message lands on (#1637), before the " <>
        "turn is queued, so a label the limits refuse leaves the message unsent.",
    parameters: [agent_id: [in: :path, type: :string, required: true]],
    request_body: {"Message", "application/json", Schemas.TeamMessageRequest},
    responses: [
      accepted: {"Queued", "application/json", Schemas.TeamMessageResponse},
      not_found: {"Not on the team", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid labels", "application/json", Schemas.ChangesetError},
      forbidden:
        {"A sandbox token labelling another conversation", "application/json", Schemas.Error},
      bad_request: {"A turn is still running", "application/json", Schemas.Error}
    ]
  )

  def message(conn, %{"agent_id" => agent_id, "prompt" => prompt} = params) do
    user = conn.assigns.current_user

    # `SandboxKey.opts/1`: this route writes labels onto the teammate's
    # conversation (#1637), which a sandbox's own token does not own.
    with {:ok, images} <- FountainWeb.PromptImages.decode(params["images"]),
         opts =
           [source: "api", labels: params["labels"]] ++
             FountainWeb.SandboxKey.opts(conn) ++ Audited.attribution(conn),
         {:ok, conv} <- Team.send_message(user.id, agent_id, prompt, images, opts) do
      conn
      |> put_status(:accepted)
      |> json(%{status: "queued", conversation_id: conv.id})
    else
      {:error, :busy} -> {:error, "conversation_busy"}
      {:error, _} = err -> err
    end
  end

  # ── stream ──────────────────────────────────────────────────────────────────

  operation(:stream,
    summary: "Stream the whole team's events (SSE)",
    description:
      "One `text/event-stream` carrying the log events of every teammate's " <>
        "conversation, each payload the shape of `GET /api/conversations/:id/stream` " <>
        "plus `conversation_id` and `agent_id`. A `team` event (data `{reason: changed}`) " <>
        "is sent when the roster changes — a teammate added or removed, or a " <>
        "fresh conversation opened for one, or a self-hosted runner connecting or " <>
        "dropping (presence changes for the teammates on it) — and the stream follows the new " <>
        "conversation on its own; the client re-lists. A `schedule` event (same " <>
        "data) is sent when a team schedule is created, updated, deleted or fired " <>
        "(#825); the client re-lists `/api/team/schedules`. `Last-Event-ID` (a log event " <>
        "id) replays what was missed on each teammate's conversation. `?blocks=true` adds " <>
        "server-parsed ACP blocks per event. Other streams produce no blocks. " <>
        "Heartbeats every 15s; closes after 60s idle so the client reconnects.",
    parameters: [
      "Last-Event-ID": [
        in: :header,
        type: :string,
        required: false,
        description:
          "Resume after this event id (integer as string). " <>
            "Missing or unparseable values are treated as 0."
      ],
      streams: [
        in: :query,
        type: :string,
        required: false,
        description: "Comma-separated stream allow-list (`stdout,stderr,acp,stage,...`)."
      ],
      blocks: [
        in: :query,
        type: :boolean,
        required: false,
        description:
          "Add `blocks` to each event payload — its `data` parsed server-side into the " <>
            "structured blocks a transcript renders, as on " <>
            "`/api/conversations/:id/stream?blocks=true`. Only ACP output events " <>
            "produce blocks. Defaults to false."
      ]
    ],
    responses: [
      ok: {"SSE stream", "text/event-stream", %OpenApiSpex.Schema{type: :string}}
    ]
  )

  @default_heartbeat_ms 15_000
  @default_idle_timeout_ms 60_000

  defp heartbeat_ms,
    do: Application.get_env(:fountain, :sse_heartbeat_ms, @default_heartbeat_ms)

  defp idle_timeout_ms,
    do: Application.get_env(:fountain, :sse_idle_timeout_ms, @default_idle_timeout_ms)

  def stream(conn, params) do
    user_id = conn.assigns.current_user.id
    last_event_id = conn |> get_req_header("last-event-id") |> List.first() |> parse_id()
    streams = parse_streams(params["streams"])
    blocks? = params["blocks"] in [true, "true", "1"]

    Team.subscribe(user_id)
    # A runner going offline or online changes presence for every teammate
    # on that machine (#834); the roster must not poll to notice.
    Fountain.Runners.subscribe(user_id)
    followed = follow_team(user_id, %{})

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # A first byte straight away. A proxy that buffers a chunked response
    # until data flows (Cloudflare does) would otherwise hold the headers
    # back until the first heartbeat, 15 s later, and a browser client that
    # shows "connected" when the response opens would sit on "reconnecting"
    # for that long on every connect.
    conn =
      case Plug.Conn.chunk(conn, ": connected\n\n") do
        {:ok, conn} -> conn
        {:error, _} -> conn
      end

    state = %{
      user_id: user_id,
      followed: followed,
      last_id: last_event_id,
      streams: streams,
      blocks?: blocks?
    }

    case replay(conn, state) do
      {:ok, conn, last_id} ->
        Process.send_after(self(), :heartbeat, heartbeat_ms())

        sse_loop(conn, %{state | last_id: last_id})

      {:closed, conn, _} ->
        conn
    end
  end

  # Subscribe to every teammate's conversation not yet followed. Returns the
  # map conversation_id → agent_id so events can be routed to roster rows.
  # Topics are never unsubscribed: a removed teammate's conversation stops
  # publishing.
  defp follow_team(user_id, followed) do
    user_id
    |> Team.list_teammates()
    |> Enum.reduce(followed, fn %{conversation: conv, agent: agent}, acc ->
      unless Map.has_key?(acc, conv.id) do
        Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")
      end

      Map.put(acc, conv.id, agent.id)
    end)
  end

  defp replay(conn, %{last_id: 0}), do: {:ok, conn, 0}

  defp replay(conn, state) do
    # Ownership: `followed` came from the tenant-scoped Team.list_teammates.
    state.followed
    |> Enum.flat_map(fn {conv_id, _} ->
      Conversations._unsafe_list_log_events(conv_id, state.last_id, streams: state.streams)
    end)
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, conn, state.last_id}, fn ev, {:ok, acc, last_id} ->
      case write_event(acc, ev, state) do
        {:ok, c} -> {:cont, {:ok, c, max(ev.id, last_id)}}
        {:error, _} -> {:halt, {:closed, acc, last_id}}
      end
    end)
  end

  defp sse_loop(conn, state) do
    receive do
      {:log_event, %LogEvent{id: ev_id} = ev} when ev_id > state.last_id ->
        if Conversations.event_in_streams?(ev, state.streams) do
          case write_event(conn, ev, state) do
            {:ok, conn} -> sse_loop(conn, %{state | last_id: ev_id})
            {:error, _} -> conn
          end
        else
          sse_loop(conn, %{state | last_id: ev_id})
        end

      {:log_event, _stale} ->
        sse_loop(conn, state)

      {:team_changed, _} ->
        followed = follow_team(state.user_id, state.followed)

        case Plug.Conn.chunk(
               conn,
               "event: team\ndata: #{Jason.encode!(%{reason: "changed"})}\n\n"
             ) do
          {:ok, conn} -> sse_loop(conn, %{state | followed: followed})
          {:error, _} -> conn
        end

      # A runner connected or dropped (#834): presence changed for the
      # teammates on it; the same re-list as a roster change.
      {runner_event, _runner_id} when runner_event in [:runner_online, :runner_offline] ->
        case Plug.Conn.chunk(
               conn,
               "event: team\ndata: #{Jason.encode!(%{reason: "changed"})}\n\n"
             ) do
          {:ok, conn} -> sse_loop(conn, state)
          {:error, _} -> conn
        end

      # A schedule was created, updated, deleted or fired (#825): the client
      # re-lists `/api/team/schedules`. Nothing to follow — a run's
      # conversation is either a teammate's (already followed, or announced by
      # `team`) or a one-off outside the team.
      {:team_schedules_changed, _} ->
        case Plug.Conn.chunk(
               conn,
               "event: schedule\ndata: #{Jason.encode!(%{reason: "changed"})}\n\n"
             ) do
          {:ok, conn} -> sse_loop(conn, state)
          {:error, _} -> conn
        end

      :heartbeat ->
        case Plug.Conn.chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} ->
            Process.send_after(self(), :heartbeat, heartbeat_ms())
            sse_loop(conn, state)

          {:error, _} ->
            conn
        end
    after
      idle_timeout_ms() -> conn
    end
  end

  # Field-for-field the per-conversation stream's payload, plus the two ids a
  # client needs to route the event to a roster row.
  defp write_event(conn, %LogEvent{} = ev, state) do
    agent_id = Map.get(state.followed, ev.conversation_id)

    payload =
      %{
        conversation_id: ev.conversation_id,
        agent_id: agent_id,
        kind: ev.kind,
        stream: ev.stream,
        data: ev.data,
        stage: LogEvent.rendered_stage(ev),
        state: LogEvent.rendered_state(ev),
        turn_id: ev.turn_id,
        ts: ev.inserted_at
      }
      |> FountainWeb.ConversationJSON.put_blocks(ev, state.blocks?)
      |> Jason.encode!()

    Plug.Conn.chunk(conn, "id: #{ev.id}\nevent: #{ev.kind}\ndata: #{payload}\n\n")
  end

  defp parse_id(nil), do: 0
  defp parse_id(""), do: 0

  defp parse_id(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_streams(nil), do: nil
  defp parse_streams(""), do: nil

  defp parse_streams(s) when is_binary(s),
    do: s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end
