defmodule Managoat.ACP.Tracer do
  @moduledoc """
  Turns `session/update` notifications into OTel tool spans, for every runtime.

  Fountain's claude-only stream tracer bridged one dialect into the turn
  span; three of four runtimes produced no tool-level traces at all, and
  nobody noticed because the gap is invisible from inside a conversation
  (#637). ACP's `tool_call` / `tool_call_update` carry an id and a status for
  every runtime, which is exactly what a tracer keys on — so this module is
  dialect-free and one per protocol, not one per agent.

  Span and attribute names carry a prefix, `new/2`'s `:prefix` option,
  `"acp"` by default. The names below are written with it.

  Span mapping:

  - **`tool_call`** opens a `<prefix>.tool_use` child span, keyed by
    `toolCallId`, named by the same title-then-kind preference the render path
    uses (`Blocks`).
  - **`tool_call_update`** with a terminal status closes the matching span;
    `failed` and `cancelled` mark it as an error. Non-terminal updates are
    progress, not an outcome, and touch nothing.
  - **`agent_message_chunk` / `agent_thought_chunk`** accumulate byte counts,
    surfaced at `finalize/1` as `<prefix>.text_bytes` /
    `<prefix>.thinking_bytes` on the turn span. Chunks are per-delta and a
    turn produces hundreds; one span event each — what the legacy tracer did
    per assistant *message* — would blow through OTel's default event limit
    on the first real turn.
  - **`finalize/1`** closes any span still open as `abandoned` (the runtime
    exited or was interrupted before the matching update) and writes the
    accumulated totals.

  ## What the legacy tracer had that this one drops, on purpose

  Cost and token usage came from claude's proprietary `result` event. ACP's
  `session/prompt` response carries a stop reason and, at protocol v1, an
  unstable usage block that `Managoat.ACP.Usage` reads at turn end; the
  tracer does not put it on the span — dropped explicitly rather than
  silently (#637). If a dashboard needs it back, the source is the `:done`
  report, not this module.

  All functions no-op on `nil`, so the caller keeps a `nil` tracer for turns
  that trace nothing, without branching. The OpenTelemetry *API* is the only
  dependency: with no SDK started every span call is a no-op.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias Managoat.ACP.Protocol

  defstruct turn_span_ctx: nil,
            prefix: "acp",
            open_tool_spans: %{},
            text_bytes: 0,
            thinking_bytes: 0,
            tool_calls: 0

  @type t :: %__MODULE__{}

  @terminal_statuses ~w(completed failed cancelled)

  @doc """
  Create a tracer attached to `turn_span_ctx`.

  `prefix:` names the spans and attributes (`<prefix>.tool_use`,
  `<prefix>.tool_name`, …); the default is `"acp"`. A host with dashboards
  built on another prefix passes its own.
  """
  @spec new(term(), keyword()) :: t()
  def new(turn_span_ctx, opts \\ []) do
    %__MODULE__{turn_span_ctx: turn_span_ctx, prefix: Keyword.get(opts, :prefix, "acp")}
  end

  @doc """
  Feed one stored protocol line — the same ndjson the `acp` log stream holds.

  Anything that is not a `session/update` notification (responses, requests,
  an adapter's stray non-JSON output) traces nothing.
  """
  @spec handle_line(t() | nil, binary()) :: t() | nil
  def handle_line(nil, _line), do: nil

  def handle_line(%__MODULE__{} = tracer, line) when is_binary(line) do
    case Protocol.classify_line(line) do
      {:notification, "session/update", params} -> handle_update(tracer, params)
      _ -> tracer
    end
  end

  @doc """
  Close abandoned tool spans and write the accumulated totals to the turn span.

  Call on every way a turn can end, before the turn span itself is ended.
  """
  @spec finalize(t() | nil) :: :ok
  def finalize(nil), do: :ok

  def finalize(%__MODULE__{} = tracer) do
    Tracer.set_current_span(tracer.turn_span_ctx)
    Tracer.set_attribute(attr(tracer, "text_bytes"), tracer.text_bytes)
    Tracer.set_attribute(attr(tracer, "thinking_bytes"), tracer.thinking_bytes)
    Tracer.set_attribute(attr(tracer, "tool_calls"), tracer.tool_calls)

    Enum.each(tracer.open_tool_spans, fn {_id, span_ctx} ->
      Tracer.set_current_span(span_ctx)
      Tracer.set_attribute(attr(tracer, "tool_status"), "abandoned")
      Tracer.set_status(OpenTelemetry.status(:error, "turn ended with open tool call"))
      Tracer.end_span(span_ctx)
    end)

    Tracer.set_current_span(tracer.turn_span_ctx)
    :ok
  end

  # ── update handlers ───────────────────────────────────────────────────────

  # The variant lives under "update"; tolerate bare params exactly as the
  # render path does (`Blocks.from_update/1`).
  defp handle_update(tracer, %{"update" => update}) when is_map(update),
    do: update_span(tracer, update)

  # `classify_line/1` guarantees params is a map, so bare params is the only
  # other shape — tolerated exactly as the render path does (`Blocks.from_update/1`).
  defp handle_update(tracer, update), do: update_span(tracer, update)

  defp update_span(tracer, %{"sessionUpdate" => "tool_call", "toolCallId" => id} = update)
       when is_binary(id) do
    # A second tool_call on an id that is already open is a re-announcement
    # (some adapters resend the call with its first status change); reopening
    # would leak the original span.
    if Map.has_key?(tracer.open_tool_spans, id) do
      tracer
    else
      Tracer.set_current_span(tracer.turn_span_ctx)

      span_ctx =
        Tracer.start_span(attr(tracer, "tool_use"), %{
          attributes: %{
            attr(tracer, "tool_name") => tool_name(update),
            attr(tracer, "tool_id") => id,
            attr(tracer, "tool_kind") => Map.get(update, "kind", "")
          }
        })

      %{
        tracer
        | open_tool_spans: Map.put(tracer.open_tool_spans, id, span_ctx),
          tool_calls: tracer.tool_calls + 1
      }
    end
  end

  defp update_span(
         tracer,
         %{"sessionUpdate" => "tool_call_update", "toolCallId" => id, "status" => status}
       )
       when status in @terminal_statuses do
    case Map.pop(tracer.open_tool_spans, id) do
      {nil, _} ->
        tracer

      {span_ctx, remaining} ->
        Tracer.set_current_span(span_ctx)
        Tracer.set_attribute(attr(tracer, "tool_status"), status)

        if status != "completed" do
          Tracer.set_status(OpenTelemetry.status(:error, "tool #{status}"))
        end

        Tracer.end_span(span_ctx)
        Tracer.set_current_span(tracer.turn_span_ctx)
        %{tracer | open_tool_spans: remaining}
    end
  end

  defp update_span(tracer, %{"sessionUpdate" => "agent_message_chunk", "content" => content}) do
    %{tracer | text_bytes: tracer.text_bytes + content_bytes(content)}
  end

  defp update_span(tracer, %{"sessionUpdate" => "agent_thought_chunk", "content" => content}) do
    %{tracer | thinking_bytes: tracer.thinking_bytes + content_bytes(content)}
  end

  defp update_span(tracer, _update), do: tracer

  # ── helpers ───────────────────────────────────────────────────────────────

  defp attr(%__MODULE__{prefix: prefix}, name), do: prefix <> "." <> name

  # Same preference as the render path: the human title, then ACP's coarse
  # kind, never an empty name.
  defp tool_name(update) do
    case {update["title"], update["kind"]} do
      {title, _} when is_binary(title) and title != "" -> title
      {_, kind} when is_binary(kind) and kind != "" -> kind
      _ -> "tool"
    end
  end

  defp content_bytes(content) when is_list(content),
    do: content |> Enum.map(&content_bytes/1) |> Enum.sum()

  defp content_bytes(%{"type" => "text", "text" => text}) when is_binary(text),
    do: byte_size(text)

  defp content_bytes(text) when is_binary(text), do: byte_size(text)
  defp content_bytes(_), do: 0
end
