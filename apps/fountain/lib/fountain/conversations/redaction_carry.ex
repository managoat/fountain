defmodule Fountain.Conversations.RedactionCarry do
  @moduledoc """
  Holds back the end of a text stream when it could be the start of a
  registered value, so the value reaches `Conversations.log!/1` whole (#2359).

  `Redaction.redact/2` runs once per row, so it only matches a value that is
  whole inside one row. Output arrives in chunks, and the boundaries between
  them fall wherever the transport or the model put them. A value cut by a
  boundary matched in neither row. Both fragments were persisted and
  broadcast, and `turns.reply_text`, which joins a turn's text, stored the
  value whole.

  ## Channels

  A channel is one continuous text stream: `stdout` and `stderr` as raw bytes,
  and on the `acp` stream the text of each chunk kind (`agent_message_chunk`,
  `agent_thought_chunk`, `user_message_chunk`), which is what a client joins
  into a reply. Each channel has its own state.

  ## Keeping row boundaries

  Registered values include identifiers as well as secrets (the conversation
  and sandbox ids, a callback token), so ordinary output ends in the first byte
  of some value all the time: a hex id starting with `e` makes every chunk that
  ends in `e` a candidate. Cutting such a chunk into a row without its last byte
  and a one-byte row after it changed row boundaries almost everywhere, and
  every rewritten line defeats reattach replay dedup.

  So a chunk whose end could begin a value is first held **whole**, as the unit
  that arrived: the raw chunk, or the ACP line byte for byte. When the next
  chunk shows no value crossing into it, the held unit is written unchanged
  and the new chunk is judged on its own. Only when a value (or a prefix of
  one) really does cross the boundary are the two chunks' texts joined, written
  as far as is safe, and the rest kept as a text tail. A held unit is at most
  `max_unit/0` bytes. A larger chunk goes straight to the tail form.

  ## The tail form

  The text is written as far as the cut `hold_from/2` finds, and only the
  unresolved tail after the cut is kept. On `acp` the current line is written
  with that text, or not at all when nothing remains. A match that is already
  whole before the cut is written, and redacted by the writer, at once.

  Any other `acp` line — a tool call, a `tool_call_update`, a plan, or a chunk
  of another kind — is written at once, and releases nothing a channel holds.
  A tool update between two text chunks does not end the reply's text (both
  halves still join into one `reply_text`), so releasing a held chunk there
  would put the fragment the boundary exists to hide into the transcript.
  Cutting the held chunk at that point instead would split its row, and that
  happens at the end of most text runs, which is exactly where a tool call
  follows. The cost is order: at most one held chunk per kind (`max_unit/0`
  bytes, usually a few words) lands after a line it streamed before.

  ## The cut

  The tail is the shortest suffix of the channel's text that is a proper
  prefix of some registered value, at most one byte fewer than the longest. If
  a complete match straddles that point, the cut moves back to the match's
  start, because `:binary.matches/2` prefers the longest value at a position
  and a longer one may be arriving. That adds at most one more value's length.

  Cutting there and redacting each side gives the same result as redacting the
  whole stream. No match of the whole stream crosses the cut: a match that
  would cross it starts inside the held tail. The matches before the cut are
  the ones the whole stream selects, because selection runs left to right and
  none of them reaches past the cut. This is the `SandboxFiles.redact_to_cap`
  argument (#1907) in streaming form.

  ## What is retained, and the fail-safe

  Per channel, and never more whatever the sandbox writes:

    * a held unit of at most `max_unit/0` bytes, copied so it cannot pin a
      larger frame;
    * a tail of at most `max_hold/0` bytes, copied;
    * on `acp`, the session id (at most 256 bytes, else dropped), so a tail
      written at the turn's end still names its session. Nothing else of a
      notification is kept: a tail is written into the *next* chunk's line, or
      at the end into a minimal `session/update`, so an oversized chunk's
      `_meta` is not carried;
    * while the fail-safe below is consuming, remainders of registered values,
      which are bounded by what was registered, not by what the sandbox wrote.

  The tail is at most twice the longest registered value, so only a value
  longer than half of `max_hold/0` can reach the cap. When it would, the
  channel does not keep the tail and does not release it in plaintext. It
  writes `Redaction.placeholder/0` in its place, and remembers the remainder of
  every value the tail could be the start of. What continues one in the
  chunks that follow is dropped. The trade-off is over-redaction: if the tail
  was not in fact a secret's start, some text is shown as the placeholder.

  Everything here is pure. `Output` owns the state and decides when to flush.
  """

  alias Fountain.Conversations.Redaction

  @chunk_kinds ~w(agent_message_chunk agent_thought_chunk user_message_chunk)
  @max_hold 8_192
  @max_unit 4_096
  @max_session 256

  @type channel :: %{
          held: nil | {binary(), binary()},
          tail: binary(),
          consuming: [binary()],
          session: nil | binary()
        }
  @type t :: %{
          raw: %{optional(String.t()) => channel()},
          text: %{optional(String.t()) => channel()}
        }

  @doc "Nothing held."
  @spec new() :: t()
  def new, do: %{raw: %{}, text: %{}}

  @doc "The most tail bytes one channel keeps."
  @spec max_hold() :: pos_integer()
  def max_hold, do: @max_hold

  @doc "The largest chunk a channel holds whole."
  @spec max_unit() :: pos_integer()
  def max_unit, do: @max_unit

  @doc "True when nothing is held and no value is being consumed."
  @spec empty?(t() | nil) :: boolean()
  def empty?(nil), do: true
  def empty?(carry), do: Enum.all?(channels(carry), &idle?/1)

  @doc "The most output bytes (held unit plus tail) any one channel keeps."
  @spec held_bytes(t() | nil) :: non_neg_integer()
  def held_bytes(nil), do: 0

  def held_bytes(carry) do
    carry
    |> channels()
    |> Enum.map(fn channel ->
      held = if channel.held, do: byte_size(elem(channel.held, 0)), else: 0
      held + byte_size(channel.tail)
    end)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  One chunk in: the `{stream, data}` rows that are safe to write now, in order,
  and what is still held.
  """
  @spec feed(t(), String.t(), String.t(), binary()) :: {[{String.t(), binary()}], t()}
  def feed(carry, conversation_id, "acp", line) do
    values = Redaction.lookup(conversation_id)

    case text_chunk(line) do
      {kind, map, text} ->
        channel = Map.get(carry.text, kind, idle())

        if values == [] and idle?(channel) do
          {[{"acp", line}], carry}
        else
          {emits, channel} = advance(channel, values, text, line)
          rows = Enum.map(emits, &{"acp", render(&1, map, text, line)})
          channel = if idle?(channel), do: idle(), else: %{channel | session: session(map)}
          {rows, %{carry | text: Map.put(carry.text, kind, channel)}}
        end

      nil ->
        {[{"acp", line}], carry}
    end
  end

  def feed(carry, conversation_id, stream, data) do
    channel = Map.get(carry.raw, stream, idle())

    case Redaction.patterns(conversation_id) do
      [] when channel.held == nil and channel.tail == "" and channel.consuming == [] ->
        {[{stream, data}], carry}

      patterns ->
        {emits, channel} = advance(channel, patterns, data, data)
        rows = Enum.map(emits, fn {_form, bytes} -> {stream, bytes} end)
        {rows, %{carry | raw: Map.put(carry.raw, stream, channel)}}
    end
  end

  @doc """
  Everything held, as rows to write now. A tail that never became a value is
  not one, so it is written as it is.
  """
  @spec flush(t(), String.t()) :: [{String.t(), binary()}]
  def flush(carry, _conversation_id) do
    text =
      for {kind, channel} <- Enum.sort(carry.text), row <- flush_channel(channel) do
        case row do
          {:unit, line} -> {"acp", line}
          {:text, tail} -> {"acp", encode(minimal(kind, channel.session), tail)}
        end
      end

    raw =
      for {stream, channel} <- Enum.sort(carry.raw),
          {_form, bytes} <- flush_channel(channel),
          do: {stream, bytes}

    text ++ raw
  end

  defp flush_channel(%{held: {unit, _text}}), do: [{:unit, unit}]
  defp flush_channel(%{tail: ""}), do: []
  defp flush_channel(%{tail: tail}), do: [{:text, tail}]

  @doc """
  The byte offset in `text` where the held tail starts; `byte_size(text)` when
  nothing needs holding. `patterns` must be longest first.
  """
  @spec hold_from([binary()], binary()) :: non_neg_integer()
  def hold_from([], text), do: byte_size(text)

  def hold_from([longest | _] = patterns, text) do
    size = byte_size(text)
    firsts = MapSet.new(patterns, &:binary.first/1)

    cut =
      Enum.find(max(size - byte_size(longest) + 1, 0)..(size - 1)//1, size, fn at ->
        MapSet.member?(firsts, :binary.at(text, at)) and
          prefix?(patterns, binary_part(text, at, size - at))
      end)

    # A match the cut lands inside is held whole. Matches do not overlap, so at
    # most one can contain the cut.
    case Enum.find(:binary.matches(text, patterns), &crosses?(&1, cut)) do
      {start, _length} -> start
      nil -> cut
    end
  end

  defp prefix?(patterns, suffix) do
    n = byte_size(suffix)
    Enum.any?(patterns, &(byte_size(&1) > n and binary_part(&1, 0, n) == suffix))
  end

  defp crosses?({start, length}, at), do: start < at and start + length > at

  # ── one channel ───────────────────────────────────────────────────────────

  defp idle, do: %{held: nil, tail: "", consuming: [], session: nil}

  defp idle?(%{held: nil, tail: "", consuming: []}), do: true
  defp idle?(_channel), do: false

  defp channels(%{raw: raw, text: text}), do: Map.values(raw) ++ Map.values(text)

  # One chunk (`text`, arriving as `unit`) through a channel: the rows to write,
  # each `{:unit, bytes}` (a chunk exactly as it arrived) or `{:text, text}`
  # (text to write in the current chunk's form), and the channel after.
  defp advance(%{held: nil, tail: "", consuming: []} = channel, patterns, text, unit) do
    cond do
      hold_from(patterns, text) == byte_size(text) ->
        {[{:unit, unit}], channel}

      byte_size(unit) <= @max_unit ->
        copy = :binary.copy(unit)
        {[], %{channel | held: {copy, if(text == unit, do: copy, else: :binary.copy(text))}}}

      true ->
        tail_step(channel, patterns, text)
    end
  end

  defp advance(%{held: {held_unit, held_text}} = channel, patterns, text, unit) do
    joined = held_text <> text
    boundary = byte_size(held_text)
    cut = hold_from(patterns, joined)

    crossing? =
      cut < boundary or
        (patterns != [] and Enum.any?(:binary.matches(joined, patterns), &crosses?(&1, boundary)))

    if crossing? do
      tail_step(%{channel | held: nil}, patterns, joined)
    else
      {rows, channel} = advance(%{channel | held: nil}, patterns, text, unit)
      {[{:unit, held_unit} | rows], channel}
    end
  end

  defp advance(channel, patterns, text, _unit), do: tail_step(channel, patterns, text)

  # Write as far as the cut, keep the rest. Over the cap, the tail is replaced
  # rather than kept (see "What is retained, and the fail-safe").
  defp tail_step(channel, patterns, data) do
    {data, consuming} = consume(channel.consuming, data)
    text = channel.tail <> data
    cut = hold_from(patterns, text)
    tail = binary_part(text, cut, byte_size(text) - cut)
    out = binary_part(text, 0, cut)
    rows = if out == "", do: [], else: [{:text, out}]

    if byte_size(tail) > @max_hold do
      {rows ++ [{:text, Redaction.placeholder()}],
       %{channel | tail: "", consuming: in_progress(patterns, tail)}}
    else
      {rows, %{channel | tail: :binary.copy(tail), consuming: consuming}}
    end
  end

  # The remainders of every value `tail` could be the start of.
  defp in_progress(patterns, tail) do
    size = byte_size(tail)

    for pattern <- patterns,
        k <- min(byte_size(pattern) - 1, size)..1//-1,
        binary_part(tail, size - k, k) == binary_part(pattern, 0, k),
        uniq: true,
        do: :binary.copy(binary_part(pattern, k, byte_size(pattern) - k))
  end

  # Drop what continues a value the fail-safe already replaced. A remainder
  # the data completes ends it; one the data only begins stays pending.
  defp consume([], data), do: {data, []}

  defp consume(remainders, data) do
    size = byte_size(data)

    results =
      Enum.map(remainders, fn rest ->
        n = :binary.longest_common_prefix([rest, data])

        cond do
          n == byte_size(rest) -> {:done, n}
          n == size -> {:more, binary_part(rest, n, byte_size(rest) - n)}
          true -> :miss
        end
      end)

    pending = for {:more, rest} <- results, do: rest

    skip =
      if pending != [],
        do: size,
        else: Enum.max(for({:done, n} <- results, do: n), fn -> 0 end)

    {binary_part(data, skip, size - skip), pending}
  end

  # ── acp lines ─────────────────────────────────────────────────────────────

  # A row for the current chunk: the line itself when its text is unchanged.
  defp render({:unit, unit}, _map, _text, _line), do: unit
  defp render({:text, text}, _map, text, line), do: line
  defp render({:text, out}, map, _text, _line), do: encode(map, out)

  defp session(%{"params" => %{"sessionId" => id}})
       when is_binary(id) and byte_size(id) <= @max_session,
       do: :binary.copy(id)

  defp session(_map), do: nil

  defp minimal(kind, session) do
    update = %{"sessionUpdate" => kind, "content" => %{"type" => "text"}}
    params = %{"update" => update}
    params = if session, do: Map.put(params, "sessionId", session), else: params
    %{"jsonrpc" => "2.0", "method" => "session/update", "params" => params}
  end

  defp encode(map, text),
    do: Jason.encode!(put_in(map, ["params", "update", "content", "text"], text)) <> "\n"

  # A text chunk, decoded. The substring test keeps the decode off every line
  # that cannot be one, which is most of them.
  defp text_chunk(line) do
    with true <- String.contains?(line, "_chunk\""),
         {:ok,
          %{
            "method" => "session/update",
            "params" => %{
              "update" => %{
                "sessionUpdate" => kind,
                "content" => %{"type" => "text", "text" => text}
              }
            }
          } = map}
         when kind in @chunk_kinds and is_binary(text) <- Jason.decode(line) do
      {kind, map, text}
    else
      _ -> nil
    end
  end
end
