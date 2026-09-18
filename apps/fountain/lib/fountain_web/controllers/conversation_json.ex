defmodule FountainWeb.ConversationJSON do
  @moduledoc false
  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn}

  def index(%{conversations: convs}), do: %{data: Enum.map(convs, &data/1)}

  def show(%{conversation: conv, resumed: resumed?}),
    do: %{data: data(conv), meta: %{resumed: resumed?}}

  # Requests that outlived a turn (#1635). Only `show/2` on a single
  # conversation ever fetches these, so every other renderer's `data/1`
  # carries the field as `[]` and this clause overwrites it with the real
  # answer. A list of conversations would pay a query per row for something
  # almost always empty; this way it still gets the key, just not the query.
  def show(%{conversation: conv, pending_requests: requests}),
    do: %{data: Map.put(data(conv), :pending_requests, Enum.map(requests, &request_data/1))}

  def show(%{conversation: conv}), do: %{data: data(conv)}
  def turns(%{turns: turns}), do: %{data: Enum.map(turns, &turn_data/1)}

  def egress(%{events: events, next: next, brokered: brokered}) do
    %{data: events, next: next, brokered: brokered}
  end

  def events(%{events: events, has_more: has_more?, limit: limit} = assigns) do
    blocks? = Map.get(assigns, :blocks?, false)
    # `turn_id => prompt` when `?prompts=true` asked for them, `%{}` otherwise.
    prompts = Map.get(assigns, :prompts, %{})

    %{
      data: Enum.map(events, &(&1 |> log_event_data() |> put_blocks(&1, blocks?, prompts))),
      meta: %{
        limit: limit,
        has_more: has_more?,
        # The id to pass back as `after`. nil on an empty page — there is
        # nothing to resume from, and echoing the request's cursor would
        # invite a client to loop on it.
        next_cursor: events |> List.last() |> event_id()
      }
    }
  end

  def tree(%{nodes: nodes}), do: %{data: Enum.map(nodes, &tree_node/1)}

  def data(%Conversation{} = c) do
    %{
      id: c.id,
      title: c.title,
      # The first turn's prompt, for clients that title an untitled
      # conversation the way the console's sidebar did. Only served where the
      # first turn was preloaded (index and show); null elsewhere and for a
      # conversation that has no turn yet.
      first_prompt: first_prompt(c),
      sandbox_id: c.sandbox_id,
      sandbox: sandbox_data(c.sandbox),
      agent_id: c.agent_id,
      # Provenance (ADR 0029): which shape of the agent this conversation
      # launched under. The id is always on the row; the number is resolved
      # where `agent_version` was preloaded (index and show), null elsewhere
      # and for conversations that predate versioning (#1051).
      agent_version_id: c.agent_version_id,
      agent_version: agent_version_number(c),
      vault_id: c.vault_id,
      environment_id: c.environment_id,
      sandbox_api_access: c.sandbox_api_access,
      permission_policy: c.permission_policy,
      runtime: c.runtime,
      # Derived, never stored — the same signal as on an agent (#702). A
      # protocol client asks before reopening a conversation, because a
      # legacy-runtime one has no ACP transcript to replay.
      acp: Fountain.RuntimeDispatch.acp_enabled?(c.runtime),
      status: c.status,
      runtime_session_id: c.runtime_session_id,
      source: c.source,
      parent_conversation_id: c.parent_conversation_id,
      channel_id: c.channel_id,
      # Free-form key/value strings (#1637): what a program stamped on its own
      # run, and what `?label=env:prod` filters the list by.
      labels: c.labels || %{},
      turn_count: c.turn_count,
      last_active_at: c.last_active_at,
      last_read_at: c.last_read_at,
      # Served rather than left to each client: the rule has three cases and
      # the nil ones are easy to get backwards.
      unread: Fountain.Conversations.unread?(c),
      # Running sums of the turns' usage (#827); zeros until a turn reports one.
      usage_total: %{input: c.usage_input_tokens || 0, output: c.usage_output_tokens || 0},
      # Permission requests that outlived a turn (#1635); `[]` here and
      # overwritten with the real list only where `show/2` fetched it (above)
      # — a query per row the list and the create response don't pay for
      # something almost always empty (#2305).
      pending_requests: [],
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end

  defp request_data(request) do
    %{
      request_id: request.request_id,
      tool: request.tool,
      # The agent's own option list, verbatim. Answer with an id from it and
      # never with one from another runtime.
      options: request.options,
      asked_at: request.asked_at,
      deadline: request.deadline,
      turn_id: request.turn_id
    }
  end

  defp first_prompt(%Conversation{turns: [%Turn{turn_number: 1, prompt: prompt} | _]}), do: prompt
  defp first_prompt(_), do: nil

  defp agent_version_number(%Conversation{
         agent_version: %Fountain.Agents.AgentVersion{version: v}
       }),
       do: v

  defp agent_version_number(_), do: nil

  defp tree_node(%{id: id, source: source, status: status, parent_id: parent_id}) do
    %{id: id, source: source, status: status, parent_id: parent_id}
  end

  @doc false
  def sandbox_data(%Sandbox{} = s) do
    %{
      id: s.id,
      sprite_name: s.machine_name,
      status: s.status,
      provider: s.provider,
      # The identity the disk was built from (ADR 0023): what a launch must
      # match to attach to this machine with `sandbox_id`.
      agent_id: s.agent_id,
      environment_id: s.environment_id,
      vault_id: s.vault_id,
      mode: s.mode,
      # The sandbox's own HTTP endpoint, for providers that give it one. Read
      # from the row rather than the provider so listing conversations stays a
      # single query; null means the provider has no such concept (or the
      # sandbox predates the field).
      url: s.provider_meta["public_url"],
      # The checkpoint taken when this home last parked (ADR 0023, #1073):
      # `{id, at}`, or null for an ephemeral sandbox, a provider without
      # checkpoints, or a home that has not parked yet.
      checkpoint: Fountain.Conversations.HomeCheckpoint.recorded(s),
      # Where a runner-backed sandbox lives (#834): the machine and the
      # directory, so a client says "on mac-mini · ~/…" without parsing the
      # name. Null for hosted providers.
      runner: runner_data(Fountain.Runners.for_sandbox(s))
    }
  end

  def sandbox_data(_), do: nil

  defp runner_data(nil), do: nil

  defp runner_data(%{runner: runner, online: online, path: path}) do
    %{
      id: runner && runner.id,
      name: runner && runner.name,
      hostname: runner && runner.hostname,
      online: online,
      path: path
    }
  end

  # Field-for-field the SSE payload, plus `id` (the pagination cursor and the
  # SSE `Last-Event-ID`) and `duration_ms`, which stage events carry and the
  # UI's timeline reads.
  defp log_event_data(%LogEvent{} = e) do
    %{
      id: e.id,
      kind: e.kind,
      stream: e.stream,
      data: e.data,
      stage: LogEvent.rendered_stage(e),
      state: LogEvent.rendered_state(e),
      duration_ms: e.duration_ms,
      turn_id: e.turn_id,
      ts: e.inserted_at
    }
  end

  @doc """
  Add `blocks` — the event's data parsed into the blocks a transcript renders
  — to an event's JSON when requested. Only ACP output events produce
  blocks; other events get `[]`.

  The SSE route's arity, which never carries prompts.
  """
  def put_blocks(json, event, blocks?), do: put_blocks(json, event, blocks?, %{})

  @doc """
  `put_blocks/3` with the turn prompts `?prompts=true` asked for, keyed by
  turn id.

  A turn's `turn`/`started` stage event is the anchor: exactly one per turn,
  already ordered immediately before that turn's output, and carrying `[]`
  today. Filling it costs no synthetic event, so `meta.next_cursor` — which is
  the last row's id — and the page-size accounting are untouched. Fabricating
  an event instead would hand a client a cursor no row has.

  An empty map is today's behaviour exactly.
  """
  def put_blocks(json, _event, false, _prompts), do: json

  def put_blocks(json, %LogEvent{kind: "output"} = ev, true, _prompts) do
    blocks =
      ev
      |> Fountain.Conversations.Blocks.for_event()
      |> Enum.map(&Fountain.Conversations.Blocks.to_json/1)

    Map.put(json, :blocks, blocks)
  end

  def put_blocks(
        json,
        %LogEvent{kind: "stage", stage: "turn", state: "started", turn_id: turn_id},
        true,
        prompts
      )
      when is_map_key(prompts, turn_id) do
    block = Fountain.Conversations.Blocks.to_json(%{kind: :prompt, body: prompts[turn_id]})

    Map.put(json, :blocks, [block])
  end

  def put_blocks(json, _event, true, _prompts), do: Map.put(json, :blocks, [])

  defp event_id(%LogEvent{id: id}), do: id
  defp event_id(nil), do: nil

  defp turn_data(%Turn{} = t) do
    %{
      id: t.id,
      turn_number: t.turn_number,
      prompt: t.prompt,
      status: t.status,
      # The caller's name for the prompt that opened the turn (#1406), or nil.
      client_request_id: t.client_request_id,
      # `user` or `autonomous` (#817); rows from before the column read as user.
      origin: t.origin || "user",
      # The turn ended with a permission request still open (#1635). The
      # request is on GET /api/conversations/{id} as `pending_requests` until
      # somebody answers it or its deadline passes.
      waiting: t.waiting == true,
      exit_code: t.exit_code,
      # Read this before reading exit_code: a turn ended by a service limit can
      # still carry a zero exit from a runtime that answered late (#1732).
      limit_reason: t.limit_reason,
      started_at: t.started_at,
      ended_at: t.ended_at,
      inserted_at: t.inserted_at,
      image_count: length(t.images || []),
      # The end-of-turn figure as the runtime reported it (#827); null when
      # it reported none or the turn predates the column.
      model_selection: t.model_selection,
      usage: turn_usage(t.usage)
    }
  end

  @doc """
  A turn's `usage` field for the API: the end-of-turn figure, or null.

  Null covers the turn-start inference stamp (#1685) as well as a missing
  column. That stamp says whose key the turn runs on and carries no token
  figure, so reporting it here would answer "how many tokens did this turn
  spend" with a zero nobody measured.
  """
  def turn_usage(nil), do: nil

  def turn_usage(%{} = usage) do
    if Turn.inference_stamp_only?(usage), do: nil, else: usage_data(usage)
  end

  @doc "Stored token counts and adapter accounting claims; absent counts remain absent in qualified reports."
  def usage_data(%{} = u) do
    counts =
      if is_map(u["accounting"]) do
        %{} |> put_present(:input, u["input"]) |> put_present(:output, u["output"])
      else
        %{input: u["input"] || 0, output: u["output"] || 0}
      end

    counts
    |> put_present(:accounting, u["accounting"])
    |> put_present(:cache_read, u["cache_read"])
    |> put_present(:cache_write, u["cache_write"])
  end

  defp put_present(map, _k, nil), do: map
  defp put_present(map, k, v), do: Map.put(map, k, v)
end
