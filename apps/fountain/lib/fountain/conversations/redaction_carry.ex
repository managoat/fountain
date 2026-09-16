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
  into a reply. Each channel keeps its own tail.

  A chunk's text is written as far as the cut `hold_from/2` finds, and only
  the unresolved tail after the cut is kept. On `acp` the chunk line is
  written with that shorter text, or not at all when nothing remains. It is
  written byte for byte when nothing was held before and nothing is held now,
  which is almost always, so reattach replay dedup (which matches rows by exact
  content) keeps working.

  Any other `acp` line — a tool call, a `tool_call_update`, a plan — is
  written at once and does **not** release a text tail. A tool update between
  two text chunks does not end the reply's text (both halves still join into
  one `reply_text`), so a tail flushed at that line would put the fragment the
  boundary exists to hide into the transcript. The cost is order: at most a
  tail's worth of text lands after a line it streamed before. What is written
  before the tail resolves cannot contain a fragment: a tool line carries no
  reply text, and the text written up to the cut contains none by the argument
  below.

  ## The cut

  The tail is the shortest suffix of the channel's text that is a proper
  prefix of some registered value. It is at most one byte fewer than the
  longest value. If a complete match straddles that point, the cut moves back
  to the match's start, because `:binary.matches/2` prefers the longest value
  at a position and a longer one may be arriving. That adds at most one more
  value's length. A match that is already whole before the cut is written, and
  redacted by the writer, at once; nothing behind a resolved match is kept.

  Cutting there and redacting each side gives the same result as redacting the
  whole stream. No match of the whole stream crosses the cut: a match that
  would cross it starts inside the held tail. The matches before the cut are
  the ones the whole stream selects, because selection runs left to right and
  none of them reaches past the cut. This is the `SandboxFiles.redact_to_cap`
  argument (#1907) in streaming form.

  ## The bound, and the fail-safe

  A channel never holds more than `max_hold/0` bytes, whatever the sandbox
  writes. The tail above is at most twice the longest registered value, so
  only a value longer than half the cap can reach it. When it would, the
  channel does not hold the tail and does not release it in plaintext. It
  writes `Redaction.placeholder/0` in its place, and remembers every value the
  tail could be the start of. The chunks that follow are checked against those
  values' remainders, and what continues one is dropped. The trade-off is
  over-redaction: if the tail was not in fact a secret's start, some text is
  shown as the placeholder. That output was, by construction, the first
  several kilobytes of a registered value.

  Everything here is pure. `Output` owns the state and decides when to flush.
  """

  alias Fountain.Conversations.Redaction

  @chunk_kinds ~w(agent_message_chunk agent_thought_chunk user_message_chunk)
  @max_hold 8_192

  @type channel :: %{
          required(:tail) => binary(),
          required(:consuming) => [binary()],
          optional(:template) => map()
        }
  @type t :: %{
          raw: %{optional(String.t()) => channel()},
          text: %{optional(String.t()) => channel()}
        }

  @doc "Nothing held."
  @spec new() :: t()
  def new, do: %{raw: %{}, text: %{}}

  @doc "The most bytes one channel holds."
  @spec max_hold() :: pos_integer()
  def max_hold, do: @max_hold

  @doc "True when nothing is held and no value is being consumed."
  @spec empty?(t() | nil) :: boolean()
  def empty?(nil), do: true
  def empty?(carry), do: Enum.all?(channels(carry), &idle?/1)

  @doc "The largest tail any one channel holds, in bytes."
  @spec held_bytes(t() | nil) :: non_neg_integer()
  def held_bytes(nil), do: 0

  def held_bytes(carry),
    do: carry |> channels() |> Enum.map(&byte_size(&1.tail)) |> Enum.max(fn -> 0 end)

  @doc """
  One chunk in: the `{stream, data}` rows that are safe to write now, in order,
  and what is still held.
  """
  @spec feed(t(), String.t(), String.t(), binary()) :: {[{String.t(), binary()}], t()}
  def feed(carry, conversation_id, "acp", line) do
    with {kind, map, text} <- text_chunk(line),
         channel = Map.get(carry.text, kind, idle()),
         values = Redaction.lookup(conversation_id),
         false <- values == [] and idle?(channel) do
      {out, channel} = step(channel, values, text)

      rows =
        cond do
          out == text -> [line]
          out == "" -> []
          true -> [encode(map, out)]
        end

      channel = Map.put(channel, :template, map)
      {Enum.map(rows, &{"acp", &1}), %{carry | text: Map.put(carry.text, kind, channel)}}
    else
      _verbatim -> {[{"acp", line}], carry}
    end
  end

  def feed(carry, conversation_id, stream, data) do
    channel = Map.get(carry.raw, stream, idle())

    case Redaction.patterns(conversation_id) do
      [] when channel.tail == "" and channel.consuming == [] ->
        {[{stream, data}], carry}

      patterns ->
        {out, channel} = step(channel, patterns, data)
        rows = if out == "", do: [], else: [{stream, out}]
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
      for {_kind, %{tail: tail, template: map}} <- Enum.sort(carry.text),
          tail != "",
          do: {"acp", encode(map, tail)}

    raw = for {stream, %{tail: tail}} <- Enum.sort(carry.raw), tail != "", do: {stream, tail}
    text ++ raw
  end

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

  defp idle, do: %{tail: "", consuming: []}

  defp idle?(%{tail: "", consuming: []}), do: true
  defp idle?(_channel), do: false

  defp channels(%{raw: raw, text: text}), do: Map.values(raw) ++ Map.values(text)

  # What can be written now, and the channel after. Over the cap, the tail is
  # replaced rather than kept (see "The bound, and the fail-safe").
  defp step(channel, patterns, data) do
    {data, consuming} = consume(channel.consuming, data)
    text = channel.tail <> data
    cut = hold_from(patterns, text)
    tail = binary_part(text, cut, byte_size(text) - cut)
    out = binary_part(text, 0, cut)

    if byte_size(tail) > @max_hold do
      {out <> Redaction.placeholder(),
       %{channel | tail: "", consuming: in_progress(patterns, tail)}}
    else
      {out, %{channel | tail: tail, consuming: consuming}}
    end
  end

  # The remainders of every value `tail` could be the start of.
  defp in_progress(patterns, tail) do
    size = byte_size(tail)

    for pattern <- patterns,
        k <- min(byte_size(pattern) - 1, size)..1//-1,
        binary_part(tail, size - k, k) == binary_part(pattern, 0, k),
        uniq: true,
        do: binary_part(pattern, k, byte_size(pattern) - k)
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
