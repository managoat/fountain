defmodule Managoat.ACP.PeerPlansTest do
  use ExUnit.Case, async: true

  alias Managoat.ACP.{Blocks, Peer, Protocol}

  defp peer(opts \\ []) do
    owner = self()

    {:ok, pid} =
      Peer.start(
        Keyword.merge(
          [
            owner: owner,
            ref: make_ref(),
            prompt: "hello",
            mode: :continue,
            session_id: "ours",
            attach: 4,
            writer: fn data ->
              send(owner, {:wrote, Jason.decode!(IO.iodata_to_binary(data))})
              :ok
            end
          ],
          opts
        )
      )

    on_exit(fn -> if Process.alive?(pid), do: Peer.close(pid) end)
    pid
  end

  defp feed(pid, update, session \\ "ours") do
    Peer.stdout(
      pid,
      IO.iodata_to_binary(
        Protocol.notification("session/update", %{"sessionId" => session, "update" => update})
      )
    )
  end

  defp create(pid, session \\ "ours") do
    feed(
      pid,
      %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "create",
        "title" => "TaskCreate",
        "rawInput" => %{"subject" => "Inspect"}
      },
      session
    )

    feed(
      pid,
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "create",
        "status" => "completed",
        "rawOutput" => %{"task" => %{"id" => "1", "subject" => "Inspect"}}
      },
      session
    )
  end

  defp complete(pid) do
    feed(pid, %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "update",
      "title" => "TaskUpdate",
      "rawInput" => %{"taskId" => "1", "status" => "completed"}
    })

    feed(pid, %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "update",
      "status" => "completed",
      "rawOutput" => "ok"
    })
  end

  test "each stored snapshot can be decoded alone, including on a subsequent turn" do
    pid = peer()
    create(pid)
    assert_receive {:acp, _, {:lines, "acp", first}}
    assert Blocks.from_line(first) == []
    assert_receive {:acp, _, {:lines, "acp", created}}

    assert [%{kind: :plan, body: [%{"id" => "1", "status" => "pending"}]}] =
             Blocks.from_line(created)

    # Original raw data is still available to diagnostics.
    assert Jason.decode!(created)["params"]["update"]["rawOutput"]["task"]["id"] == "1"

    Peer.stdout(pid, IO.iodata_to_binary(Protocol.response(4, %{stopReason: "end_turn"})))
    assert_receive {:acp, _, {:done, _, _}}
    assert :ok = Peer.prompt(pid, "finish")
    complete(pid)
    assert_receive {:acp, _, {:lines, "acp", _}}
    assert_receive {:acp, _, {:lines, "acp", completed}}

    assert [%{kind: :plan, body: [%{"content" => "Inspect", "status" => "completed"}]}] =
             Blocks.from_line(completed)
  end

  test "foreign frames cannot seed task state and different peers do not share it" do
    pid = peer()
    create(pid, "theirs")
    complete(pid)
    assert_receive {:acp, _, {:lines, "acp", _}}
    assert_receive {:acp, _, {:lines, "acp", result}}
    assert [%{kind: :tool_result}] = Blocks.from_line(result)
    create(pid)
    assert_receive {:acp, _, {:lines, "acp", _}}
    assert_receive {:acp, _, {:lines, "acp", _}}
    other = peer()
    complete(other)
    assert_receive {:acp, _, {:lines, "acp", _}}
    assert_receive {:acp, _, {:lines, "acp", result}}
    assert [%{kind: :tool_result}] = Blocks.from_line(result)
  end

  test "discarded session/load history rebuilds the plan for subsequent updates" do
    pid = peer(attach: nil, replay_quiet_ms: 5)
    assert_receive {:wrote, %{"id" => init}}

    Peer.stdout(
      pid,
      IO.iodata_to_binary(Protocol.response(init, %{agentCapabilities: %{loadSession: true}}))
    )

    assert_receive {:wrote, %{"id" => load, "method" => "session/load"}}
    create(pid)
    :sys.get_state(pid)
    refute_received {:acp, _, {:lines, _, _}}
    Peer.stdout(pid, IO.iodata_to_binary(Protocol.response(load, %{sessionId: "ours"})))
    assert_receive {:wrote, %{"method" => "session/prompt"}}, 500
    complete(pid)
    assert_receive {:acp, _, {:lines, "acp", _}}
    assert_receive {:acp, _, {:lines, "acp", result}}

    assert [%{kind: :plan, body: [%{"content" => "Inspect", "status" => "completed"}]}] =
             Blocks.from_line(result)
  end
end
