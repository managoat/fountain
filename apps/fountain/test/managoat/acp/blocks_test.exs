defmodule Managoat.ACP.BlocksTest do
  use ExUnit.Case, async: true

  alias Managoat.ACP.Blocks

  defp update(map), do: Blocks.from_update(%{"update" => map})

  defp line(method, params) do
    Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  describe "message chunks" do
    test "an agent message chunk becomes a :text block" do
      assert [%{kind: :text, body: "hello"}] =
               update(%{
                 "sessionUpdate" => "agent_message_chunk",
                 "content" => %{"type" => "text", "text" => "hello"}
               })
    end

    test "a thought chunk becomes a :thinking block" do
      assert [%{kind: :thinking, body: "hmm"}] =
               update(%{
                 "sessionUpdate" => "agent_thought_chunk",
                 "content" => %{"type" => "text", "text" => "hmm"}
               })
    end

    test "a list of content parts is concatenated, not split into blocks" do
      # Adjacent text renders as one paragraph; emitting a block per part would
      # break a sentence across cards.
      assert [%{kind: :text, body: "abc"}] =
               update(%{
                 "sessionUpdate" => "agent_message_chunk",
                 "content" => [
                   %{"type" => "text", "text" => "a"},
                   %{"type" => "text", "text" => "b"},
                   %{"type" => "text", "text" => "c"}
                 ]
               })
    end

    test "an empty chunk produces no block at all" do
      assert [] =
               update(%{
                 "sessionUpdate" => "agent_message_chunk",
                 "content" => %{"type" => "text", "text" => ""}
               })
    end

    test "a non-text part is named rather than rendered blank" do
      assert [%{kind: :text, body: "[image]"}] =
               update(%{
                 "sessionUpdate" => "agent_message_chunk",
                 "content" => %{"type" => "image", "data" => "..."}
               })
    end

    test "the other protocol content forms remain useful to a text transcript" do
      assert [%{body: "sound[audio][image]https://example.test/file"}] =
               update(%{
                 "sessionUpdate" => "agent_message_chunk",
                 "content" => [
                   "sound",
                   %{"type" => "audio"},
                   %{"type" => "image"},
                   %{"type" => "resource_link", "uri" => "https://example.test/file"},
                   %{"type" => "resource_link", "uri" => nil}
                 ]
               })
    end
  end

  describe "tool calls" do
    test "a tool_call becomes a :tool_use carrying the id the pairing pass needs" do
      assert [block] =
               update(%{
                 "sessionUpdate" => "tool_call",
                 "toolCallId" => "call_1",
                 "title" => "Read file",
                 "kind" => "read",
                 "rawInput" => %{"path" => "/tmp/x"}
               })

      assert block.kind == :tool_use
      assert block.id == "call_1"
      assert block.name == "Read file"
      assert block.body =~ "/tmp/x"
    end

    test "the summary prefers a location path over the raw input" do
      assert [%{summary: "/srv/app.ex"}] =
               update(%{
                 "sessionUpdate" => "tool_call",
                 "toolCallId" => "c",
                 "title" => "Edit",
                 "locations" => [%{"path" => "/srv/app.ex"}],
                 "rawInput" => %{"noise" => "lots"}
               })
    end

    test "a title-less call falls back to its kind, never to an empty card" do
      assert [%{name: "execute"}] =
               update(%{"sessionUpdate" => "tool_call", "toolCallId" => "c", "kind" => "execute"})

      assert [%{name: "tool"}] =
               update(%{"sessionUpdate" => "tool_call", "toolCallId" => "c"})
    end

    test "a completed update becomes a :tool_result keyed to the same id" do
      assert [block] =
               update(%{
                 "sessionUpdate" => "tool_call_update",
                 "toolCallId" => "call_1",
                 "status" => "completed",
                 "content" => [
                   %{"type" => "content", "content" => %{"type" => "text", "text" => "ok"}}
                 ]
               })

      assert block.kind == :tool_result
      assert block.tool_id == "call_1"
      assert block.body == "ok"
      refute block.error?
    end

    test "a failed update is a result flagged as an error" do
      assert [%{kind: :tool_result, error?: true}] =
               update(%{
                 "sessionUpdate" => "tool_call_update",
                 "toolCallId" => "c",
                 "status" => "failed"
               })
    end

    test "tool results render diffs, direct content, and raw output" do
      assert [%{body: "diff: lib/app.ex\ndone"}] =
               update(%{
                 "sessionUpdate" => "tool_call_update",
                 "toolCallId" => "c",
                 "status" => "completed",
                 "content" => [
                   %{"type" => "diff", "path" => "lib/app.ex"},
                   %{"type" => "text", "text" => "done"}
                 ]
               })

      assert [%{body: "plain output"}] =
               update(%{
                 "sessionUpdate" => "tool_call_update",
                 "toolCallId" => "c",
                 "status" => "completed",
                 "rawOutput" => "plain output"
               })
    end

    test "tool summaries make bounded previews from structured input" do
      long = String.duplicate("x", 150)

      assert [%{summary: summary}] =
               update(%{
                 "sessionUpdate" => "tool_call",
                 "toolCallId" => "c",
                 "rawInput" => %{"count" => 2, "query" => long}
               })

      assert summary =~ "count=2"
      assert String.ends_with?(summary, "…")
      assert byte_size(summary) <= 123
    end

    test "in-flight updates produce nothing" do
      # A tool call reports pending → in_progress → completed. Rendering each as
      # a result would draw the same finished tool card three times.
      for status <- ["pending", "in_progress"] do
        assert [] =
                 update(%{
                   "sessionUpdate" => "tool_call_update",
                   "toolCallId" => "c",
                   "status" => status
                 })
      end
    end

    test "ids thread through so show.ex's pairing pass can collapse them" do
      [use_block] =
        update(%{"sessionUpdate" => "tool_call", "toolCallId" => "x", "title" => "T"})

      [result_block] =
        update(%{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "x",
          "status" => "completed"
        })

      assert use_block.id == result_block.tool_id
    end
  end

  describe "variants with no Fountain equivalent" do
    test "command lists and user echoes are dropped" do
      for variant <- ["available_commands_update", "user_message_chunk"] do
        assert [] =
                 update(%{
                   "sessionUpdate" => variant,
                   "content" => %{"type" => "text", "text" => "x"}
                 })
      end
    end

    test "an unknown variant is dropped rather than rendered as raw" do
      # The legacy parsers render unrecognised lines as a :raw block. For a
      # specified protocol that would turn every new notification kind an
      # adapter adds into visible noise in every conversation.
      assert [] = update(%{"sessionUpdate" => "something_invented_later"})
    end
  end

  describe "from_line/1" do
    test "translates a session/update notification line" do
      line =
        line("session/update", %{
          "sessionId" => "s",
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => "hi"}
          }
        })

      assert [%{kind: :text, body: "hi"}] = Blocks.from_line(line)
    end

    test "protocol chatter renders as nothing" do
      assert [] =
               Blocks.from_line(Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}))

      assert [] = Blocks.from_line(line("session/other", %{}))
    end

    test "a non-JSON line survives as a :raw block" do
      assert [%{kind: :raw, body: "npm warn"}] = Blocks.from_line("npm warn")
    end

    test "params without the update envelope still translate" do
      # Some adapters put the variant directly in params rather than under
      # `update`. Both shapes appear in the wild; neither should render blank.
      assert [%{kind: :text, body: "flat"}] =
               Blocks.from_line(
                 line("session/update", %{
                   "sessionUpdate" => "agent_message_chunk",
                   "content" => %{"type" => "text", "text" => "flat"}
                 })
               )
    end

    test "a permission request renders exactly the choices the agent offered" do
      request =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 42,
          "method" => "session/request_permission",
          "params" => %{
            "toolCall" => %{"kind" => "execute", "rawInput" => %{"command" => "mix test"}},
            "options" => [%{"optionId" => "yes", "kind" => "allow_once"}, "invalid"]
          }
        })

      assert [block] = Blocks.from_line(request)
      assert block.kind == :permission_request
      assert block.request_id == "42"
      assert block.name == "execute"
      assert block.options == [%{"optionId" => "yes", "kind" => "allow_once"}]
      assert block.summary =~ "mix test"
    end

    test "a malformed permission request still produces an answerable block" do
      request =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "req-1",
          "method" => "session/request_permission"
        })

      assert [%{request_id: "req-1", name: "tool", summary: "", options: []}] =
               Blocks.from_line(request)
    end

    test "non-map updates are ignored" do
      assert [] = Blocks.from_update(nil)
      assert [] = Blocks.from_update(%{"update" => "not an update"})
    end
  end
end
