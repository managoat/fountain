defmodule Managoat.ACP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Managoat.ACP.Protocol

  describe "feed/2 framing" do
    test "returns whole messages and keeps the incomplete tail" do
      {msgs, rest} = Protocol.feed("", ~s({"jsonrpc":"2.0","id":1,"result":{}}\n{"jsonr))

      assert [{:response, 1, %{}}] = msgs
      assert rest == ~s({"jsonr)
    end

    test "a message split across three chunks is delivered once, whole" do
      {msgs, buf} = Protocol.feed("", ~s({"jsonrpc":"2.0",))
      assert msgs == []

      {msgs, buf} = Protocol.feed(buf, ~s("id":7,"result":{"sessionId":))
      assert msgs == []

      {msgs, buf} = Protocol.feed(buf, ~s("abc"}}\n))

      assert [{:response, 7, %{"sessionId" => "abc"}}] = msgs
      assert buf == ""
    end

    test "several messages in one chunk keep their order" do
      chunk =
        Enum.map_join(1..3, "", fn i ->
          ~s({"jsonrpc":"2.0","method":"session/update","params":{"n":#{i}}}\n)
        end)

      {msgs, ""} = Protocol.feed("", chunk)

      assert [
               {:notification, "session/update", %{"n" => 1}},
               {:notification, "session/update", %{"n" => 2}},
               {:notification, "session/update", %{"n" => 3}}
             ] = msgs
    end

    test "valid JSON with no trailing newline is held back, not emitted early" do
      # The newline is the frame boundary. Emitting on 'it parses' would deliver
      # a message that the agent is still writing.
      {msgs, rest} = Protocol.feed("", ~s({"jsonrpc":"2.0","id":1,"result":{}}))

      assert msgs == []
      assert rest != ""
    end

    test "blank lines between messages are ignored" do
      {msgs, ""} = Protocol.feed("", "\n\n" <> ~s({"jsonrpc":"2.0","id":1,"result":{}}\n))
      assert [{:response, 1, _}] = msgs
    end

    test "a non-JSON line is an event, not a crash" do
      {msgs, ""} = Protocol.feed("", "npm warn deprecated foo@1.0.0\n")
      assert [{:invalid, "npm warn deprecated foo@1.0.0"}] = msgs
    end

    test "a stack trace does not stop the messages after it" do
      chunk = "TypeError: boom\n" <> ~s({"jsonrpc":"2.0","id":2,"result":{}}\n)
      {msgs, ""} = Protocol.feed("", chunk)

      assert [{:invalid, "TypeError: boom"}, {:response, 2, _}] = msgs
    end
  end

  describe "classify/1" do
    test "distinguishes the four message shapes" do
      assert {:response, 1, %{"ok" => true}} =
               Protocol.classify(%{"id" => 1, "result" => %{"ok" => true}})

      assert {:error_response, 1, %{"code" => -1}} =
               Protocol.classify(%{"id" => 1, "error" => %{"code" => -1}})

      assert {:request, 2, "session/request_permission", %{"a" => 1}} =
               Protocol.classify(%{
                 "id" => 2,
                 "method" => "session/request_permission",
                 "params" => %{"a" => 1}
               })

      assert {:notification, "session/update", %{}} =
               Protocol.classify(%{"method" => "session/update"})
    end

    test "a request is distinguished from a notification by the id, not the method" do
      # Both carry `method`; only a request expects a reply. Getting this
      # backwards means either answering a notification or hanging an agent.
      assert {:request, 9, "fs/read_text_file", _} =
               Protocol.classify(%{"id" => 9, "method" => "fs/read_text_file"})

      assert {:notification, "fs/read_text_file", _} =
               Protocol.classify(%{"method" => "fs/read_text_file"})
    end

    test "missing params become an empty map rather than nil" do
      assert {:notification, "session/update", %{}} =
               Protocol.classify(%{"method" => "session/update", "params" => nil})
    end

    test "a decoded JSON value that is not an RPC object is invalid" do
      assert {:invalid, "[1,2,3]"} = Protocol.classify([1, 2, 3])
    end
  end

  defp update_line(update) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "s1", "update" => update}
    })
  end

  describe "session_metadata?/1" do
    test "true for every metadata update kind" do
      for kind <- ~w(session_info_update available_commands_update current_mode_update) do
        assert Protocol.session_metadata?(update_line(%{"sessionUpdate" => kind})),
               "expected #{kind} to be metadata"
      end
    end

    test "the claude adapter's post-turn title line is metadata (#1300)" do
      assert Protocol.session_metadata?(
               update_line(%{
                 "sessionUpdate" => "session_info_update",
                 "title" => "Research Xfinity internet promotion pricing",
                 "updatedAt" => "2026-08-25T12:05:48.620Z"
               })
             )
    end

    test "false for agent activity" do
      for kind <- ~w(agent_message_chunk agent_thought_chunk tool_call tool_call_update plan
                     usage_update user_message_chunk) do
        refute Protocol.session_metadata?(update_line(%{"sessionUpdate" => kind})),
               "expected #{kind} not to be metadata"
      end
    end

    test "false for other notifications, requests, responses and junk" do
      refute Protocol.session_metadata?(
               Jason.encode!(%{"jsonrpc" => "2.0", "method" => "session/cancel", "params" => %{}})
             )

      refute Protocol.session_metadata?(
               Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
             )

      refute Protocol.session_metadata?("npm warn deprecated foo@1.0.0")

      # A session/update with no update object at all is not metadata either.
      refute Protocol.session_metadata?(
               Jason.encode!(%{"jsonrpc" => "2.0", "method" => "session/update"})
             )
    end
  end

  describe "encoding" do
    test "every encoded frame ends in exactly one newline" do
      for frame <- [
            Protocol.request(1, "initialize", %{}),
            Protocol.notification("session/cancel", %{}),
            Protocol.response(1, %{}),
            Protocol.error(1, -32_601, "nope")
          ] do
        encoded = IO.iodata_to_binary(frame)
        assert String.ends_with?(encoded, "\n")
        refute String.ends_with?(encoded, "\n\n")
      end
    end

    test "a request round-trips through the framer" do
      line = IO.iodata_to_binary(Protocol.request(3, "session/prompt", %{"sessionId" => "s1"}))
      {[msg], ""} = Protocol.feed("", line)

      assert {:request, 3, "session/prompt", %{"sessionId" => "s1"}} = msg
    end

    test "error/3 carries the code and message" do
      line = IO.iodata_to_binary(Protocol.error(4, Protocol.method_not_found(), "no fs"))
      {[{:error_response, 4, err}], ""} = Protocol.feed("", line)

      assert err["code"] == -32_601
      assert err["message"] == "no fs"
    end
  end

  describe "default_client_capabilities/0" do
    test "services nothing, and opts into boolean session config options" do
      caps = Protocol.default_client_capabilities()

      assert caps.terminal == false
      assert caps.fs == %{readTextFile: false, writeTextFile: false}
      # Both pinned adapters test `session.configOptions.boolean != null`.
      assert %{session: %{configOptions: %{boolean: %{}}}} = caps
    end
  end
end
