defmodule FountainWeb.ConversationController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Fountain.Billing
  alias Fountain.Conversations
  alias Fountain.Conversations.{ConversationServer, LogEvent}
  alias FountainWeb.Audited
  alias FountainWeb.LabelFilter
  alias FountainWeb.SandboxKey
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  # Before the cast, and only where the parameter exists: `label` is a
  # repeated key, and the cast reads query parameters out of Plug, which
  # keeps only the last of them. See the plug's moduledoc.
  plug FountainWeb.Plugs.RepeatedQueryParam, "label" when action in [:index]

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Conversations"])

  operation(:index,
    summary: "List conversations",
    parameters: [
      roots_only: [
        in: :query,
        type: :boolean,
        required: false,
        description:
          "Exclude sub-conversations (those with a `parent_conversation_id`), " <>
            "leaving only top-level sessions. Defaults to false."
      ],
      agent_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Only this agent's conversations (#832)."
      ],
      sandbox_id: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :string, format: :uuid},
        required: false,
        description: "Only conversations on this sandbox. Combined with the other filters."
      ],
      channel_id: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Only conversations bound to this channel — `fountain:team` for the team's. " <>
            "A conversation unbound by removing its teammate no longer matches; a " <>
            "teammate's full history is `GET /api/team/:agent_id/conversations`."
      ],
      status: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Comma-separated statuses to keep (`idle,terminated`); 400 on a value outside the vocabulary."
      ],
      limit: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 500},
        required: false,
        description:
          "Return at most this many conversations, most recently updated first (1 to 500; " <>
            "400 outside that range). Without it the whole list is returned, which on a " <>
            "busy account is hundreds of rows per call — a client that needs one " <>
            "conversation should filter (`agent_id`, `sandbox_id`, `channel_id`) and cap."
      ],
      label: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string}},
        style: :form,
        explode: true,
        required: false,
        description:
          "Only conversations carrying these `key:value` labels (#1637). Repeat the " <>
            "parameter to combine them with AND: `?label=env:prod&label=drift:true` keeps " <>
            "the conversations that carry both. `label[]=` is accepted as well. Each value " <>
            "splits on its first colon only, so `label=path:a:b` matches the label `path` " <>
            "with the value `a:b`. 400 `invalid_label_filter` on a value with no colon or " <>
            "an empty key."
      ]
    ],
    responses: [
      ok: {"Conversations", "application/json", Schemas.ConversationListResponse},
      bad_request: {"Unknown status or limit out of range", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid filter", "application/json", Schemas.ChangesetError}
    ]
  )

  def index(conn, params) do
    user = conn.assigns.current_user
    roots_only = parse_bool_param(params["roots_only"], false)

    with {:ok, statuses} <- parse_statuses(params["status"]),
         {:ok, limit} <- parse_list_limit(params["limit"]),
         {:ok, labels} <- LabelFilter.from(conn) do
      render(conn, :index,
        conversations:
          Conversations.list_conversations(user.id,
            roots_only: roots_only,
            agent_id: params["agent_id"],
            channel_id: params["channel_id"],
            sandbox_id: params["sandbox_id"],
            status: statuses,
            limit: limit,
            labels: labels
          )
      )
    end
  end

  @max_list_limit 500

  # Absent means the whole list, as it always has; a value outside 1..500 is
  # a 400 rather than a silent clamp, for the same reason as a bad status —
  # a client that asked for 0 or 10,000 should find out.
  defp parse_list_limit(nil), do: {:ok, nil}
  defp parse_list_limit(""), do: {:ok, nil}

  defp parse_list_limit(raw) do
    case Integer.parse(to_string(raw)) do
      {n, ""} when n in 1..@max_list_limit -> {:ok, n}
      _ -> {:error, "invalid_limit"}
    end
  end

  # A status the vocabulary does not have is a 400, not a silent "match
  # nothing" (or worse, "match everything"): a client that typos `terminted`
  # should find out.
  defp parse_statuses(nil), do: {:ok, []}
  defp parse_statuses(""), do: {:ok, []}

  defp parse_statuses(s) when is_binary(s) do
    statuses = s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    if Enum.all?(statuses, &(&1 in Fountain.Conversations.Conversation.statuses())),
      do: {:ok, statuses},
      else: {:error, "invalid_status"}
  end

  operation(:read,
    summary: "Mark a conversation read",
    description:
      "Sets the conversation's `last_read_at` to now, which is what clears its " <>
        "unread state. Idempotent.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Marked read",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def read(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _conv ->
        :ok = Conversations.mark_read(id, user.id)
        send_resp(conn, :no_content, "")
    end
  end

  operation(:labels,
    summary: "Set a conversation's labels",
    description:
      "Merges `labels` into the conversation's own (#1637). A key the body does not name " <>
        "is left alone, and a key whose value is `null` is removed, so a run can stamp one " <>
        "outcome without reading the rest first.\n\n" <>
        "At most 32 labels survive the merge; a key is at most 64 bytes and a value at most " <>
        "256 bytes. A 422 names the offending key.\n\n" <>
        "The account's own key may label any of its conversations. A sandbox callback token " <>
        "may label **only the conversation it was minted for**; another id is refused with " <>
        "403 `sprite_may_not_label_another_conversation`. An agent inside a turn does not " <>
        "need this route at all: it sends the `_fountain/labels` ACP extension update " <>
        "instead.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    request_body: {"Labels", "application/json", Schemas.ConversationLabelsRequest},
    responses: [
      ok: {"Conversation", "application/json", Schemas.ConversationResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden:
        {"A sandbox token labelling another conversation", "application/json", Schemas.Error},
      unprocessable_entity:
        {"Invalid labels", "application/json", Schemas.UnprocessableEntityError}
    ]
  )

  def labels(conn, %{"conversation_id" => id} = params) do
    user = conn.assigns.current_user
    opts = SandboxKey.opts(conn) ++ Audited.attribution(conn)

    with {:ok, conv} <-
           Conversations.set_conversation_labels(id, user.id, params["labels"], opts) do
      # Re-read annotated, so this renders the same conversation object every
      # other conversation route does rather than one with a null turn_count.
      render(conn, :show,
        conversation: Conversations.get_conversation_with_activity(conv.id, user.id)
      )
    end
  end

  operation(:tree,
    summary: "Get the conversation's spawn tree",
    description:
      "Every conversation in the same spawn tree — ancestors and descendants of " <>
        "this one — as flat `{id, source, status, parent_id}` entries. The API is " <>
        "how sub-conversations get created (`X-Fountain-Parent-Conversation-Id`), " <>
        "so this is how an agent that fanned out enumerates what it started " <>
        "without client-side bookkeeping.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Conversation tree", "application/json", Schemas.ConversationTreeResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def tree(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil -> {:error, :not_found}
      _conv -> render(conn, :tree, nodes: Conversations.get_conversation_tree(id, user.id))
    end
  end

  operation(:show,
    summary: "Get a conversation",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Conversation", "application/json", Schemas.ConversationResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    # The annotated variant: a `show` that reported turn_count 0 and a null
    # last_active_at, as the plain fetch would, is worse than not serving
    # the fields at all.
    case Conversations.get_conversation_with_activity(id, user.id) do
      nil ->
        {:error, :not_found}

      conv ->
        # Ownership: established by the tenant-scoped fetch above. Requests
        # that outlived a turn (#1635) are served here rather than on the
        # list, because a conversation is idle while one waits and the card
        # has to survive a client reload.
        render(conn, :show,
          conversation: conv,
          pending_requests: Conversations._unsafe_list_pending_requests(conv.id)
        )
    end
  end

  operation(:turns,
    summary: "List turns in a conversation",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Turns", "application/json", Schemas.TurnListResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  operation(:egress,
    summary: "List what the conversation sent out through the egress broker",
    description:
      "The broker's request log for this conversation, newest first: each " <>
        "outbound HTTP request the sandbox made, the host, the service that " <>
        "matched (and so which credential was attached), the status and " <>
        "latency (ADR 0019 gate 4). Empty, with `brokered: false`, for a " <>
        "conversation that was not brokered. The log outlives the conversation " <>
        "for `BROKER_LOG_RETENTION_HOURS`.",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      limit: [in: :query, type: :integer, description: "1 to 500, default 100"],
      before: [
        in: :query,
        type: :integer,
        description: "Page: the `next` value of the previous page"
      ]
    ],
    responses: [
      ok: {"Egress", "application/json", Schemas.EgressListResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"The key lacks full scope", "application/json", Schemas.Error},
      bad_gateway:
        {"The broker did not answer", "application/json", Schemas.BrokerUnavailableError}
    ]
  )

  def egress(conn, %{"conversation_id" => id} = params) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      conv ->
        if Fountain.Broker.configured?() do
          opts = [limit: egress_limit(params["limit"])] ++ egress_before(params["before"])

          case Fountain.Broker.request_log(conv.id, opts) do
            {:ok, %{events: events, next: next}} ->
              render(conn, :egress, events: events, next: next, brokered: true)

            {:error, reason} ->
              # The inspected term is an internal shape, not an API message;
              # it goes to the log, and the client gets a sentence plus a
              # stable `reason` word it can branch on (#1153).
              Logger.warning("broker request_log failed for #{conv.id}: #{inspect(reason)}")

              conn
              |> put_status(:bad_gateway)
              |> json(%{
                error: "broker_unavailable",
                message: "The egress broker did not answer.",
                reason: broker_reason(reason)
              })
          end
        else
          render(conn, :egress, events: [], next: nil, brokered: false)
        end
    end
  end

  # What `Broker.request_log/2` can fail with, now that the log is a table in
  # this database rather than a call to a vendor proxy (#1487): only
  # `{:broker, :request_log, :not_configured}`. There was a clause here for a
  # vendor HTTP error and one for a `Req.TransportError`, and dialyzer marks
  # anything more general than these two as unreachable, which is the right
  # answer: a shape that cannot occur does not need a word. The 502 itself
  # stays, because the endpoint's contract did not change with the backend.
  defp broker_reason({:broker, _call, inner}), do: broker_reason(inner)
  defp broker_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp egress_limit(nil), do: 100

  defp egress_limit(raw) do
    case Integer.parse(to_string(raw)) do
      {n, ""} when n in 1..500 -> n
      _ -> 100
    end
  end

  defp egress_before(nil), do: []

  defp egress_before(raw) do
    case Integer.parse(to_string(raw)) do
      {n, ""} when n > 0 -> [before: n]
      _ -> []
    end
  end

  def turns(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        # Ownership: established by the scoped get_conversation above.
        render(conn, :turns, turns: Conversations._unsafe_list_turns(id))
    end
  end

  @default_event_limit 100
  @max_event_limit 1000

  operation(:events,
    summary: "List a conversation's log events",
    description:
      "The read-model behind the SSE stream. Same rows, same fields, as JSON — " <>
        "fetching or archiving a conversation's output no longer requires an SSE " <>
        "parser. Oldest first, cursor-paginated: pass the previous page's " <>
        "`meta.next_cursor` as `after`. SSE remains the tail/follow mechanism.",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      streams: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Comma-separated allow-list of `stdout`, `stderr`, `stage`. " <>
            "Same semantics as the SSE route; omitted means everything."
      ],
      after: [
        in: :query,
        type: :integer,
        required: false,
        description: "Return events with an id greater than this. Defaults to 0."
      ],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Page size, 1..#{@max_event_limit}. Defaults to #{@default_event_limit}."
      ],
      blocks: [
        in: :query,
        type: :boolean,
        required: false,
        description:
          "Add `blocks` to each event: its `data` parsed server-side into the " <>
            "structured blocks a transcript renders (text, thinking, tool_use, " <>
            "tool_result, init, result, error, raw) — the same parse the web UI uses, " <>
            "so no client re-implements a runtime's dialect. Defaults to false."
      ]
    ],
    responses: [
      unprocessable_entity: {"Invalid request parameters", "application/json", Schemas.Error},
      ok: {"Log events", "application/json", Schemas.LogEventListResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def events(conn, %{"conversation_id" => id} = params) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      conv ->
        limit = parse_limit(params["limit"])
        after_id = parse_after(params["after"])
        streams = parse_streams_param(params["streams"])
        blocks_runtime = if parse_bool_param(params["blocks"], false), do: conv.runtime

        # Ownership: established by the scoped get_conversation above.
        # One extra row decides has_more without a second count query.
        events =
          Conversations._unsafe_list_log_events(id, after_id,
            streams: streams,
            limit: limit + 1
          )

        {page, has_more?} = split_page(events, limit)

        render(conn, :events,
          events: page,
          has_more: has_more?,
          limit: limit,
          blocks_runtime: blocks_runtime
        )
    end
  end

  defp split_page(events, limit) do
    case Enum.split(events, limit) do
      {page, []} -> {page, false}
      {page, _extra} -> {page, true}
    end
  end

  defp parse_limit(nil), do: @default_event_limit
  defp parse_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_event_limit)

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> parse_limit(n)
      :error -> @default_event_limit
    end
  end

  defp parse_after(nil), do: 0
  defp parse_after(n) when is_integer(n) and n > 0, do: n
  defp parse_after(n) when is_integer(n), do: 0
  defp parse_after(s) when is_binary(s), do: s |> parse_last_event_id() |> max(0)

  operation(:create,
    summary: "Start a conversation",
    description:
      "Creates a sandbox + conversation pair, starts the runtime in a fresh sprite, " <>
        "and (if `prompt` is supplied) sends it as turn 1. " <>
        "With `channel_id`, resumes the latest live conversation already bound to that " <>
        "channel for the same agent and vault (200, `meta.resumed: true`) instead of " <>
        "opening a new one (201). " <>
        "`labels` (#1637) are stamped on the new conversation; with `channel_id`, a resume " <>
        "merges them into the conversation it hands back, and a sandbox callback token " <>
        "resuming a conversation it was not minted for is refused with 403. " <>
        "Pass `X-Fountain-Parent-Conversation-Id` header to record which conversation spawned this one. " <>
        "Legacy `X-AoD-Parent-Conversation-Id` is still accepted for sprites provisioned before the rename.",
    request_body: {"Conversation attrs", "application/json", Schemas.ConversationCreateRequest},
    responses: [
      bad_request: {"Invalid request", "application/json", Schemas.Error},
      conflict: {"Conflicting state", "application/json", Schemas.Error},
      service_unavailable: {"Sandbox or fleet unavailable", "application/json", Schemas.Error},
      created: {"Conversation", "application/json", Schemas.ConversationResponse},
      accepted:
        {"Queued for sandbox capacity", "application/json", Schemas.SandboxRequestResponse},
      too_many_requests: {"Tenant concurrency cap reached", "application/json", Schemas.Error},
      ok:
        {"Conversation (resumed by channel_id)", "application/json", Schemas.ConversationResponse},
      forbidden:
        {"A sandbox token labelling the conversation a resume landed on", "application/json",
         Schemas.Error},
      not_found: {"Agent not found", "application/json", Schemas.Error},
      unprocessable_entity:
        {"Validation error", "application/json", Schemas.UnprocessableEntityError},
      payment_required:
        {"Insufficient credits", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             error: %OpenApiSpex.Schema{type: :string},
             upgrade_url: %OpenApiSpex.Schema{type: :string}
           }
         }}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, images} <- decode_images(params["images"]) do
      create_with_images(conn, params, user, images)
    end
  end

  defp create_with_images(conn, params, user, images) do
    parent_header =
      List.first(get_req_header(conn, "x-fountain-parent-conversation-id")) ||
        List.first(get_req_header(conn, "x-aod-parent-conversation-id"))

    {source, parent_id} = infer_provenance(parent_header)

    params =
      params
      |> Map.put("images", images)
      |> Map.put("source", source)
      |> Map.put("parent_conversation_id", parent_id)
      |> Map.put("user_id", user.id)

    # `SandboxKey.opts/1` rides along because a `channel_id` resume lands on an
    # *existing* conversation and merges this request's labels into it (#1637);
    # without it a sandbox token could relabel any conversation of the tenant
    # by resuming its channel.
    opts = SandboxKey.opts(conn) ++ Audited.attribution(conn)

    with :ok <- Billing.check_spend(user),
         {:ok, conv, outcome} <- Conversations.start_or_resume_conversation(params, opts) do
      # 201 when a conversation was opened; 200 when `channel_id` resumed an
      # existing one (#774). Same body either way, so a client that ignores
      # the status still gets the id it needs.
      conn
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:show, conversation: conv, resumed: outcome == :resumed)
    else
      {:error, {:sandbox_quota_exceeded, _} = reason} ->
        maybe_enqueue(conn, params, user, reason)

      {:error, :fleet_full = reason} ->
        maybe_enqueue(conn, params, user, reason)

      {:error, _} = error ->
        error
    end
  end

  # Exactly the launch keys `Conversations.start_conversation/2` reads, minus
  # the ones this path sets itself (`user_id`, `agent_id`, `source`) and the
  # two it refuses to queue. An allow list rather than a drop list:
  # `ConversationCreateRequest` does not set `additionalProperties: false`, so
  # dropping the keys we know would park whatever else a caller sent in
  # `attrs` until the request expired.
  @queued_attr_keys ~w(prompt title vault_id environment_id permission_policy
                       sandbox_mode sandbox_api_access sprite_name channel_id
                       fresh parent_conversation_id caller_tools labels
                       execution_limits)

  # Queueing is opt-in (ADR 0042 decision 2). A caller that did not ask keeps
  # the immediate 429 or 503 its client already handles.
  #
  # Images never queue: the server does not hold image bytes for an hour. An
  # explicit `sandbox_id` never queues either — that is an attach to a machine
  # the caller already has, not a request for capacity. That arm is belt and
  # braces rather than a path with a test: `attach_conversation/4` takes no
  # sandbox reservation, so it cannot raise either capacity error for this
  # clause to intercept. It is here so a future attach that *does* reserve
  # cannot start queueing by accident.
  defp maybe_enqueue(conn, params, user, reason) do
    if params["queue"] == true and params["images"] in [nil, []] and
         params["sandbox_id"] in [nil, ""] do
      enqueue_params = %{
        user_id: user.id,
        agent_id: params["agent_id"],
        kind: "start",
        source: params["source"],
        # The restriction this request arrived under, carried so the replay is
        # held to it an hour later. Without it a `sprite` token could queue a
        # `channel_id` start with `labels` and have the drainer merge them into
        # a conversation the token does not own, which is the write
        # `Conversations.set_conversation_labels/4` refuses at this door
        # (ADR 0045). `nil` for any other credential, which every rule reads as
        # "no sandbox restriction applies".
        sandbox_key_id: SandboxKey.id(conn),
        attrs: Map.take(params, @queued_attr_keys)
      }

      case Fountain.SandboxQueue.enqueue(enqueue_params, Audited.attribution(conn)) do
        {:ok, request} ->
          conn
          |> put_status(:accepted)
          |> put_view(FountainWeb.SandboxQueueJSON)
          |> render(:show, request: request, position: Fountain.SandboxQueue.position(request))

        # At the depth bound the caller gets the capacity error it was about
        # to get anyway. The queue delays the cap; it never raises it.
        {:error, :queue_full} ->
          {:error, reason}

        {:error, _} = error ->
          error
      end
    else
      {:error, reason}
    end
  end

  operation(:reapply,
    summary: "Reapply a conversation's Agent, Environment and Vault",
    description:
      "Applies a selection to the machine this conversation already runs on, so its files " <>
        "stay where the agent left them. Variables, the system prompt, skills and MCP " <>
        "configuration are rewritten, and the next prompt reads them. An omitted field keeps " <>
        "its current selection; null clears the Environment override or the Vault; an empty " <>
        "object reapplies what is already selected.\n\n" <>
        "Refused with 409 `conversation_busy` while a turn runs, 409 `rebuild_required` when " <>
        "the selection would need the machine built again (the `field` says which one forced " <>
        "it), 503 while the machine is still being built, and 410 once the conversation has " <>
        "ended.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Configuration selection", "application/json", Schemas.ConversationReapplyRequest},
    responses: [
      ok: {"Reapplied conversation", "application/json", Schemas.ConversationResponse},
      forbidden:
        {"Sprite keys may not reapply a conversation", "application/json", Schemas.Error},
      not_found:
        {"Conversation or selected resource not found", "application/json", Schemas.Error},
      conflict:
        {"The conversation has a running turn, or the selection needs the machine built again",
         "application/json", Schemas.Error},
      gone: {"Conversation has ended", "application/json", Schemas.Error},
      unprocessable_entity: {"Selection is not allowed", "application/json", Schemas.Error},
      service_unavailable: {"The machine is still being built", "application/json", Schemas.Error}
    ]
  )

  def reapply(conn, %{"conversation_id" => id} = params) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      conv ->
        # Ownership was established by the scoped fetch above.
        with {:ok, updated} <-
               Conversations.reapply_conversation(conv, params, Audited.attribution(conn)) do
          render(conn, :show, conversation: updated)
        end
    end
  end

  operation(:answer_request,
    summary: "Answer a permission request",
    description:
      "Answers a `session/request_permission` the agent is blocked on (#940). The " <>
        "request and its options arrive as a `permission_request` block on the " <>
        "conversation's event stream; `option_id` must be one of the `optionId` values " <>
        "that block carried. Never send an option the agent did not offer.\n\n" <>
        "First answer wins: another attached client, the timeout, or the turn ending " <>
        "may already have resolved it, and all of those return 409. The resolution " <>
        "appears on the stream as a `request` stage event with state `done`.\n\n" <>
        "A request that outlived its turn (#1635) is answered here too. The agent " <>
        "ended that turn with stop reason `waiting`, so the conversation is idle and " <>
        "the sandbox may be suspended; GET /api/conversations/{id} lists such " <>
        "requests as `pending_requests`. Answering one resolves it and opens a new " <>
        "turn carrying the request id and the option, which wakes the sandbox.",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      request_id: [in: :path, type: :string, required: true]
    ],
    request_body: {"Answer", "application/json", Schemas.PermissionAnswerRequest},
    responses: [
      ok: {"Answered", "application/json", Schemas.PermissionAnswerResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict:
        {"Already resolved, or resolved but not delivered", "application/json", Schemas.Error},
      unprocessable_entity: {"Unknown option", "application/json", Schemas.Error},
      bad_request: {"Busy", "application/json", Schemas.Error},
      payment_required: {"Insufficient credits", "application/json", Schemas.Error},
      forbidden: {"The sandbox may not answer", "application/json", Schemas.Error}
    ]
  )

  def answer_request(conn, %{"conversation_id" => id, "request_id" => request_id} = params) do
    user = conn.assigns.current_user

    case params["option_id"] do
      option_id when is_binary(option_id) and option_id != "" ->
        conn
        |> Audited.attribution()
        |> then(&Conversations.answer_permission_request(id, user.id, request_id, option_id, &1))
        |> answer_response(conn)

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "option_id_required"})
    end
  end

  defp answer_response(:ok, conn), do: json(conn, %{ok: true})

  # Every "too late" is one status. A client that lost the race to another
  # client and a client answering after the timeout are in the same position:
  # the request is gone and the stream says how it ended.
  defp answer_response({:error, reason}, conn)
       when reason in [:no_pending_permission, :not_running] do
    conn
    |> put_status(:conflict)
    |> json(%{error: "permission_request_resolved"})
  end

  defp answer_response({:error, :unknown_option}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "unknown_option", message: "option_id was not offered for this request"})
  end

  defp answer_response({:error, :sprite_may_not_answer}, conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "sprite_may_not_answer"})
  end

  defp answer_response({:error, :not_found}, conn) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end

  # A turn is running, so the resume turn a detached answer opens cannot queue
  # behind it (#1635). The request is untouched; try again when it is idle.
  defp answer_response({:error, :busy}, _conn), do: {:error, "conversation_busy"}

  # The request was resolved and the turn that carries it back could not be
  # opened. Its own code, because the 409 above tells a client to give up on a
  # request somebody else took, and this one has to say the opposite: the
  # answer landed, the agent has not heard it, and a prompt is what wakes it.
  defp answer_response({:error, :answer_not_delivered}, conn) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "permission_answer_not_delivered",
      message:
        "The answer was recorded and the request is resolved, but the turn that " <>
          "carries it to the agent could not be opened. Send a prompt to the " <>
          "conversation to wake it."
    })
  end

  # Everything else renders through the FallbackController, for the reason
  # `do_prompt/5` gives: an error shape this function has not learned used to
  # be a FunctionClauseError 500.
  defp answer_response({:error, _} = err, _conn), do: err

  @doc """
  Infer the conversation's `source` and `parent_conversation_id` from
  the `X-Fountain-Parent-Conversation-Id` (or legacy `X-AoD-Parent-Conversation-Id`)
  header value (or `nil` if absent).

  Pure function so the inference logic can be unit-tested without
  going through the full `Conversations.start_conversation/1` pipeline
  (which provisions a real Sprite).
  """
  @spec infer_provenance(String.t() | nil) :: {String.t(), String.t() | nil}
  def infer_provenance(parent_header) do
    case parent_header do
      id when is_binary(id) and byte_size(id) > 0 -> {"agent", id}
      _ -> {"api", nil}
    end
  end

  operation(:prompt,
    summary: "Send another prompt",
    description:
      "Queues a new turn. If the ConversationServer has been GC'd (e.g. across a " <>
        "BEAM restart) a fresh sprite is provisioned and the runtime resumes via its " <>
        "session id.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    request_body: {"Prompt", "application/json", Schemas.PromptRequest},
    responses: [
      payment_required: {"Insufficient credits", "application/json", Schemas.Error},
      gone: {"Conversation is terminal", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid request parameters", "application/json", Schemas.Error},
      service_unavailable: {"Sandbox or fleet unavailable", "application/json", Schemas.Error},
      ok: {"Queued", "application/json", Schemas.PromptResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      bad_request: {"Busy", "application/json", Schemas.Error}
    ]
  )

  def prompt(conn, %{"conversation_id" => id, "prompt" => prompt} = params) do
    user = conn.assigns.current_user

    with {:ok, images} <- decode_images(params["images"]) do
      do_prompt(conn, id, prompt, user, images)
    end
  end

  defp do_prompt(conn, id, prompt, user, images) do
    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        case ConversationServer.send_prompt(id, prompt, images, Audited.attribution(conn)) do
          :ok ->
            json(conn, %{status: "queued"})

          {:error, :not_running} ->
            {:error, :not_found}

          {:error, :busy} ->
            {:error, "conversation_busy"}

          # Everything else renders via the FallbackController. This case has
          # had error shapes threaded through it by hand four times (#212's
          # 402, then :gone / :no_agent / changeset in #332), and each one it
          # was missing was a CaseClauseError 500. The fallback owns the
          # error → status mapping; new shapes land there, not here.
          {:error, _} = err ->
            err
        end
    end
  end

  operation(:terminate,
    summary: "Terminate a conversation",
    description:
      "Tears down the sprite and marks the conversation `terminated`. Idempotent " <>
        "for already-dead conversations.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      service_unavailable: {"Sandbox or fleet unavailable", "application/json", Schemas.Error},
      no_content: "Terminated",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def terminate(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        case ConversationServer.terminate_conversation(id, Audited.attribution(conn)) do
          :ok -> send_resp(conn, :no_content, "")
          {:error, :not_running} -> {:error, :not_found}
          # :provisioning and future shapes render via the FallbackController.
          {:error, _} = err -> err
        end
    end
  end

  operation(:interrupt,
    summary: "Interrupt the running turn",
    description:
      "Ends the turn in flight. Wakes a conversation whose server has died " <>
        "so a turn left `running` behind it can still be closed.\n\n" <>
        "`404` means no such conversation. `409` means the conversation " <>
        "exists but has nothing to interrupt: `no_turn_running` when it is " <>
        "idle between turns, `not_running` when it is terminated or could " <>
        "not be woken.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      service_unavailable: {"Sandbox or fleet unavailable", "application/json", Schemas.Error},
      no_content: "Interrupted",
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict: {"Nothing to interrupt", "application/json", Schemas.Error}
    ]
  )

  def interrupt(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        case ConversationServer.interrupt(id, Audited.attribution(conn)) do
          :ok ->
            send_resp(conn, :no_content, "")

          # Ownership was established by the fetch above, so a state problem
          # here is a conflict, not a missing row (#1179). `:not_found` is
          # still reachable — the conversation can be deleted between the two
          # calls — and falls through to the FallbackController's 404.
          {:error, :not_running} ->
            conn
            |> put_status(:conflict)
            |> json(%{
              error: "not_running",
              message: "the conversation is not running, so there is no turn to interrupt"
            })

          {:error, :idle} ->
            conn |> put_status(:conflict) |> json(%{error: "no_turn_running"})

          # :provisioning and future shapes render via the FallbackController.
          {:error, _} = err ->
            err
        end
    end
  end

  operation(:delete,
    summary: "Delete a conversation",
    description:
      "Tears down the sprite if alive, then deletes the conversation row " <>
        "(cascades to turns and log events).",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      conv ->
        {:ok, _} = Conversations.delete_conversation(conv, Audited.attribution(conn))
        send_resp(conn, :no_content, "")
    end
  end

  operation(:stream,
    summary: "Stream log events (SSE)",
    description:
      "Server-Sent Events stream of the conversation's log events. The `Last-Event-ID` " <>
        "request header resumes from a known event id; missed events are replayed before " <>
        "the live tail begins. Keep-alive heartbeats every 15s as `: heartbeat` comments.\n\n" <>
        "Each message carries the event id in `id:`, the event's `kind` in `event:` " <>
        "(`output` or `stage`), and a JSON object in `data:` with `kind`, `stream`, " <>
        "`data`, `stage`, `state`, `turn_id` and `ts`. The `data` field is a string: raw " <>
        "output for an `output` event, JSON-encoded metadata for a `stage` one.\n\n" <>
        "**This shape is an interface, not an implementation detail.** Two clients render " <>
        "from it — the web UI and `fountain acp`, the Agent Client Protocol adapter an " <>
        "editor spawns — so changing an event's shape or a stream's meaning breaks a " <>
        "surface outside this repo. See decisions/0015.",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      "Last-Event-ID": [
        in: :header,
        type: :string,
        required: false,
        description:
          "Resume after this event id (integer as string). " <>
            "Missing or unparseable values are treated as 0."
      ],
      # Both load-bearing in the bundled SKILL.md files and undocumented here
      # until now. The values are enumerated from LogEvent.streams/0 by a guard
      # test, because this list has already gone stale once: `acp` shipped in
      # #647 and the description still said "stdout, stderr, stage" while the
      # query filter silently dropped it (#716).
      streams: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Comma-separated subset of `stdout`, `stderr`, `acp` and `stage`. " <>
            "Omitted or empty means everything.\n\n" <>
            "- `stdout` / `stderr` — the runtime process's own output, byte for byte.\n" <>
            "- `acp` — one Agent Client Protocol `session/update` notification per line, " <>
            "stored exactly as the runtime's adapter emitted it. This is what a protocol " <>
            "client forwards to an editor, so it is a compatibility surface (decisions/0015). " <>
            "Only conversations whose runtime speaks ACP have it — see the conversation's " <>
            "`acp` field.\n" <>
            "- `stage` — lifecycle events (`provision`, `setup`, `turn`, `reattach`, " <>
            "`sandbox`, `terminate`) with a `state` and JSON metadata. The terminal " <>
            "`turn`/`done` carries the turn's `stop_reason`.\n\n" <>
            "A name no event carries selects nothing; it is not an error."
      ],
      wait: [
        in: :query,
        type: :string,
        required: false,
        description:
          "`false`/`0` drains the buffered events and closes immediately, " <>
            "rather than holding the connection open for the live tail. " <>
            "Defaults to true."
      ],
      blocks: [
        in: :query,
        type: :boolean,
        required: false,
        description:
          "Add `blocks` to each event payload — its `data` parsed server-side into " <>
            "the structured blocks a transcript renders, as on `/events?blocks=true`. " <>
            "Defaults to false."
      ]
    ],
    responses: [
      ok: {"SSE stream", "text/event-stream", %OpenApiSpex.Schema{type: :string}},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  # Both read from application env so the loop can be driven at test speed.
  # Waiting 15s for a heartbeat and 60s for the idle exit is why none of this
  # had tests: the timings are the behaviour, and the behaviour was unreachable.
  @default_heartbeat_ms 15_000
  @default_idle_timeout_ms 60_000

  defp heartbeat_ms,
    do: Application.get_env(:fountain, :sse_heartbeat_ms, @default_heartbeat_ms)

  defp idle_timeout_ms,
    do: Application.get_env(:fountain, :sse_idle_timeout_ms, @default_idle_timeout_ms)

  def stream(conn, %{"conversation_id" => id} = params) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      conv ->
        last_event_id =
          conn
          |> get_req_header("last-event-id")
          |> List.first()
          |> parse_last_event_id()

        streams = parse_streams_param(params["streams"])
        wait? = parse_bool_param(params["wait"], true)
        blocks_runtime = if parse_bool_param(params["blocks"], false), do: conv.runtime

        if wait? do
          Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{id}")
        end

        # A ConversationServer that dies without publishing a terminal
        # stage (a crash, a Horde rebalance, a deploy) would otherwise
        # leave this stream heartbeating forever with no data and no
        # reason to reconnect. Monitoring is best-effort: no server just
        # means an idle/finished conversation being drained from history.
        # The ref is matched exactly in sse_loop — this process holds other
        # monitors (DB ownership among them) whose :DOWN messages must not
        # end the stream.
        monitor_ref =
          if wait? do
            case ConversationServer.whereis(id) do
              pid when is_pid(pid) -> Process.monitor(pid)
              _ -> nil
            end
          end

        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        # Replay buffered events the client missed.
        {status, conn, last_id} = replay(conn, id, last_event_id, streams, blocks_runtime)

        if wait? and status == :ok do
          Process.send_after(self(), :heartbeat, heartbeat_ms())
          sse_loop(conn, last_id, streams, monitor_ref, blocks_runtime)
        else
          # `?wait=false` → close immediately after replay. Useful when
          # the caller already knows the conversation is finished and
          # just wants to drain the history quickly (no 60s heartbeat
          # window before curl `--max-time` fires).
          conn
        end
    end
  end

  defp parse_bool_param("false", _default), do: false
  defp parse_bool_param("0", _default), do: false
  defp parse_bool_param("true", _default), do: true
  defp parse_bool_param("1", _default), do: true
  defp parse_bool_param(_, default), do: default

  # `?streams=stdout,stderr,stage` — comma-separated allow-list. Empty /
  # missing param = no filter (everything goes through).
  defp parse_streams_param(nil), do: nil
  defp parse_streams_param(""), do: nil

  defp parse_streams_param(s) when is_binary(s) do
    s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  # Validation, decode and size cap live in FountainWeb.PromptImages so the
  # LiveView prompt path applies exactly the same checks.
  defp decode_images(images), do: FountainWeb.PromptImages.decode(images)

  defp parse_last_event_id(nil), do: 0
  defp parse_last_event_id(""), do: 0

  defp parse_last_event_id(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  # Returns `{:ok, conn, last_id}`, or `{:closed, conn, last_id}` when the
  # client went away mid-replay — a routine disconnect (Ctrl-C on a curl, a
  # closed tab, an EventSource reconnect against a long backlog), not an
  # error. This used to `throw` the chunk error with no catch anywhere in
  # the module, producing a crash report and a Sentry event per disconnect.
  defp replay(conn, conv_id, after_id, streams, blocks_runtime) do
    # Ownership: only called from stream/2, after its scoped get_conversation.
    conv_id
    |> Conversations._unsafe_list_log_events(after_id, streams: streams)
    |> Enum.reduce_while({:ok, conn, after_id}, fn ev, {:ok, acc_conn, last_id} ->
      case write_event(acc_conn, ev, blocks_runtime) do
        {:ok, c} -> {:cont, {:ok, c, ev.id}}
        {:error, _} -> {:halt, {:closed, acc_conn, last_id}}
      end
    end)
  end

  # Match a freshly-broadcast event against the same rule the historical
  # replay uses — literally the same function now. This used to be a second
  # copy that had drifted from the query filter, so `?streams=acp` matched
  # live events and no replayed ones.
  defp event_in_streams?(ev, streams), do: Conversations.event_in_streams?(ev, streams)

  defp sse_loop(conn, last_id, streams, monitor_ref, blocks_runtime) do
    receive do
      {:log_event, %LogEvent{id: ev_id} = ev} when ev_id > last_id ->
        cond do
          not event_in_streams?(ev, streams) ->
            sse_loop(conn, ev_id, streams, monitor_ref, blocks_runtime)

          true ->
            case write_event(conn, ev, blocks_runtime) do
              {:ok, conn} -> sse_loop(conn, ev_id, streams, monitor_ref, blocks_runtime)
              {:error, _} -> conn
            end
        end

      {:log_event, _stale} ->
        sse_loop(conn, last_id, streams, monitor_ref, blocks_runtime)

      :heartbeat ->
        case Plug.Conn.chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} ->
            Process.send_after(self(), :heartbeat, heartbeat_ms())
            sse_loop(conn, last_id, streams, monitor_ref, blocks_runtime)

          {:error, _} ->
            conn
        end

      {:DOWN, ^monitor_ref, :process, _pid, reason} when is_reference(monitor_ref) ->
        # The conversation server died without publishing a terminal stage.
        # Say so and close, so the client reconnects (and, if the server was
        # rehydrated elsewhere, resumes) instead of receiving heartbeats
        # forever on a topic nothing will publish to again.
        write_server_down_event(conn, reason)
    after
      idle_timeout_ms() ->
        # Long quiet — exit cleanly so the client reconnects.
        conn
    end
  end

  # Synthetic (not persisted, so no SSE id — it must not disturb
  # Last-Event-ID resume) stage event telling the client why the stream is
  # closing. Same payload shape as write_event/2. A clean shutdown or Horde
  # handoff is the stage reaching its end ("done"); anything else is a crash
  # ("failed") — the stage vocabulary clients already switch on.
  defp write_server_down_event(conn, reason) do
    state =
      case reason do
        :normal -> "done"
        :shutdown -> "done"
        {:shutdown, _} -> "done"
        _ -> "failed"
      end

    payload =
      Jason.encode!(%{
        kind: "stage",
        stream: nil,
        data:
          Jason.encode!(%{
            reason: inspect(reason),
            message: "conversation server exited — reconnect to resume streaming"
          }),
        stage: "server",
        state: state,
        turn_id: nil,
        ts: DateTime.utc_now()
      })

    case Plug.Conn.chunk(conn, "event: stage\ndata: #{payload}\n\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  # `blocks_runtime` nil means no blocks; a runtime string means "add the
  # server-parsed blocks for this event, for that runtime's legacy dialect".
  defp write_event(conn, %LogEvent{} = ev, blocks_runtime) do
    payload =
      %{
        kind: ev.kind,
        stream: ev.stream,
        data: ev.data,
        stage: LogEvent.rendered_stage(ev),
        state: LogEvent.rendered_state(ev),
        turn_id: ev.turn_id,
        ts: ev.inserted_at
      }
      |> FountainWeb.ConversationJSON.put_blocks(ev, blocks_runtime)
      |> Jason.encode!()

    chunk = "id: #{ev.id}\nevent: #{ev.kind}\ndata: #{payload}\n\n"
    Plug.Conn.chunk(conn, chunk)
  end
end
