defmodule Managoat.ACP.Testing.ScriptedAgentTest do
  @moduledoc """
  Whole turns through a real peer and the scripted agent: the shape a host's
  own tests can use, and the proof that the agent answers the handshake the
  way the peer expects.
  """
  use ExUnit.Case, async: true

  alias Managoat.ACP.Peer
  alias Managoat.ACP.Testing.ScriptedAgent

  defp text(text),
    do: %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => text}
    }

  defp start(agent_opts, peer_opts \\ []) do
    {:ok, agent} = ScriptedAgent.start_link(agent_opts)

    {:ok, peer} =
      Peer.start(
        Keyword.merge(
          [
            owner: self(),
            writer: ScriptedAgent.writer(agent),
            ref: make_ref(),
            prompt: "say hello",
            mode: :run,
            session_id: nil
          ],
          peer_opts
        )
      )

    :ok = ScriptedAgent.connect(agent, peer)
    {agent, peer}
  end

  test "a turn: handshake, session, prompt, updates, done" do
    {_agent, _peer} =
      start(
        updates: [text("hel"), text("lo")],
        usage: %{"inputTokens" => 10, "outputTokens" => 2}
      )

    assert_receive {:acp, _, {:handshake_ms, _, "session/new"}}
    assert_receive {:acp, _, {:session, "scripted-session"}}
    assert_receive {:acp, _, {:prompt_sent, prompt_id}}
    assert is_integer(prompt_id)

    assert_receive {:acp, _, {:lines, "acp", first}}
    assert first =~ "hel"
    assert_receive {:acp, _, {:lines, "acp", second}}
    assert second =~ "lo"

    assert_receive {:acp, _, {:done, "end_turn", %{"input" => 10, "output" => 2}}}

    # The wire, as the agent saw it, in order.
    assert_received {:scripted_agent, :wrote, %{"method" => "initialize"}}
    assert_received {:scripted_agent, :wrote, %{"method" => "session/new"}}
    assert_received {:scripted_agent, :wrote, %{"method" => "session/prompt", "params" => params}}
    assert [%{"type" => "text", "text" => "say hello"}] = params["prompt"]
  end

  test "the connection outlives the turn: a second prompt, then close" do
    {agent, peer} = start(updates: [text("one")])
    assert_receive {:acp, _, {:lines, "acp", _first_turn}}
    assert_receive {:acp, _, {:done, "end_turn", nil}}

    assert :ok = Peer.prompt(peer, "again")
    assert_receive {:acp, _, {:lines, "acp", line}}
    assert line =~ "one"
    assert_receive {:acp, _, {:done, "end_turn", nil}}

    # Out of turn, the agent may still talk; the owner still hears it.
    ScriptedAgent.update(agent, text("later"))
    assert_receive {:acp, _, {:lines, "acp", late}}
    assert late =~ "later"

    mon = Process.monitor(peer)
    Peer.close(peer)
    assert_receive {:DOWN, ^mon, :process, ^peer, :normal}
  end

  test "a permission request under `ask` is held for the owner, then answered" do
    permission = %{
      "toolCall" => %{"title" => "rm -rf build", "kind" => "execute"},
      "options" => [
        %{"optionId" => "yes", "kind" => "allow_once"},
        %{"optionId" => "no", "kind" => "reject_once"}
      ]
    }

    {_agent, peer} =
      start([permission: permission, updates: [text("done")]],
        permission_policy: %{"execute" => "ask"}
      )

    # The request renders inline and the owner is told to ask a human.
    assert_receive {:acp, _, {:lines, "acp", line}}
    assert line =~ "session/request_permission"
    assert_receive {:acp, _, {:permission_ask, request_id, "rm -rf build", options}}
    assert Enum.map(options, & &1["optionId"]) == ["yes", "no"]

    # The agent is blocked: no updates yet.
    refute_receive {:acp, _, {:done, _, _}}, 50

    assert :ok = Peer.answer_permission(peer, request_id, "yes")

    assert_receive {:scripted_agent, :permission_answered,
                    %{"outcome" => "selected", "optionId" => "yes"}}

    assert_receive {:acp, _, {:lines, "acp", update}}
    assert update =~ "done"
    assert_receive {:acp, _, {:done, "end_turn", nil}}
  end

  test "a denied request is answered from the agent's own options and reported" do
    permission = %{
      "toolCall" => %{"title" => "curl", "kind" => "fetch"},
      "options" => [
        %{"optionId" => "ok", "kind" => "allow_always"},
        %{"optionId" => "nope", "kind" => "reject_always"}
      ]
    }

    start([permission: permission], permission_policy: %{"fetch" => "auto_deny"})

    assert_receive {:scripted_agent, :permission_answered, %{"optionId" => "nope"}}
    assert_receive {:acp, _, {:permission_denied, "curl", "auto_deny"}}
    assert_receive {:acp, _, {:done, "end_turn", nil}}
  end

  test "a timed-out ask is denied by the owner and the turn goes on" do
    permission = %{
      "toolCall" => %{"kind" => "edit"},
      "options" => [%{"optionId" => "y", "kind" => "allow_once"}]
    }

    {_agent, peer} = start([permission: permission], permission_policy: %{"default" => "ask"})
    assert_receive {:acp, _, {:permission_ask, request_id, "edit", _}}

    # What the owner's timeout does. No rejection was offered, so the answer
    # is the protocol's own `cancelled`, never the allow.
    Peer.deny_permission(peer, request_id)

    assert_receive {:scripted_agent, :permission_answered, %{"outcome" => "cancelled"}}
    assert_receive {:acp, _, {:done, "end_turn", nil}}
  end

  test "cancel ends the turn with the agent's cancelled stop reason" do
    # No updates and no permission, so the prompt would be answered at once;
    # hold it open by giving the agent a permission it never gets an answer
    # to, then cancel.
    permission = %{"toolCall" => %{"kind" => "execute"}, "options" => []}
    {_agent, peer} = start([permission: permission], permission_policy: %{"default" => "ask"})
    assert_receive {:acp, _, {:permission_ask, _, _, _}}

    Peer.cancel(peer)

    assert_receive {:scripted_agent, :wrote, %{"method" => "session/cancel"}}
    assert_receive {:acp, _, {:done, "cancelled", nil}}
  end

  test "resume goes through session/resume when advertised, and pins a model when offered" do
    {_agent, _peer} =
      start(
        [
          capabilities: %{"sessionCapabilities" => %{"resume" => %{}}},
          session_result: %{"configOptions" => [%{"id" => "model"}]}
        ],
        mode: :continue,
        session_id: "s-old",
        model: "claude-sonnet-4-6"
      )

    assert_receive {:acp, _, {:handshake_ms, _, "session/resume"}}

    assert_receive {:scripted_agent, :wrote,
                    %{"method" => "session/resume", "params" => %{"sessionId" => "s-old"}}}

    assert_receive {:scripted_agent, :wrote,
                    %{
                      "method" => "session/set_config_option",
                      "params" => %{"value" => "claude-sonnet-4-6"}
                    }}

    assert_receive {:acp, _, {:done, "end_turn", nil}}
  end

  test "an agent that advertises an api-key auth method is authenticated first" do
    start(auth_methods: [%{"id" => "key", "_meta" => %{"api-key" => %{}}}])

    assert_receive {:scripted_agent, :wrote,
                    %{"method" => "authenticate", "params" => %{"methodId" => "key"}}}

    assert_receive {:scripted_agent, :wrote, %{"method" => "session/new"}}
    assert_receive {:acp, _, {:done, "end_turn", nil}}
  end

  test "an unsupported client method gets method-not-found, from either side" do
    {agent, _peer} = start([])
    assert_receive {:acp, _, {:done, "end_turn", nil}}

    ScriptedAgent.raw(
      agent,
      ~s({"jsonrpc":"2.0","id":77,"method":"fs/read_text_file","params":{}})
    )

    assert_receive {:scripted_agent, :wrote, %{"id" => 77, "error" => %{"code" => -32_601}}}
  end

  test "the scripted agent rejects peer methods it does not implement" do
    {:ok, agent} = ScriptedAgent.start_link([])

    :ok =
      ScriptedAgent.writer(agent).(Managoat.ACP.Protocol.request(99, "session/unknown", %{}))

    assert_receive {:scripted_agent, :wrote, %{"id" => 99, "method" => "session/unknown"}}
    :ok = ScriptedAgent.connect(agent, self())

    assert_receive {:"$gen_cast", {:stdout, response}}
    assert %{"id" => 99, "error" => %{"code" => -32_601}} = Jason.decode!(response)
  end
end
