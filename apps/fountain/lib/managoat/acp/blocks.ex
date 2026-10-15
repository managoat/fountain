defmodule Managoat.ACP.Blocks do
  @moduledoc """
  Translate ACP messages into the block maps a transcript renders.

  This is the module that replaces a hand-written dialect parser, and the
  reason it lives beside the peer rather than in a view is the point of
  Fountain's ADR 0014: four proprietary output formats used to be parsed in
  the render path, where a vendor's point release becomes a rendering bug.
  The ACP path parses once, in a module with its own tests, and every client
  reads one parse.

  The block shapes are a wire contract, not a choice made here: they are what
  the transcript renderers already draw, so a client can render an ACP
  transcript and a legacy one with one code path. The README lists them.

  | ACP `session/update` | block |
  |---|---|
  | `agent_message_chunk` | `%{kind: :text}` |
  | `agent_thought_chunk` | `%{kind: :thinking}` |
  | `tool_call` | `%{kind: :tool_use}` |
  | `tool_call_update` | `%{kind: :tool_result}` |
  | `user_message_chunk` | dropped — we already render the prompt |
  | `plan` | `%{kind: :plan, body: entries}` (the full checklist) |
  | `available_commands_update` | dropped — a UI affordance |

  ## Chunks are not messages

  `agent_message_chunk` is a *chunk*: a turn produces many, and each carries a
  fragment of text. We emit one `:text` block per chunk and let the existing
  renderer concatenate adjacent ones, which is what it already does for the
  legacy stream. Buffering them here would mean holding a turn's whole
  assistant message in the peer's memory to produce output that renders
  identically.

  ## Tool calls thread on one id

  A renderer's tool-pairing pass exists because three of the four legacy
  dialects emit a tool call and its result as unrelated top-level events. ACP
  threads
  them on `toolCallId` by construction, so the pairing pass gets the ids it
  wants for free — we map `tool_call` → `:tool_use` with `:id` and
  `tool_call_update` → `:tool_result` with `:tool_id`, and the existing pass
  collapses them.

  A `tool_call_update` only becomes a `:tool_result` once it reports a terminal
  status. In-flight updates (`pending`, `in_progress`) carry progress, not an
  outcome, and turning each one into a result block would render a completed
  tool card several times per call.
  """

  alias Managoat.ACP.Protocol

  @kinds ~w(text thinking tool_use tool_result permission_request raw plan)

  @doc "Every block kind emitted by this library, as wire strings."
  def kinds, do: @kinds

  @doc "The wire form: string keys and kind, with error? renamed to error."
  def to_json(block) do
    Map.new(block, fn
      {:kind, kind} -> {"kind", Atom.to_string(kind)}
      {:error?, value} -> {"error", value}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  @terminal_statuses ~w(completed failed cancelled)

  @doc """
  Translate one stored ndjson line into blocks.

  This is the entry point a render path uses: an owner stores the raw
  protocol line the peer reported, so what is on disk is what the adapter
  actually said.
  """
  @spec from_line(String.t()) :: [map()]
  def from_line(line) do
    case Protocol.classify_line(line) do
      {:notification, "session/update", params} ->
        from_update(params)

      # The one *request* that renders. The agent is blocked on it and a human
      # has to answer, so it belongs inline in the transcript beside the tool
      # call it is about, not on a separate channel a client correlates by hand
      # (#940). Its resolution arrives as a `request` stage event and is paired
      # here on `request_id` — the same pass that already pairs a `tool_result`
      # to its `tool_use` on `tool_id`.
      {:request, id, "session/request_permission", params} ->
        permission_blocks(id, params)

      {:invalid, raw} ->
        [%{kind: :raw, body: raw, summary: "raw"}]

      _ ->
        []
    end
  end

  # `params` is always a map: `Protocol.classify/1` defaults it to `%{}`.
  defp permission_blocks(id, params) do
    call = Map.get(params, "toolCall") || %{}

    [
      %{
        kind: :permission_request,
        request_id: to_string(id),
        name: tool_name(call),
        summary: tool_summary(call),
        # Exactly what the agent offered, in its order. A client must never
        # synthesise an option that is not on this list — the same fail-closed
        # rule `Managoat.ACP.Permissions` follows on the answering side.
        options: Enum.filter(Map.get(params, "options") || [], &is_map/1)
      }
    ]
  end

  @doc """
  Translate the params of one `session/update` notification.

  The update variant lives under `sessionUpdate`; everything else in the map is
  variant-specific.
  """
  @spec from_update(map()) :: [map()]
  def from_update(%{"update" => update}) when is_map(update), do: update_blocks(update)
  def from_update(update) when is_map(update), do: update_blocks(update)
  def from_update(_), do: []

  defp update_blocks(%{"sessionUpdate" => "plan", "entries" => entries}) when is_list(entries) do
    [%{kind: :plan, body: entries}]
  end

  defp update_blocks(%{"_meta" => %{"managoat_acp" => %{"plan" => entries}}}) do
    if is_list(entries), do: [%{kind: :plan, body: entries}], else: []
  end

  defp update_blocks(%{"sessionUpdate" => "agent_message_chunk", "content" => content}) do
    text_block(:text, content)
  end

  defp update_blocks(%{"sessionUpdate" => "agent_thought_chunk", "content" => content}) do
    text_block(:thinking, content)
  end

  defp update_blocks(%{"sessionUpdate" => "tool_call"} = update) do
    input = Map.get(update, "rawInput")

    [
      %{
        kind: :tool_use,
        id: update["toolCallId"],
        name: tool_name(update),
        summary: tool_summary(update),
        body: pretty(input)
      }
    ]
  end

  defp update_blocks(%{"sessionUpdate" => "tool_call_update", "status" => status} = update)
       when status in @terminal_statuses do
    [
      %{
        kind: :tool_result,
        tool_id: update["toolCallId"],
        body: tool_output(update),
        error?: status != "completed"
      }
    ]
  end

  # Non-terminal tool_call_update, user echo, command list, and any
  # variant a future adapter version invents. Dropping an unknown variant is
  # deliberate: the legacy parsers render unrecognised lines as a `:raw` block,
  # which for a well-specified protocol would turn every new notification kind
  # into visible noise in every conversation.
  defp update_blocks(_), do: []

  defp text_block(kind, content) do
    case content_text(content) do
      "" -> []
      text -> [%{kind: kind, body: text}]
    end
  end

  # ACP content blocks are the same shape used by MCP: a tagged map, or a list
  # of them. Only `text` has a rendering here; an image arriving in an assistant
  # chunk is named rather than dropped silently, because a blank block in the
  # transcript reads as a bug in the client.
  defp content_text(content) when is_list(content) do
    content |> Enum.map(&content_text/1) |> Enum.reject(&(&1 == "")) |> Enum.join("")
  end

  defp content_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp content_text(%{"type" => "image"}), do: "[image]"
  defp content_text(%{"type" => "audio"}), do: "[audio]"
  defp content_text(%{"type" => "resource_link", "uri" => uri}) when is_binary(uri), do: uri
  defp content_text(text) when is_binary(text), do: text
  defp content_text(_), do: ""

  defp tool_name(update) do
    # `kind` is ACP's coarse category (read/edit/execute/…); `title` is the
    # human string the agent chose. Prefer the title, fall back to the kind, and
    # never render an empty tool card.
    case {update["title"], update["kind"]} do
      {title, _} when is_binary(title) and title != "" -> title
      {_, kind} when is_binary(kind) and kind != "" -> kind
      _ -> "tool"
    end
  end

  defp tool_summary(update) do
    case update["locations"] do
      [%{"path" => path} | _] when is_binary(path) -> path
      _ -> input_preview(update["rawInput"])
    end
  end

  defp input_preview(input) when is_map(input) and map_size(input) > 0 do
    input
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{truncate(to_display(v), 40)}" end)
    |> truncate(120)
  end

  defp input_preview(_), do: ""

  defp tool_output(update) do
    case update["content"] do
      nil -> pretty(update["rawOutput"])
      content -> Enum.map_join(content, "\n", &tool_content_text/1)
    end
  end

  # A tool result's content is wrapped one level deeper than a message's:
  # `%{"type" => "content", "content" => <content block>}`.
  defp tool_content_text(%{"type" => "content", "content" => inner}), do: content_text(inner)
  defp tool_content_text(%{"type" => "diff", "path" => path}), do: "diff: #{path}"
  defp tool_content_text(other), do: content_text(other)

  defp to_display(v) when is_binary(v), do: v
  defp to_display(v), do: inspect(v)

  defp truncate(s, max) when byte_size(s) > max, do: binary_part(s, 0, max) <> "…"
  defp truncate(s, _max), do: s

  defp pretty(nil), do: ""
  defp pretty(term) when is_binary(term), do: term
  defp pretty(term), do: Jason.encode!(term, pretty: true)
end
