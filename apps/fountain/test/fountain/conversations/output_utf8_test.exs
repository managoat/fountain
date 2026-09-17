defmodule Fountain.Conversations.OutputUtf8Test do
  use Fountain.DataCase, async: true
  use ExUnitProperties

  alias Fountain.Conversations.{LogEvent, Output, Redaction}

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id)
    turn = insert_turn(conv, status: "running")
    ctx = %{conversation_id: conv.id, turn_id: turn.id, user_id: user.id}

    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")
    on_exit(fn -> Redaction.delete(conv.id) end)
    {:ok, ctx: ctx}
  end

  defp assert_output(ctx, stream, expected) do
    assert_receive {:log_event, %LogEvent{} = event}
    assert event.data == expected
    assert event.stream == stream
    assert event.turn_id == ctx.turn_id
    assert Fountain.Repo.get!(LogEvent, event.id).data == expected
  end

  test "a codepoint split by the transport is replaced in each row", %{ctx: ctx} do
    assert Redaction.lookup(ctx.conversation_id) == []

    output = Output.log(%Output{bytes: 0}, ctx, "stdout", "caf" <> <<0xC3>>)
    assert_output(ctx, "stdout", "caf?")

    Output.log(output, ctx, "stdout", <<0xA9>> <> " au lait\n")
    assert_output(ctx, "stdout", "? au lait\n")
  end

  test "direct persistence replaces latin-1 and lone continuation bytes", %{ctx: ctx} do
    assert Redaction.lookup(ctx.conversation_id) == []

    Output.persist(ctx, "stderr", <<0xA9>> <> " caf" <> <<0xE9>> <> "\n")
    assert_output(ctx, "stderr", "? caf?\n")
  end

  test "binary output replaces NUL, overlong encodings and surrogate codepoints", %{ctx: ctx} do
    data = "before" <> <<0, 0xFF, 0xC0, 0xAF, 0xED, 0xA0, 0x80>> <> " after\n"

    Output.log(%Output{bytes: 0}, ctx, "stderr", data)
    assert_output(ctx, "stderr", "before??????? after\n")
  end

  test "valid Unicode and terminal control characters are preserved", %{ctx: ctx} do
    data = "\e[31mcafé 日本語 🙂\e[0m\t\r\n"

    for stream <- ~w(stdout stderr) do
      Output.log(%Output{bytes: 0}, ctx, stream, data)
      assert_output(ctx, stream, data)
    end
  end

  test "binary secrets are redacted before their bytes are replaced", %{ctx: ctx} do
    secret = "secret-" <> <<0xFF, 0>> <> "-value"
    Redaction.put(ctx.conversation_id, [secret])

    Output.persist(ctx, "stderr", "token=" <> secret <> <<0xA9>> <> "\n")
    assert_output(ctx, "stderr", "token=[REDACTED]?\n")
  end

  test "a split secret is redacted beside invalid bytes", %{ctx: ctx} do
    Redaction.put(ctx.conversation_id, ["secret-value"])

    %Output{bytes: 0} =
      output =
      Output.log(%Output{bytes: 0}, ctx, "stdout", <<0xFF>> <> " secret-")

    output |> Output.log(ctx, "stdout", "value" <> <<0>> <> "\n") |> Output.flush()
    assert_output(ctx, "stdout", "? [REDACTED]?\n")
  end

  test "turn-end flush also replaces invalid bytes in held output", %{ctx: ctx} do
    Redaction.put(ctx.conversation_id, ["secret-value"])

    output = Output.log(%Output{bytes: 0}, ctx, "stderr", <<0xFF>> <> " secret-")
    refute_receive {:log_event, _}

    assert %Output{carry: nil} = Output.flush(output)
    assert_output(ctx, "stderr", "? secret-")
  end

  test "replacement does not expand output beyond the byte budget", %{ctx: ctx} do
    budget = Output.byte_budget()

    assert %Output{bytes: ^budget, capped: false} =
             output =
             Output.log(%Output{bytes: budget - 2}, ctx, "stderr", <<0xFF, 0>>)

    assert_output(ctx, "stderr", "??")
    assert %Output{capped: true} = Output.log(output, ctx, "stderr", "x")
    assert_output(ctx, "stderr", Output.cap_marker(budget))
  end

  property "arbitrary bytes persist and broadcast as bounded PostgreSQL text", %{ctx: ctx} do
    check all(data <- binary(min_length: 1, max_length: 256), max_runs: 30) do
      Output.persist(ctx, "stderr", data)

      assert_receive {:log_event, %LogEvent{} = event}
      assert String.valid?(event.data)
      refute String.contains?(event.data, <<0>>)
      assert byte_size(event.data) <= byte_size(data)
      assert Fountain.Repo.get!(LogEvent, event.id).data == event.data
    end
  end
end
