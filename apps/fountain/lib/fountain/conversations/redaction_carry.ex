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
    * while the fail-safe below is consuming, at most `max_continuations/0`
      `{value index, offset}` pairs and three integers. The values themselves
      stay in the registry; nothing of them is copied.

  The tail is at most twice the longest registered value, so only a value
  longer than half of `max_hold/0` can reach the cap. When it would, the
  channel does not keep the tail and does not release it in plaintext. It
  writes `Redaction.placeholder/0` in its place, and remembers where in each
  registered value the tail could have stopped. What continues one in the
  chunks that follow is dropped. When there are too many such places (a value
  that overlaps itself, like a run of one byte, has one per byte) or the
  registry changes before the value finishes, it stops tracking them and drops
  as many bytes as the longest continuation could still need. That count can
  run out inside a codepoint, and every row is written as text (JSON on `acp`,
  a PostgreSQL `text` column on all of them), so the rest of the codepoint is
  dropped with it. The trade-off is over-redaction: if the tail was not in
  fact a secret's start, some text is shown as the placeholder, or dropped.

  Everything here is pure. `Output` owns the state and decides when to flush.
  """

  alias Fountain.Conversations.Redaction

  @chunk_kinds ~w(agent_message_chunk agent_thought_chunk user_message_chunk)
  @max_hold 8_192
  @max_unit 4_096
  @max_session 256
  @max_continuations 64

  @type channel :: %{
          held: nil | {binary(), binary()},
          tail: binary(),
          consuming: nil | consuming(),
          session: nil | binary()
        }
  @typedoc """
  The fail-safe's continuations: `{index, offset}` pairs into the value list
  whose `:erlang.phash2/1` is `fingerprint`, or `nil` pairs once only a count
  of bytes to drop (`skip`, the longest remaining continuation) is kept.
  """
  @type consuming :: %{
          fingerprint: non_neg_integer(),
          pairs: nil | [{non_neg_integer(), pos_integer()}],
          skip: non_neg_integer()
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

  @doc "The most exact continuations the fail-safe tracks before it only counts."
  @spec max_continuations() :: pos_integer()
  def max_continuations, do: @max_continuations

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
      [] when channel.held == nil and channel.tail == "" and channel.consuming == nil ->
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

  defp idle, do: %{held: nil, tail: "", consuming: nil, session: nil}

  defp idle?(%{held: nil, tail: "", consuming: nil}), do: true
  defp idle?(_channel), do: false

  defp channels(%{raw: raw, text: text}), do: Map.values(raw) ++ Map.values(text)

  # One chunk (`text`, arriving as `unit`) through a channel: the rows to write,
  # each `{:unit, bytes}` (a chunk exactly as it arrived) or `{:text, text}`
  # (text to write in the current chunk's form), and the channel after.
  defp advance(%{held: nil, tail: "", consuming: nil} = channel, patterns, text, unit) do
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
    {rest, consuming} = consume(channel.consuming, patterns, data)
    data = if byte_size(rest) < byte_size(data), do: to_codepoint(rest), else: data
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

  # Where each value could have been cut off at the end of `tail`: `{i, k}` when
  # `tail` ends with the first `k` bytes of value `i`. Past
  # `@max_continuations` it stops listing them and keeps only `skip`, the most
  # bytes any continuation still needs, which is the longest value's length
  # less its shortest matching prefix.
  defp in_progress(patterns, tail) do
    size = byte_size(tail)

    {pairs, skip} =
      patterns
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {pattern, i}, {pairs, skip} ->
        Enum.reduce_while(1..min(byte_size(pattern) - 1, size)//1, {pairs, skip}, fn k,
                                                                                     {pairs, skip} ->
          if binary_part(tail, size - k, k) == binary_part(pattern, 0, k) do
            skip = max(skip, byte_size(pattern) - k)

            # Once over the cap, the shortest matching prefix already gave this
            # value its longest remainder; the rest of its offsets add nothing.
            if is_list(pairs) and length(pairs) < @max_continuations,
              do: {:cont, {[{i, k} | pairs], skip}},
              else: {:halt, {nil, skip}}
          else
            {:cont, {pairs, skip}}
          end
        end)
      end)

    if pairs == [],
      do: nil,
      else: %{fingerprint: :erlang.phash2(patterns), pairs: pairs, skip: skip}
  end

  # Drop what continues a value the fail-safe already replaced.
  #
  # With pairs: a continuation the data completes ends there; one the data only
  # begins stays pending; the most any of them consumed is dropped. Without
  # pairs, or when the registry is no longer the list the pairs index into,
  # `skip` bytes are dropped outright. That is safe because every value that
  # could have been cut off in the replaced tail needs at most `skip` more
  # bytes: `skip` is the largest remainder over all of them, and it only ever
  # counts down by bytes actually dropped. It errs toward dropping output that
  # was not a secret, never toward writing one.
  defp consume(nil, _patterns, data), do: {data, nil}

  defp consume(%{pairs: pairs, fingerprint: fingerprint} = consuming, patterns, data)
       when is_list(pairs) do
    if :erlang.phash2(patterns) == fingerprint do
      consume_pairs(consuming, List.to_tuple(patterns), data)
    else
      consume(%{consuming | pairs: nil}, patterns, data)
    end
  end

  defp consume(%{skip: skip}, _patterns, data) do
    dropped = min(skip, byte_size(data))
    rest = binary_part(data, dropped, byte_size(data) - dropped)
    left = skip - dropped
    {rest, if(left == 0, do: nil, else: %{fingerprint: 0, pairs: nil, skip: left})}
  end

  # The count is in bytes, so it can run out inside a codepoint, and what is
  # left would not be text: `Jason.encode!` raises on it for `acp`, and the
  # insert into `log_events.data` does for `stdout` and `stderr`. The rest of
  # that codepoint (at most three continuation bytes) is dropped as well. This
  # runs only on a chunk `consume/3` cut. A raw chunk the transport cut inside
  # a codepoint is not the carry's doing, and is left as it arrived. A chunk
  # that is whole UTF-8 cannot end inside a codepoint, so nothing reaches into
  # the next chunk. A value matched through pairs ends where the value does,
  # which in valid text is already a codepoint's end.
  defp to_codepoint(<<2::2, _::6, rest::binary>>), do: to_codepoint(rest)
  defp to_codepoint(data), do: data

  defp consume_pairs(consuming, patterns, data) do
    size = byte_size(data)

    results =
      Enum.map(consuming.pairs, fn {i, k} ->
        pattern = elem(patterns, i)
        remaining = byte_size(pattern) - k
        n = :binary.longest_common_prefix([binary_part(pattern, k, remaining), data])

        cond do
          n == remaining -> {:done, n}
          n == size -> {:more, {i, k + n}}
          true -> :miss
        end
      end)

    pending =
      results
      |> Enum.flat_map(fn
        {:more, pair} -> [pair]
        _ -> []
      end)
      |> Enum.uniq()

    dropped =
      if pending != [],
        do: size,
        else: Enum.max(for({:done, n} <- results, do: n), fn -> 0 end)

    rest = binary_part(data, dropped, size - dropped)
    skip = consuming.skip - min(consuming.skip, dropped)

    {rest, if(pending == [], do: nil, else: %{consuming | pairs: pending, skip: max(skip, 1)})}
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
