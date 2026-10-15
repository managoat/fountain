defmodule Managoat.ACP.PeerRestartTest do
  use ExUnit.Case, async: true

  alias Managoat.ACP.{ExecutionLimits, Peer}

  for {method, tag, capabilities} <- [
        {"session/resume", :resume_session, %{"sessionCapabilities" => %{"resume" => %{}}}},
        {"session/load", :load_session, %{"loadSession" => true}}
      ] do
    test "#{method} can recover on the same initialized peer without resetting its input or clock" do
      {:ok, limits} =
        ExecutionLimits.new(:claude, %{max_model_turns: 2, max_estimated_cost_usd: 0.25})

      peer = start_peer(execution_limits: limits, model: "model-1")
      original = :sys.get_state(peer)
      init = next_write()
      reply(peer, init["id"], %{"agentCapabilities" => unquote(Macro.escape(capabilities))})
      resume = next_write()
      assert resume["method"] == unquote(method)

      fail(peer, resume["id"])
      assert_receive {:acp, :probe, {:failed, {:acp_error, unquote(tag), _}}}
      refute_receive {:acp, :probe, {:prompt_sent, _}}, 10

      assert :ok = Peer.restart_session(peer)
      fresh = next_write()
      assert fresh["method"] == "session/new"
      assert fresh["id"] > resume["id"]
      assert fresh["params"] == Map.delete(resume["params"], "sessionId")

      recovered = :sys.get_state(peer)
      assert recovered.started_mono == original.started_mono
      assert recovered.writer == original.writer
      assert recovered.session_options == original.session_options
      assert recovered.permission_policy == original.permission_policy
      assert recovered.model == "model-1"
      refute recovered.replay_discard?

      reply(peer, fresh["id"], %{"sessionId" => "fresh", "models" => %{}})
      selected = next_write()
      assert selected["method"] == "session/set_model"
      assert selected["params"]["modelId"] == "model-1"
      assert selected["id"] > fresh["id"]
      reply(peer, selected["id"], %{})

      prompt = next_write()
      assert prompt["method"] == "session/prompt"
      assert prompt["id"] > selected["id"]
      assert prompt["params"]["sessionId"] == "fresh"

      assert prompt["params"]["prompt"] == [
               %{"type" => "text", "text" => "original input"},
               %{"type" => "image", "mimeType" => "image/png", "data" => Base.encode64("image")}
             ]

      assert_receive {:acp, :probe, {:prompt_sent, prompt_id}}
      assert prompt_id == prompt["id"]
      assert {:error, :not_restartable} = Peer.restart_session(peer)
      refute_receive {:wrote, _}, 10

      Peer.stdout(
        peer,
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{sessionId: "fresh", update: %{sessionUpdate: "agent_message_chunk"}}
        }) <> "\n"
      )

      assert_receive {:acp, :probe, {:lines, "acp", _}}
      reply(peer, prompt["id"], %{"stopReason" => "max_turn_requests"})
      assert_receive {:acp, :probe, {:done, "max_turn_requests", _}}
      assert {:error, :not_restartable} = Peer.restart_session(peer)
      refute_receive {:wrote, _}, 10
    end
  end

  test "recovery retains successful authentication without authenticating again" do
    peer = start_peer(auth: "chosen")
    init = next_write()

    reply(peer, init["id"], %{
      "agentCapabilities" => %{"loadSession" => true},
      "authMethods" => [%{"id" => "chosen", "name" => "Chosen method"}]
    })

    authenticate = next_write()
    assert authenticate["method"] == "authenticate"
    assert authenticate["params"] == %{"methodId" => "chosen"}
    reply(peer, authenticate["id"], %{})
    resume = next_write()
    assert resume["method"] == "session/load"
    authenticated = :sys.get_state(peer).auth

    fail(peer, resume["id"])
    assert_receive {:acp, :probe, {:failed, {:acp_error, :load_session, _}}}
    assert :ok = Peer.restart_session(peer)
    fresh = next_write()
    assert fresh["method"] == "session/new"
    assert :sys.get_state(peer).auth == authenticated

    reply(peer, fresh["id"], %{"sessionId" => "fresh"})
    prompt = next_write()
    assert prompt["method"] == "session/prompt"
    refute_receive {:wrote, _}, 10
  end

  test "a failed fresh session cannot restart a second time" do
    peer = failed_resume()
    assert :ok = Peer.restart_session(peer)
    fresh = next_write()
    fail(peer, fresh["id"])
    assert_receive {:acp, :probe, {:failed, {:acp_error, :new_session, _}}}
    assert {:error, :not_restartable} = Peer.restart_session(peer)
    refute_receive {:wrote, _}, 10
  end

  test "initialization and its failure are not restartable" do
    peer = start_peer()
    init = next_write()
    assert {:error, :not_restartable} = Peer.restart_session(peer)
    fail(peer, init["id"])
    assert_receive {:acp, :probe, {:failed, {:acp_error, :initialize, _}}}
    assert {:error, :not_restartable} = Peer.restart_session(peer)
    refute_receive {:wrote, _}, 10
  end

  test "an error after a prompt was sent cannot replay that prompt" do
    peer = start_peer(mode: :run, session_id: nil)
    init = next_write()
    reply(peer, init["id"], %{"agentCapabilities" => %{}})
    fresh = next_write()
    reply(peer, fresh["id"], %{"sessionId" => "fresh"})
    prompt = next_write()
    assert prompt["method"] == "session/prompt"
    fail(peer, prompt["id"])
    assert_receive {:acp, :probe, {:failed, {:acp_error, :prompt, _}}}
    assert {:error, :not_restartable} = Peer.restart_session(peer)
    refute_receive {:wrote, _}, 10
  end

  test "recovery still uses the writer's execution fence and cannot retry a refused write" do
    owner = self()

    writer = fn bytes ->
      frame = Jason.decode!(IO.iodata_to_binary(bytes))

      if frame["method"] == "session/new" do
        {:error, :execution_fenced}
      else
        send(owner, {:wrote, frame})
        :ok
      end
    end

    peer = failed_resume(writer: writer)
    assert {:error, :acp_session_restart_failed} = Peer.restart_session(peer)
    assert_receive {:acp, :probe, {:failed, {:acp_write_failed, :execution_fenced}}}
    assert {:error, :not_restartable} = Peer.restart_session(peer)
    refute_receive {:wrote, _}, 10
  end

  defp failed_resume(opts \\ []) do
    peer = start_peer(opts)
    init = next_write()
    reply(peer, init["id"], %{"agentCapabilities" => %{"loadSession" => true}})
    resume = next_write()
    fail(peer, resume["id"])
    assert_receive {:acp, :probe, {:failed, {:acp_error, :load_session, _}}}
    peer
  end

  defp start_peer(opts \\ []) do
    owner = self()

    writer = fn bytes ->
      send(owner, {:wrote, Jason.decode!(IO.iodata_to_binary(bytes))})
      :ok
    end

    {:ok, peer} =
      Peer.start(
        Keyword.merge(
          [
            owner: owner,
            writer: writer,
            ref: :probe,
            prompt: "original input",
            mode: :continue,
            session_id: "missing",
            images: [%{media_type: "image/png", data: "image"}],
            mcp_servers: [%{name: "local", command: "server"}],
            permission_policy: %{"default" => "ask"}
          ],
          opts
        )
      )

    on_exit(fn -> if Process.alive?(peer), do: Peer.close(peer) end)
    peer
  end

  defp next_write do
    assert_receive {:wrote, frame}, 1_000
    frame
  end

  defp reply(peer, id, result),
    do: Peer.stdout(peer, Jason.encode!(%{jsonrpc: "2.0", id: id, result: result}) <> "\n")

  defp fail(peer, id),
    do:
      Peer.stdout(
        peer,
        Jason.encode!(%{jsonrpc: "2.0", id: id, error: %{code: -32_002, message: "gone"}}) <> "\n"
      )
end
