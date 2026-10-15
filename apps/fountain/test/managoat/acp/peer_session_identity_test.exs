defmodule Managoat.ACP.PeerSessionIdentityTest do
  use ExUnit.Case, async: true

  alias Managoat.ACP.{Peer, Protocol}

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

    pid
  end

  defp feed(pid, frame), do: Peer.stdout(pid, IO.iodata_to_binary(frame))

  defp update(session) do
    Protocol.notification(
      "session/update",
      Map.merge(session, %{
        "update" => %{
          "sessionUpdate" => "usage_update",
          "_meta" => %{"_claude/origin" => %{"kind" => "task-notification"}}
        }
      })
    )
  end

  defp permission(session, id \\ 8) do
    Protocol.request(
      id,
      "session/request_permission",
      Map.merge(session, %{
        "toolCall" => %{"title" => "execute command", "kind" => "execute"},
        "options" => [%{"optionId" => "yes", "kind" => "allow_always"}]
      })
    )
  end

  test "foreign updates produce neither transcript lines nor cycle ends, even while idle" do
    pid = peer()
    feed(pid, update(%{"sessionId" => "theirs"}))
    feed(pid, Protocol.response(4, %{stopReason: "end_turn"}))
    assert_receive {:acp, _, {:done, "end_turn", nil}}
    feed(pid, update(%{"sessionId" => "theirs"}))
    :sys.get_state(pid)
    refute_received {:acp, _, {:lines, _, _}}
    refute_received {:acp, _, {:cycle_end, _}}
    feed(pid, update(%{"sessionId" => "ours"}))
    assert_receive {:acp, _, {:lines, "acp", _}}
    assert_receive {:acp, _, {:cycle_end, "task-notification"}}
  end

  for policy <- ["auto_allow", "auto_deny", "ask"] do
    test "foreign permissions bypass #{policy}, including a colliding held request id" do
      pid = peer(permission_policy: %{"default" => unquote(policy)})
      feed(pid, permission(%{"sessionId" => "theirs"}))

      assert_receive {:wrote,
                      %{"id" => 8, "result" => %{"outcome" => %{"outcome" => "cancelled"}}}}

      :sys.get_state(pid)
      refute_received {:acp, _, _}

      feed(pid, permission(%{"sessionId" => "ours"}))

      if unquote(policy) == "ask" do
        assert_receive {:acp, _, {:permission_ask, request_id, _, _}}
        feed(pid, permission(%{"sessionId" => "theirs"}))
        assert_receive {:wrote, %{"result" => %{"outcome" => %{"outcome" => "cancelled"}}}}
        assert :ok = Peer.answer_permission(pid, request_id, "yes")
        assert_receive {:wrote, %{"result" => %{"outcome" => %{"optionId" => "yes"}}}}
      else
        assert_receive {:wrote, %{"id" => 8}}
      end
    end
  end

  for session <- [%{}, %{"sessionId" => nil}, %{"sessionId" => "ours"}] do
    test "compatible frames keep flowing: #{inspect(session)}" do
      pid = peer()
      feed(pid, update(unquote(Macro.escape(session))))
      assert_receive {:acp, _, {:lines, "acp", _}}
      feed(pid, permission(unquote(Macro.escape(session))))
      assert_receive {:wrote, %{"result" => %{"outcome" => %{"optionId" => "yes"}}}}
    end
  end

  test "session/new can emit frames before its response establishes identity" do
    pid = peer(mode: :run, session_id: nil, attach: nil)
    assert_receive {:wrote, %{"id" => init_id}}
    feed(pid, Protocol.response(init_id, %{agentCapabilities: %{}}))
    assert_receive {:wrote, %{"method" => "session/new", "id" => new_id}}
    feed(pid, update(%{"sessionId" => "ours"}))
    assert_receive {:acp, _, {:lines, "acp", _}}
    feed(pid, permission(%{"sessionId" => "ours"}))
    assert_receive {:wrote, %{"id" => 8, "result" => %{"outcome" => %{"optionId" => "yes"}}}}
    feed(pid, Protocol.response(new_id, %{sessionId: "ours"}))
    assert_receive {:wrote, %{"method" => "session/prompt"}}
    feed(pid, update(%{"sessionId" => "theirs"}))
    :sys.get_state(pid)
    refute_received {:acp, _, {:lines, _, _}}
  end

  test "foreign replay does not extend the session/load quiet window" do
    pid = peer(attach: nil, replay_quiet_ms: 5_000)
    assert_receive {:wrote, %{"id" => init_id}}
    feed(pid, Protocol.response(init_id, %{agentCapabilities: %{loadSession: true}}))
    assert_receive {:wrote, %{"method" => "session/load", "id" => load_id}}
    feed(pid, Protocol.response(load_id, %{}))
    before = :sys.get_state(pid)
    feed(pid, update(%{"sessionId" => "theirs"}))
    after_foreign = :sys.get_state(pid)
    assert after_foreign.replay_last_ms == before.replay_last_ms
    refute_received {:acp, _, {:lines, _, _}}
  end
end
