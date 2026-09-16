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
  alias Fountain.Conversations.{Blocks, Output, Redaction}

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

  defp tool_call(id, input) do
    "session/update"
    |> Managoat.ACP.Protocol.notification(%{
      sessionId: "sess-2359",
      update: %{sessionUpdate: "tool_call", toolCallId: id, title: "Bash", rawInput: input}
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

    test "held text is flushed before a different line, in order", %{ctx: ctx} do
      {head, _tail} = split(@secret, 10)

      %Output{bytes: 0}
      |> feed(ctx, "acp", [chunk("almost " <> head), tool_call("t1", %{command: "ls"})])
      |> Output.flush()

      assert [first, second] = rows(ctx.conversation_id)
      assert first.data == chunk("almost " <> head)
      assert second.data == tool_call("t1", %{command: "ls"})
    end

    test "flush/1 writes what is held, under the turn it arrived in", %{ctx: ctx, turn: turn} do
      {head, _tail} = split(@secret, 10)

      output = Output.log(%Output{bytes: 0}, ctx, "acp", chunk("ends with " <> head))
      assert rows(ctx.conversation_id) == []

      %Output{carry: nil} = Output.flush(output)
      assert [row] = rows(ctx.conversation_id)
      assert row.turn_id == turn.id
      assert stored_text(ctx.conversation_id) == "ends with " <> head
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

  defp collect_frames(acc \\ []) do
    receive do
      {:log_event, event} -> collect_frames([event | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
