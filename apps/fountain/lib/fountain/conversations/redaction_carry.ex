defmodule Fountain.Conversations.RedactionCarry do
  @moduledoc """
  Holds back sandbox output whose end could be the start of a registered value,
  so the value reaches `Conversations.log!/1` whole (#2359).

  `Redaction.redact/2` runs once per row, so it only matches a value that is
  whole inside one row. Output arrives in chunks, and the boundaries between
  them fall wherever the transport or the model put them. A value cut by a
  boundary matched in neither row. Both fragments were persisted and
  broadcast, and `turns.reply_text`, which joins a turn's text, stored the
  value whole.

  ## What is held

  Only a tail that is a proper prefix of some registered value: at most one
  byte fewer than the longest value, plus any whole match that tail overlaps,
  because `:binary.matches/2` prefers the longest value at a position and a
  longer value may be about to arrive. Output that cannot be a value's start
  is released at once. A conversation with nothing registered holds nothing.

  Cutting at that point and redacting each side gives the same result as
  redacting the whole stream. No match of the whole stream crosses the cut:
  a match that would cross it starts inside the held tail. The matches before
  the cut are the ones the whole stream selects, because selection runs left
  to right and none of them reaches past the cut. This is the
  `SandboxFiles.redact_to_cap` argument (#1907) in streaming form: move the cut
  back to a match's start, never forward past a fragment.

  ## Two shapes of stream

  `stdout` and `stderr` rows are raw bytes, so their tail bytes are held and
  prepended to the stream's next chunk.

  An `acp` row is one JSON-RPC line, and holding bytes of it would cut the
  frame. The carry therefore reads the decoded text of consecutive
  `*_message_chunk` / `agent_thought_chunk` lines and holds **whole lines**. A
  line whose text does not end in a possible prefix is written byte for byte,
  so reattach replay dedup (`TurnMachine`, which matches rows by exact content)
  keeps working. Only when a value really spans lines are those lines written
  as one row: the first line with the joined text. Any other line releases
  what is held first, so the transcript keeps its order.

  Everything here is pure. `Output` owns the state and decides when to flush.
  """

  alias Fountain.Conversations.Redaction

  @chunk_kinds ~w(agent_message_chunk agent_thought_chunk user_message_chunk)

  @type held_lines :: nil | %{kind: String.t(), lines: [{binary(), map(), binary()}]}
  @type t :: %{raw: %{optional(String.t()) => binary()}, lines: held_lines()}

  @doc "Nothing held."
  @spec new() :: t()
  def new, do: %{raw: %{}, lines: nil}

  @doc "True when nothing is held."
  @spec empty?(t() | nil) :: boolean()
  def empty?(nil), do: true

  def empty?(%{raw: raw, lines: lines}),
    do: is_nil(lines) and Enum.all?(raw, &(elem(&1, 1) == ""))

  @doc """
  One chunk in: the `{stream, data}` rows that are safe to write now, in order,
  and what is still held.
  """
  @spec feed(t(), String.t(), String.t(), binary()) :: {[{String.t(), binary()}], t()}
  def feed(carry, conversation_id, "acp", line) do
    case Redaction.lookup(conversation_id) do
      [] when is_nil(carry.lines) ->
        {[{"acp", line}], carry}

      values ->
        {out, held} = feed_line(carry.lines, values, line)
        {Enum.map(out, &{"acp", &1}), %{carry | lines: held}}
    end
  end

  def feed(carry, conversation_id, stream, data) do
    held = Map.get(carry.raw, stream, "")

    case Redaction.patterns(conversation_id) do
      [] when held == "" ->
        {[{stream, data}], carry}

      patterns ->
        text = held <> data
        cut = hold_from(patterns, text)
        rest = binary_part(text, cut, byte_size(text) - cut)
        out = if cut == 0, do: [], else: [{stream, binary_part(text, 0, cut)}]
        {out, %{carry | raw: Map.put(carry.raw, stream, rest)}}
    end
  end

  @doc "Everything held, as rows to write now. Lines a value spans are still joined."
  @spec flush(t(), String.t()) :: [{String.t(), binary()}]
  def flush(carry, conversation_id) do
    lines =
      case carry.lines do
        nil ->
          []

        %{lines: lines} ->
          lines |> emit(Redaction.lookup(conversation_id)) |> Enum.map(&{"acp", &1})
      end

    raw = for {stream, bytes} <- Enum.sort(carry.raw), bytes != "", do: {stream, bytes}
    lines ++ raw
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

  # ── acp lines ─────────────────────────────────────────────────────────────

  defp feed_line(held, values, line) do
    case text_chunk(line) do
      {kind, map, text} when values != [] ->
        {released, pending} =
          case held do
            %{kind: ^kind, lines: lines} -> {[], lines}
            _ -> {release(held, values), []}
          end

        {out, rest} = settle(pending ++ [{line, map, text}], values)
        {released ++ out, if(rest == [], do: nil, else: %{kind: kind, lines: rest})}

      _other ->
        {release(held, values) ++ [line], nil}
    end
  end

  defp release(nil, _values), do: []
  defp release(%{lines: lines}, values), do: emit(lines, values)

  # The lines that are safe to write, and the lines still held. The cut moves
  # back to the start of the line it falls in, and again while a match
  # crosses that start, so no value is split between what is written and
  # what waits.
  defp settle(lines, values) do
    {text, starts} = texts(lines)
    ends = Enum.map(Enum.zip(lines, starts), fn {{_, _, t}, at} -> at + byte_size(t) end)
    matches = :binary.matches(text, values)

    case held_index(hold_from(values, text), starts, ends, matches) do
      nil ->
        {emit(lines, values), []}

      index ->
        {ready, rest} = Enum.split(lines, index)
        {emit(ready, values), rest}
    end
  end

  defp held_index(cut, starts, ends, matches) do
    with index when is_integer(index) <- Enum.find_index(ends, &(&1 > cut)) do
      start = Enum.at(starts, index)

      case Enum.find(matches, &crosses?(&1, start)) do
        {earlier, _length} -> held_index(earlier, starts, ends, matches)
        nil -> index
      end
    end
  end

  defp crosses?({start, length}, at), do: start < at and start + length > at

  # Lines a match crosses are written as one row; every other line verbatim.
  defp emit([], _values), do: []

  defp emit(lines, values) do
    {text, starts} = texts(lines)
    matches = if values == [], do: [], else: :binary.matches(text, values)

    lines
    |> Enum.zip(starts)
    |> Enum.reduce([], fn
      {line, start}, [group | groups] ->
        if Enum.any?(matches, &crosses?(&1, start)),
          do: [[line | group] | groups],
          else: [[line], group | groups]

      {line, _start}, [] ->
        [[line]]
    end)
    |> Enum.reverse()
    |> Enum.map(&(&1 |> Enum.reverse() |> join()))
  end

  defp join([{line, _map, _text}]), do: line

  defp join([{_line, map, _text} | _] = group) do
    text = Enum.map_join(group, &elem(&1, 2))
    Jason.encode!(put_in(map, ["params", "update", "content", "text"], text)) <> "\n"
  end

  defp texts(lines) do
    {starts, _size} =
      Enum.map_reduce(lines, 0, fn {_line, _map, text}, at -> {at, at + byte_size(text)} end)

    {Enum.map_join(lines, &elem(&1, 2)), starts}
  end

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
