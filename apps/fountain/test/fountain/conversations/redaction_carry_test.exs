defmodule Fountain.Conversations.RedactionCarryTest do
  @moduledoc """
  The carry's one promise (#2359): however a stream is cut into chunks,
  redacting what the carry releases, row by row, gives the same text as
  redacting the stream whole.

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

  setup do
    conv_id = Ecto.UUID.generate()
    Redaction.put(conv_id, Enum.map(@values, &{"K", &1}))
    on_exit(fn -> Redaction.delete(conv_id) end)
    {:ok, conv_id: conv_id}
  end

  defp raw(conv_id, pieces) do
    {rows, carry} =
      Enum.reduce(pieces, {[], RedactionCarry.new()}, fn piece, {rows, carry} ->
        {out, carry} = RedactionCarry.feed(carry, conv_id, "stdout", piece)
        {rows ++ out, carry}
      end)

    Enum.map_join(rows ++ RedactionCarry.flush(carry, conv_id), fn {"stdout", data} ->
      Redaction.redact(conv_id, data)
    end)
  end

  defp line(text) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "s",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => text}
        }
      }
    }) <> "\n"
  end

  defp lines(conv_id, pieces) do
    {rows, carry} =
      Enum.reduce(pieces, {[], RedactionCarry.new()}, fn piece, {rows, carry} ->
        {out, carry} = RedactionCarry.feed(carry, conv_id, "acp", line(piece))
        {rows ++ out, carry}
      end)

    rows = rows ++ RedactionCarry.flush(carry, conv_id)

    Enum.map_join(rows, fn {"acp", data} ->
      # What `log!/1` stores, read back the way a client reads it.
      data
      |> then(&Redaction.redact(conv_id, &1))
      |> Jason.decode!()
      |> get_in(["params", "update", "content", "text"])
    end)
  end

  # Cuts on codepoint boundaries: an ACP chunk's text is a JSON string.
  defp graphemes_cut(text, cuts) do
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

  test "every single cut of a message", %{conv_id: conv_id} do
    whole = Redaction.redact(conv_id, @stream)

    for at <- 0..String.length(@stream) do
      assert lines(conv_id, graphemes_cut(@stream, [at])) == whole, "cut at codepoint #{at}"
    end
  end

  test "one chunk per byte and per codepoint", %{conv_id: conv_id} do
    whole = Redaction.redact(conv_id, @stream)
    assert raw(conv_id, for(<<b <- @stream>>, do: <<b>>)) == whole
    assert lines(conv_id, String.codepoints(@stream)) == whole
  end

  property "any number of cuts", %{conv_id: conv_id} do
    whole = Redaction.redact(conv_id, @stream)
    bytes = byte_size(@stream)
    codepoints = String.length(@stream)

    check all(
            byte_cuts <- list_of(integer(0..bytes), max_length: 12),
            codepoint_cuts <- list_of(integer(0..codepoints), max_length: 12)
          ) do
      assert raw(conv_id, bytes_cut(@stream, byte_cuts)) == whole
      assert lines(conv_id, graphemes_cut(@stream, codepoint_cuts)) == whole
    end
  end

  test "a line that cannot begin a value is released verbatim at once", %{conv_id: conv_id} do
    data = line("nothing to hold here.")

    assert {[{"acp", ^data}], carry} =
             RedactionCarry.feed(RedactionCarry.new(), conv_id, "acp", data)

    assert RedactionCarry.empty?(carry)
  end

  test "a line of another kind releases what is held, first", %{conv_id: conv_id} do
    held = line("ends in SECRET")

    other =
      ~s({"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call"}}}\n)

    {[], carry} = RedactionCarry.feed(RedactionCarry.new(), conv_id, "acp", held)
    refute RedactionCarry.empty?(carry)

    assert {[{"acp", ^held}, {"acp", ^other}], carry} =
             RedactionCarry.feed(carry, conv_id, "acp", other)

    assert RedactionCarry.empty?(carry)
  end

  test "hold_from/2 holds only a tail that begins a value" do
    patterns = ["abcdefgh"]
    assert RedactionCarry.hold_from(patterns, "xyz") == 3
    assert RedactionCarry.hold_from(patterns, "xyzabc") == 3
    assert RedactionCarry.hold_from(patterns, "xyzabcdefgh") == 11
    assert RedactionCarry.hold_from([], "abc") == 3
  end
end
