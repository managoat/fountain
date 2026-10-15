defmodule Managoat.ACP.TracerTest do
  use ExUnit.Case, async: true

  alias Managoat.ACP.Tracer

  # The OTel SDK is prod-only (mix.exs); under test the API renders every span
  # call a no-op. What these tests can and do hold is the tracer's bookkeeping —
  # which ids are open, what accumulates, what survives junk input — which is
  # exactly the part that used to be claude-only and is now protocol-wide
  # (#637).

  defp update_line(update) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "sess_1", "update" => update}
    }) <> "\n"
  end

  defp tool_call(id, extra \\ %{}) do
    update_line(Map.merge(%{"sessionUpdate" => "tool_call", "toolCallId" => id}, extra))
  end

  defp tool_update(id, status) do
    update_line(%{"sessionUpdate" => "tool_call_update", "toolCallId" => id, "status" => status})
  end

  test "nil is a no-op everywhere" do
    assert Tracer.handle_line(nil, "anything") == nil
    assert Tracer.finalize(nil) == :ok
  end

  test "a tool_call opens a span keyed by toolCallId; a terminal update closes it" do
    tracer =
      Tracer.new(:span)
      |> Tracer.handle_line(tool_call("t1", %{"title" => "Read file", "kind" => "read"}))

    assert Map.has_key?(tracer.open_tool_spans, "t1")
    assert tracer.tool_calls == 1

    tracer = Tracer.handle_line(tracer, tool_update("t1", "completed"))
    assert tracer.open_tool_spans == %{}
  end

  test "failed and cancelled close the span too" do
    for status <- ["failed", "cancelled"] do
      tracer =
        Tracer.new(:span)
        |> Tracer.handle_line(tool_call("t1"))
        |> Tracer.handle_line(tool_update("t1", status))

      assert tracer.open_tool_spans == %{}
    end
  end

  test "non-terminal updates are progress, not an outcome" do
    tracer =
      Tracer.new(:span)
      |> Tracer.handle_line(tool_call("t1"))
      |> Tracer.handle_line(tool_update("t1", "in_progress"))
      |> Tracer.handle_line(tool_update("t1", "pending"))

    assert Map.has_key?(tracer.open_tool_spans, "t1")
  end

  test "a re-announced tool_call does not leak the original span" do
    tracer =
      Tracer.new(:span)
      |> Tracer.handle_line(tool_call("t1"))
      |> Tracer.handle_line(tool_call("t1", %{"status" => "in_progress"}))

    assert map_size(tracer.open_tool_spans) == 1
    assert tracer.tool_calls == 1
  end

  test "an update for an unknown id is ignored rather than crashing the turn" do
    tracer = Tracer.handle_line(Tracer.new(:span), tool_update("never-opened", "completed"))
    assert tracer.open_tool_spans == %{}
  end

  test "message and thought chunks accumulate byte counts, not span events" do
    tracer =
      Tracer.new(:span)
      |> Tracer.handle_line(
        update_line(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "hello"}
        })
      )
      |> Tracer.handle_line(
        update_line(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => [%{"type" => "text", "text" => " world"}]
        })
      )
      |> Tracer.handle_line(
        update_line(%{
          "sessionUpdate" => "agent_thought_chunk",
          "content" => %{"type" => "text", "text" => "hmm"}
        })
      )

    assert tracer.text_bytes == byte_size("hello world")
    assert tracer.thinking_bytes == 3
  end

  test "non-text content counts nothing rather than guessing a size" do
    tracer =
      Tracer.handle_line(
        Tracer.new(:span),
        update_line(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "image", "data" => "aGk="}
        })
      )

    assert tracer.text_bytes == 0
  end

  test "plain text chunks count bytes and a kind names title-less tools" do
    tracer =
      Tracer.new(:span)
      |> Tracer.handle_line(
        update_line(%{"sessionUpdate" => "agent_message_chunk", "content" => "hello"})
      )
      |> Tracer.handle_line(tool_call("t1", %{"kind" => "execute"}))

    assert tracer.text_bytes == 5
    assert tracer.tool_calls == 1
    assert Map.has_key?(tracer.open_tool_spans, "t1")
  end

  test "unknown update variants leave the trace unchanged" do
    tracer = Tracer.new(:span)

    assert Tracer.handle_line(
             tracer,
             update_line(%{"sessionUpdate" => "future_update", "value" => 1})
           ) == tracer
  end

  test "responses, requests and junk lines trace nothing" do
    tracer = Tracer.new(:span)

    for line <- [
          ~s({"jsonrpc":"2.0","id":1,"result":{}}\n),
          ~s({"jsonrpc":"2.0","id":2,"method":"session/request_permission","params":{}}\n),
          ~s({"jsonrpc":"2.0","method":"session/other","params":{}}\n),
          "npm WARN deprecated something\n",
          ""
        ] do
      assert Tracer.handle_line(tracer, line) == tracer
    end
  end

  test "a tool_call missing its id is dropped, not opened under a garbage key" do
    tracer = Tracer.handle_line(Tracer.new(:span), update_line(%{"sessionUpdate" => "tool_call"}))
    assert tracer.open_tool_spans == %{}
    assert tracer.tool_calls == 0
  end

  test "finalize closes abandoned spans and returns :ok" do
    tracer =
      Tracer.new(:span)
      |> Tracer.handle_line(tool_call("t1"))
      |> Tracer.handle_line(tool_call("t2"))
      |> Tracer.handle_line(tool_update("t1", "completed"))

    assert Tracer.finalize(tracer) == :ok
  end
end
