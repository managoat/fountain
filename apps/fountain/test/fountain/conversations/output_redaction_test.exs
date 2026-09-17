defmodule Fountain.Conversations.OutputRedactionTest do
  @moduledoc """
  A registered value must not reach the transcript because the stream broke
  inside it (#2359).

  `Conversations.log!/1` redacts each row on its own, and sandbox output
  arrives in chunks whose boundaries nobody chooses: a model's reply as many
  `agent_message_chunk` lines, a process's stdout and stderr as whatever bytes
  the transport delivered. A value split across two rows matched in neither,
  and both fragments were persisted and broadcast — and `turns.reply_text`,
  which joins a turn's text blocks, then stored it whole.

  Driven through `Output.log/4`, the per-chunk writer every sandbox stream
  goes through, with a synthetic credential registered the way the server
  registers the sandbox env.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{Blocks, Output, Redaction, RedactionCarry}

  @secret "sk-synthetic-2359-a1b2c3d4e5f6g7h8i9j0"

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id)
    turn = insert_turn(conv, status: "running")
    Redaction.put(conv.id, [{"SYNTHETIC_API_KEY", @secret}])
    on_exit(fn -> Redaction.delete(conv.id) end)

    ctx = %{conversation_id: conv.id, turn_id: turn.id, user_id: user.id}
    {:ok, conv: conv, turn: turn, ctx: ctx}
  end

  defp rows(conv_id) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "output",
        order_by: e.id
      )
    )
  end

  defp chunk(text, kind \\ "agent_message_chunk") do
    "session/update"
    |> Managoat.ACP.Protocol.notification(%{
      sessionId: "sess-2359",
      update: %{sessionUpdate: kind, content: %{type: "text", text: text}}
    })
    |> IO.iodata_to_binary()
  end

  defp tool_update(id, status) do
    "session/update"
    |> Managoat.ACP.Protocol.notification(%{
      sessionId: "sess-2359",
      update: %{sessionUpdate: "tool_call_update", toolCallId: id, status: status}
    })
    |> IO.iodata_to_binary()
  end

  defp feed(output, ctx, stream, pieces),
    do: Enum.reduce(pieces, output, &Output.log(&2, ctx, stream, &1))

  defp split(value, at),
    do: {binary_part(value, 0, at), binary_part(value, at, byte_size(value) - at)}

  defp stored_text(conv_id), do: conv_id |> rows() |> Blocks.assistant_text()

  defp stored_bytes(conv_id, stream),
    do: conv_id |> rows() |> Enum.filter(&(&1.stream == stream)) |> Enum.map_join(& &1.data)

  describe "a value split across agent_message_chunk rows" do
    test "is redacted in the stored transcript and in reply_text", %{ctx: ctx, turn: turn} do
      {head, tail} = split(@secret, 13)

      %Output{bytes: 0}
      |> feed(ctx, "acp", [chunk("the key is " <> head), chunk(tail <> " — keep it safe")])
      |> Output.flush()

      text = stored_text(ctx.conversation_id)
      refute text =~ @secret
      assert text == "the key is #{Redaction.placeholder()} — keep it safe"

      refute Conversations._unsafe_turn_reply_text(turn) =~ @secret

      for row <- rows(ctx.conversation_id), do: refute(row.data =~ head)
    end

    test "is redacted in what subscribers were sent", %{ctx: ctx} do
      Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{ctx.conversation_id}")
      {head, tail} = split(@secret, 5)

      %Output{bytes: 0}
      |> feed(ctx, "acp", [chunk("key: " <> head), chunk(tail)])
      |> Output.flush()

      frames = collect_frames()
      refute frames |> Enum.flat_map(&Blocks.for_event/1) |> Enum.map_join(& &1.body) =~ @secret
      refute Enum.any?(frames, &(&1.data =~ head))
    end

    test "is redacted however many chunks the value is cut into", %{ctx: ctx} do
      pieces = for <<byte <- @secret>>, do: chunk(<<byte>>)

      %Output{bytes: 0}
      |> feed(ctx, "acp", [chunk("[") | pieces] ++ [chunk("]")])
      |> Output.flush()

      assert stored_text(ctx.conversation_id) == "[#{Redaction.placeholder()}]"
    end

    test "a tool update between the halves does not release the first half", %{
      ctx: ctx,
      turn: turn
    } do
      # The review's reproduction: `abc`, an in-progress tool_call_update,
      # `defgh`. Flushing the text tail at the tool line wrote `abc` in the
      # clear, and the reply text joined it to `defgh` again.
      Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{ctx.conversation_id}")
      Redaction.put(ctx.conversation_id, [{"SHORT_KEY", "abcdefgh"}])
      update = tool_update("t1", "in_progress")

      %Output{bytes: 0}
      |> feed(ctx, "acp", [chunk("abc"), update, chunk("defgh")])
      |> Output.flush()

      frames = collect_frames()
      stored = rows(ctx.conversation_id)

      # The tool line is not held back behind the text tail.
      assert [^update | _] = Enum.map(stored, & &1.data)

      for events <- [stored, frames] do
        text = Blocks.assistant_text(events)
        refute text =~ "abcdefgh"
        refute text =~ "abc"
        assert text == Redaction.placeholder()

        # Nor across any consecutive text frames.
        pieces = events |> Enum.flat_map(&Blocks.for_event/1) |> Enum.map(& &1.body)
        refute Enum.join(pieces) =~ "abcdefgh"
      end

      refute (Conversations._unsafe_turn_reply_text(turn) || "") =~ "abc"
    end

    test "flush/1 writes what is held, under the turn it arrived in", %{ctx: ctx, turn: turn} do
      {head, _tail} = split(@secret, 10)

      # Held whole: a small line keeps its boundaries and its bytes.
      output = Output.log(%Output{bytes: 0}, ctx, "acp", chunk("ends with " <> head))
      assert rows(ctx.conversation_id) == []

      %Output{carry: nil} = Output.flush(output)
      assert [row] = rows(ctx.conversation_id)
      assert {row.turn_id, row.data} == {turn.id, chunk("ends with " <> head)}
    end

    test "output for another turn writes what is held first, under its own turn", %{
      conv: conv,
      ctx: ctx,
      turn: turn
    } do
      {head, _tail} = split(@secret, 10)
      next = insert_turn(conv, status: "running", turn_number: 2)

      %Output{bytes: 0}
      |> Output.log(ctx, "acp", chunk("ends with " <> head))
      |> Output.log(%{ctx | turn_id: next.id}, "acp", chunk("a new turn"))

      assert [first, second] = rows(ctx.conversation_id)
      assert {first.turn_id, first.data} == {turn.id, chunk("ends with " <> head)}
      assert {second.turn_id, second.data} == {next.id, chunk("a new turn")}
    end
  end

  describe "what the carry retains" do
    test "a prefix-only frame with huge metadata retains none of it", %{ctx: ctx} do
      # The second review's reproduction: text that is only a registered
      # prefix, padded with megabytes of `_meta`. Keeping the decoded
      # notification as a template kept the padding, uncharged, while
      # `held_bytes` said 3. The second case makes the kept text and session
      # id long enough to be sub-binaries that could pin the frame.
      long_value = String.duplicate("q", 400)

      for {value, text, session} <- [
            {"abcdefgh", "abc", "sess-2359"},
            {long_value, String.duplicate("q", 300), String.duplicate("s", 200)}
          ] do
        Redaction.put(ctx.conversation_id, [{"KEY", value}])

        line =
          "session/update"
          |> Managoat.ACP.Protocol.notification(%{
            sessionId: session,
            _meta: %{padding: String.duplicate("p", 10_000_000)},
            update: %{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: text}}
          })
          |> IO.iodata_to_binary()

        start = %Output{bytes: Output.byte_budget() - 1_000}
        output = Output.log(start, ctx, "acp", line)

        assert rows(ctx.conversation_id) == []
        refute output.capped

        # All retained state, not the tail counter: its serialized size, and
        # every binary in it, by the bytes it keeps alive.
        assert :erlang.external_size(output.carry) < 2_000

        for binary <- binaries(output.carry) do
          assert :binary.referenced_byte_size(binary) < 2_000
        end
      end

      # The held text still completes a value, and is still redacted.
      Redaction.put(ctx.conversation_id, [{"KEY", "abcdefgh"}])

      %Output{bytes: 0}
      |> Output.log(ctx, "acp", chunk("abc"))
      |> Output.log(ctx, "acp", chunk("defgh!"))
      |> Output.flush()

      assert stored_text(ctx.conversation_id) == Redaction.placeholder() <> "!"
    end

    for size <- [8_194, 16_384] do
      test "a self-overlapping #{size}-byte value past the cap retains a few integers", %{
        ctx: ctx
      } do
        # The third review's reproduction: a value that overlaps itself at
        # every offset, and one byte short of it in output. Copying a remainder
        # per matching prefix retained 33 MB (100 MB at 16 KiB) while
        # `held_bytes` said 0.
        size = unquote(size)
        Redaction.put(ctx.conversation_id, [{"RUN", String.duplicate("a", size)}])
        start = %Output{bytes: Output.byte_budget() - 1_000}

        output = Output.log(start, ctx, "stdout", String.duplicate("a", size - 1))
        refute output.capped
        assert stored_bytes(ctx.conversation_id, "stdout") == Redaction.placeholder()

        retained = :erlang.external_size(output.carry)
        assert retained < 2_000, "carry retains #{retained} bytes"

        for binary <- binaries(output.carry) do
          assert :binary.referenced_byte_size(binary) < 2_000
        end

        # The value's last byte, and then output that could still be its
        # continuation, is dropped rather than written.
        output = Output.log(output, ctx, "stdout", "a")
        output = Output.log(output, ctx, "stdout", String.duplicate("a", size - 2))
        assert stored_bytes(ctx.conversation_id, "stdout") == Redaction.placeholder()

        # Once nothing can still be a continuation, output flows again.
        output
        |> Output.log(ctx, "stdout", "visible\n")
        |> Output.flush()

        assert stored_bytes(ctx.conversation_id, "stdout") ==
                 Redaction.placeholder() <> "visible\n"
      end
    end

    test "a tail cut from a huge chunk does not pin the chunk", %{ctx: ctx} do
      # A tail over 64 bytes: a shorter sub-binary is copied by the runtime.
      Redaction.put(ctx.conversation_id, [{"KEY", String.duplicate("q", 400)}])
      huge = String.duplicate("x", 1_000_000) <> String.duplicate("q", 300)

      for {stream, data} <- [{"stdout", huge}, {"acp", chunk(huge)}] do
        output = Output.log(%Output{bytes: 0}, ctx, stream, data)

        for binary <- binaries(output.carry) do
          assert :binary.referenced_byte_size(binary) < 2_000
        end
      end
    end

    test "stays bounded when every chunk both completes and begins a value", %{ctx: ctx} do
      # The review's reproduction: with `abcdefgh` registered, `abc` and then
      # `defghabc` over and over. Holding whole lines walked the cut back to
      # the first line and kept all of them. A little room under the real
      # budget stands in for a small one, as `OutputTest` does.
      Redaction.put(ctx.conversation_id, [{"SHORT_KEY", "abcdefgh"}])
      budget = Output.byte_budget()
      start = %Output{bytes: budget - 4_000}

      output =
        Enum.reduce(1..1_001, Output.log(start, ctx, "acp", chunk("abc")), fn _, output ->
          output = Output.log(output, ctx, "acp", chunk("defghabc"))
          # After the first line, only the unresolved `abc` tail is kept.
          assert RedactionCarry.held_bytes(output.carry && output.carry.held) <= 15
          output
        end)

      # Rows were written while streaming, redacted, until the budget ran out.
      assert output.capped
      stored = rows(ctx.conversation_id)
      assert length(stored) > 10
      refute Blocks.assistant_text(stored) =~ "abc"
    end

    test "a value longer than the cap is replaced, never held or leaked", %{ctx: ctx} do
      cap = RedactionCarry.max_hold()
      long = "LONG-" <> String.duplicate("0123456789", div(cap, 10) + 200)
      Redaction.put(ctx.conversation_id, [{"HUGE_CERT", long}])
      {head, tail} = split(long, cap + 1_000)

      output = Output.log(%Output{bytes: 0}, ctx, "stdout", "cert: " <> head)
      assert RedactionCarry.held_bytes(output.carry && output.carry.held) <= cap

      output
      |> feed(ctx, "stdout", [
        binary_part(tail, 0, 700),
        binary_part(tail, 700, byte_size(tail) - 700) <> " end\n"
      ])
      |> Output.flush()

      bytes = stored_bytes(ctx.conversation_id, "stdout")
      assert bytes == "cert: #{Redaction.placeholder()} end\n"
    end
  end

  describe "multibyte text after the fail-safe drops by count" do
    # The fourth review's finding: the count is in bytes, and an `acp` chunk's
    # text is re-encoded as JSON. A count that ran out inside a codepoint left
    # a lone continuation byte, and `Jason.encode!` raised out of `log/4`.
    test "a count that ends inside a codepoint drops the rest of it", %{ctx: ctx} do
      size = RedactionCarry.max_hold() + 2
      Redaction.put(ctx.conversation_id, [{"RUN", String.duplicate("a", size)}])

      # One byte short of a value that overlaps itself: no pairs, a count of
      # `size - 1`, which is odd, so it ends on the second byte of an `é`.
      %Output{bytes: 0}
      |> feed(ctx, "acp", [
        chunk(String.duplicate("a", size - 1)),
        chunk(String.duplicate("é", div(size, 2)) <> " visible"),
        chunk(" and after")
      ])
      |> Output.flush()

      assert_valid_lines(ctx.conversation_id)
      assert stored_text(ctx.conversation_id) == Redaction.placeholder() <> " visible and after"
    end

    test "a registry change mid-value does the same", %{ctx: ctx} do
      long = "LONG-" <> Enum.map_join(1..3_000, &Integer.to_string/1)
      Redaction.put(ctx.conversation_id, [{"CERT", long}])
      cut = RedactionCarry.max_hold() + 100
      output = Output.log(%Output{bytes: 0}, ctx, "acp", chunk(binary_part(long, 0, cut)))

      # A rotation re-sorts the registry, so the rest is dropped by count
      # (`byte_size(long) - cut`). The padding puts that count's end on the
      # second byte of an `é`.
      Redaction.add(ctx.conversation_id, [
        {"ROTATED", String.duplicate("z", byte_size(long) + 10)}
      ])

      count = byte_size(long) - cut
      pad = String.duplicate("x", rem(count + 1, 2))

      output
      |> feed(ctx, "acp", [
        chunk(pad <> String.duplicate("é", count) <> " visible"),
        chunk(" and after")
      ])
      |> Output.flush()

      assert_valid_lines(ctx.conversation_id)
      text = stored_text(ctx.conversation_id)
      refute text =~ "LONG-"
      refute text =~ "2999"
      assert String.starts_with?(text, Redaction.placeholder() <> "é")
      assert String.ends_with?(text, "é visible and after")
    end
  end

  describe "multibyte raw output after the fail-safe drops by count" do
    # The fifth review's finding: `log_events.data` is PostgreSQL text. A count
    # that ran out inside a codepoint of `stdout` or `stderr` left a lone
    # continuation byte in front of valid output, and the insert raised.
    for stream <- ["stdout", "stderr"] do
      test "a count that ends inside a codepoint of #{stream} drops the rest of it", %{ctx: ctx} do
        stream = unquote(stream)
        size = RedactionCarry.max_hold() + 2
        Redaction.put(ctx.conversation_id, [{"RUN", String.duplicate("a", size)}])

        %Output{bytes: 0}
        |> feed(ctx, stream, [
          String.duplicate("a", size - 1),
          String.duplicate("é", div(size, 2)) <> " visible",
          " and after"
        ])
        |> Output.flush()

        assert_valid_rows(ctx.conversation_id)

        assert stored_bytes(ctx.conversation_id, stream) ==
                 Redaction.placeholder() <> " visible and after"
      end

      test "a registry change mid-value on #{stream} does the same", %{ctx: ctx} do
        stream = unquote(stream)
        long = "LONG-" <> Enum.map_join(1..3_000, &Integer.to_string/1)
        Redaction.put(ctx.conversation_id, [{"CERT", long}])
        cut = RedactionCarry.max_hold() + 100
        output = Output.log(%Output{bytes: 0}, ctx, stream, binary_part(long, 0, cut))

        rotated = String.duplicate("z", byte_size(long) + 10)
        Redaction.add(ctx.conversation_id, [{"ROTATED", rotated}])
        count = byte_size(long) - cut
        pad = String.duplicate("x", rem(count + 1, 2))

        output
        |> feed(ctx, stream, [pad <> String.duplicate("é", count) <> " visible", " and after"])
        |> Output.flush()

        assert_valid_rows(ctx.conversation_id)
        bytes = stored_bytes(ctx.conversation_id, stream)
        refute bytes =~ "LONG-"
        refute bytes =~ "2999"
        assert String.starts_with?(bytes, Redaction.placeholder() <> "é")
        assert String.ends_with?(bytes, "é visible and after")
      end
    end
  end

  describe "chunks that cannot be a value's start" do
    test "are persisted at once and verbatim, so replay dedup still matches", %{ctx: ctx} do
      lines = [chunk("nothing "), chunk("to hide "), chunk("here.")]
      output = feed(%Output{bytes: 0}, ctx, "acp", lines)

      assert Enum.map(rows(ctx.conversation_id), & &1.data) == lines
      assert output.carry == nil
    end

    test "a conversation with nothing registered holds nothing", %{ctx: ctx} do
      Redaction.delete(ctx.conversation_id)
      {head, _tail} = split(@secret, 10)

      Output.log(%Output{bytes: 0}, ctx, "acp", chunk(head))
      assert [row] = rows(ctx.conversation_id)
      assert row.data == chunk(head)
    end
  end

  describe "a value split across raw stdout and stderr chunks" do
    for stream <- ["stdout", "stderr"] do
      test "is redacted on #{stream}", %{ctx: ctx} do
        stream = unquote(stream)
        {head, tail} = split(@secret, 21)

        %Output{bytes: 0}
        |> feed(ctx, stream, ["SYNTHETIC_API_KEY=" <> head, tail <> "\nPATH=/usr/bin\n"])
        |> Output.flush()

        bytes = stored_bytes(ctx.conversation_id, stream)
        refute bytes =~ @secret
        assert bytes == "SYNTHETIC_API_KEY=#{Redaction.placeholder()}\nPATH=/usr/bin\n"
      end
    end

    test "each stream carries its own tail", %{ctx: ctx} do
      {head, tail} = split(@secret, 8)

      %Output{bytes: 0}
      |> feed(ctx, "stdout", ["out " <> head])
      |> feed(ctx, "stderr", ["an unrelated warning\n"])
      |> feed(ctx, "stdout", [tail])
      |> Output.flush()

      assert stored_bytes(ctx.conversation_id, "stdout") == "out #{Redaction.placeholder()}"
      assert stored_bytes(ctx.conversation_id, "stderr") == "an unrelated warning\n"
    end
  end

  describe "a whole value that JSON escapes" do
    test "is redacted inside a protocol line", %{conv: conv, ctx: ctx} do
      quoted = ~s(pass"word\\with-escapes-2359)
      Redaction.put(conv.id, [{"DB_PASSWORD", quoted}])

      Output.log(%Output{bytes: 0}, ctx, "acp", chunk("the password is " <> quoted))

      assert [row] = rows(ctx.conversation_id)
      refute Blocks.assistant_text([row]) =~ quoted
      refute row.data =~ Jason.encode!(quoted) |> String.slice(1..-2//1)
    end

    test "is redacted when it spans lines", %{conv: conv, ctx: ctx} do
      pem = "-----BEGIN KEY-----\nMIIsynthetic2359\n-----END KEY-----"
      Redaction.put(conv.id, [{"PRIVATE_KEY", pem}])
      {head, tail} = split(pem, 25)

      %Output{bytes: 0}
      |> feed(ctx, "acp", [chunk(head), chunk(tail <> "\n")])
      |> Output.flush()

      assert stored_text(ctx.conversation_id) == Redaction.placeholder()
    end
  end

  defp assert_valid_lines(conv_id) do
    for row <- rows(conv_id) do
      assert String.valid?(row.data)
      assert {:ok, _line} = Jason.decode(row.data)
    end
  end

  defp assert_valid_rows(conv_id) do
    for row <- rows(conv_id), do: assert(String.valid?(row.data))
  end

  defp binaries(term) when is_binary(term), do: [term]
  defp binaries(term) when is_map(term), do: term |> Map.to_list() |> binaries()
  defp binaries(term) when is_list(term), do: Enum.flat_map(term, &binaries/1)
  defp binaries(term) when is_tuple(term), do: term |> Tuple.to_list() |> binaries()
  defp binaries(_term), do: []

  defp collect_frames(acc \\ []) do
    receive do
      {:log_event, event} -> collect_frames([event | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
