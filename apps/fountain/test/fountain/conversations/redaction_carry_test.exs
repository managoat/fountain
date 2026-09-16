defmodule Fountain.Conversations.RedactionCarryTest do
  @moduledoc """
  The carry's promises (#2359).

  First, however a stream is cut into chunks, and wherever tool lines fall
  between them, redacting what the carry releases row by row gives the same
  text as redacting the stream whole. Second, it never holds more than a
  bounded tail while it does so (review of #2364).

  Checked over every cut of streams built to catch the cases a naive hold
  misses. One value is a prefix of another, so a whole match may still grow.
  Two values overlap, so leftmost selection decides. A value contains a newline
  and a quote, so it escapes in JSON. A value is multi-byte UTF-8.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fountain.Conversations.{Redaction, RedactionCarry}

  @values [
    "SECRETAB-short",
    "SECRETAB-short-and-longer",
    "ABCDEFGH-overlap",
    "overlap-IJKLMNOP",
    "multi\nline \"quoted\" key",
    "clé-secrète-ünïcødé"
  ]

  @stream "a SECRETAB-short-and-longer b SECRETAB-short c ABCDEFGH-overlap-IJKLMNOP " <>
            "d multi\nline \"quoted\" key e clé-secrète-ünïcødé f SECRETAB-shor"

  # A whole chunk, or a tail of twice the longest value less one: the most
  # one channel may hold.
  @bound RedactionCarry.max_unit() + 2 * (@values |> Enum.map(&byte_size/1) |> Enum.max())

  setup do
    conv_id = Ecto.UUID.generate()
    Redaction.put(conv_id, Enum.map(@values, &{"K", &1}))
    on_exit(fn -> Redaction.delete(conv_id) end)
    {:ok, conv_id: conv_id}
  end

  defp run(conv_id, stream, inputs, bound) do
    {rows, carry} =
      Enum.reduce(inputs, {[], RedactionCarry.new()}, fn input, {rows, carry} ->
        {out, carry} = RedactionCarry.feed(carry, conv_id, stream, input)
        assert RedactionCarry.held_bytes(carry) <= bound
        {rows ++ out, carry}
      end)

    rows ++ RedactionCarry.flush(carry, conv_id)
  end

  defp raw(conv_id, pieces) do
    conv_id
    |> run("stdout", pieces, @bound)
    |> Enum.map_join(fn {"stdout", data} -> Redaction.redact(conv_id, data) end)
  end

  defp line(text) do
    update(%{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => text}
    })
  end

  defp tool_line(n),
    do:
      update(%{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "t#{n}",
        "status" => "in_progress"
      })

  defp update(update) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "s", "update" => update}
    }) <> "\n"
  end

  # The text a client joins out of the stored rows: `tools` is the set of piece
  # indexes a tool line follows.
  defp lines(conv_id, pieces, tools \\ MapSet.new()) do
    inputs =
      pieces
      |> Enum.with_index()
      |> Enum.flat_map(fn {piece, i} ->
        if i in tools, do: [line(piece), tool_line(i)], else: [line(piece)]
      end)

    rows = run(conv_id, "acp", inputs, @bound)

    # Every tool line is written exactly once.
    assert Enum.count(rows, fn {"acp", data} -> data =~ "tool_call_update" end) ==
             Enum.count(tools, &(&1 < length(pieces)))

    rows
    |> Enum.map(fn {"acp", data} -> Redaction.redact(conv_id, data) |> Jason.decode!() end)
    |> Enum.map_join(&(get_in(&1, ["params", "update", "content", "text"]) || ""))
  end

  # Cuts on codepoint boundaries: an ACP chunk's text is a JSON string.
  defp codepoints_cut(text, cuts) do
    chars = String.codepoints(text)

    cuts
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.concat([length(chars)])
    |> Enum.map_reduce(0, fn cut, from ->
      {chars |> Enum.slice(from, cut - from) |> Enum.join(), cut}
    end)
    |> elem(0)
  end

  defp bytes_cut(bytes, cuts) do
    cuts
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.concat([byte_size(bytes)])
    |> Enum.map_reduce(0, fn cut, from -> {binary_part(bytes, from, cut - from), cut} end)
    |> elem(0)
  end

  test "every single cut of a raw stream", %{conv_id: conv_id} do
    whole = Redaction.redact(conv_id, @stream)
    refute whole =~ "SECRETAB-short-and"

    for at <- 0..byte_size(@stream) do
      assert raw(conv_id, bytes_cut(@stream, [at])) == whole, "cut at byte #{at}"
    end
  end

  test "every single cut of a message, with a tool line at the cut", %{conv_id: conv_id} do
    whole = Redaction.redact(conv_id, @stream)

    for at <- 0..String.length(@stream) do
      pieces = codepoints_cut(@stream, [at])
      assert lines(conv_id, pieces) == whole, "cut at codepoint #{at}"
      assert lines(conv_id, pieces, MapSet.new([0])) == whole, "tool at codepoint #{at}"
    end
  end

  test "one chunk per byte, and per codepoint with a tool line after each", %{conv_id: conv_id} do
    whole = Redaction.redact(conv_id, @stream)
    pieces = String.codepoints(@stream)
    assert raw(conv_id, for(<<b <- @stream>>, do: <<b>>)) == whole
    assert lines(conv_id, pieces) == whole
    assert lines(conv_id, pieces, MapSet.new(0..(length(pieces) - 1))) == whole
  end

  property "any cuts, with tool lines anywhere between them", %{conv_id: conv_id} do
    whole = Redaction.redact(conv_id, @stream)
    bytes = byte_size(@stream)
    codepoints = String.length(@stream)

    check all(
            byte_cuts <- list_of(integer(0..bytes), max_length: 12),
            codepoint_cuts <- list_of(integer(0..codepoints), max_length: 12),
            tools <- list_of(integer(0..12), max_length: 8)
          ) do
      assert raw(conv_id, bytes_cut(@stream, byte_cuts)) == whole

      text = lines(conv_id, codepoints_cut(@stream, codepoint_cuts), MapSet.new(tools))
      assert text == whole
      for value <- @values, do: refute(text =~ value)
    end
  end

  test "the review's reproduction: a tool update between the halves", %{conv_id: conv_id} do
    Redaction.put(conv_id, [{"K", "abcdefgh"}])
    rows = run(conv_id, "acp", [line("abc"), tool_line(1), line("defgh")], @bound)

    # The tool line goes out first; `abc` waited for `defgh`.
    assert [{"acp", tool}, {"acp", text}] = rows
    assert tool == tool_line(1)
    assert text == line("abcdefgh")
  end

  test "the review's reproduction: a repeated boundary stays bounded", %{conv_id: conv_id} do
    Redaction.put(conv_id, [{"K", "abcdefgh"}])
    pieces = ["abc" | List.duplicate("defghabc", 1_001)]

    # The first line is held whole; from then on only the `abc` tail is.
    rows = run(conv_id, "acp", Enum.map(pieces, &line/1), byte_size(line("abc")))

    # One row per completed value, plus the unfinished `abc` at the flush.
    assert length(rows) == 1_002
    assert List.last(rows) == {"acp", line("abc")}
  end

  test "a line that cannot begin a value is released verbatim at once", %{conv_id: conv_id} do
    data = line("nothing to hold here.")

    assert {[{"acp", ^data}], carry} =
             RedactionCarry.feed(RedactionCarry.new(), conv_id, "acp", data)

    assert RedactionCarry.empty?(carry)
  end

  test "a line of another kind is written at once, and what is held stays whole", %{
    conv_id: conv_id
  } do
    other = tool_line(1)

    {[], carry} =
      RedactionCarry.feed(RedactionCarry.new(), conv_id, "acp", line("ends in SECRET"))

    assert {[{"acp", ^other}], carry} = RedactionCarry.feed(carry, conv_id, "acp", other)
    refute RedactionCarry.empty?(carry)
    assert RedactionCarry.flush(carry, conv_id) == [{"acp", line("ends in SECRET")}]
  end

  test "a chunk that turns out not to begin a value is written as it arrived", %{
    conv_id: conv_id
  } do
    # The session-isolation shape: `live` ends in a byte some value starts
    # with. It is held whole and written unchanged, not as `liv` and `E`.
    Redaction.put(conv_id, [{"K", "Esecret-value"}])
    rows = run(conv_id, "acp", [line("alivE"), line(" and well")], @bound)
    assert rows == [{"acp", line("alivE")}, {"acp", line(" and well")}]

    assert run(conv_id, "stdout", ["alivE", " and well"], @bound) ==
             [{"stdout", "alivE"}, {"stdout", " and well"}]

    assert run(conv_id, "acp", [line("alivE")], @bound) == [{"acp", line("alivE")}]
  end

  test "hold_from/2 holds only a tail that begins a value" do
    patterns = ["abcdefgh"]
    assert RedactionCarry.hold_from(patterns, "xyz") == 3
    assert RedactionCarry.hold_from(patterns, "xyzabc") == 3
    assert RedactionCarry.hold_from(patterns, "xyzabcdefgh") == 11
    assert RedactionCarry.hold_from([], "abc") == 3
  end
end
