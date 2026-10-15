defmodule Managoat.ACP.PeerAdditionalDirectoriesTest do
  @moduledoc """
  `:additional_directories` reaches the agent as ACP's `additionalDirectories`
  on every session-setup call, and only when the agent advertises it. This is
  the client half of managoat/fountain#1684: codex-acp adds these directories
  to its sandbox's writable roots, which is how a clone outside the agent's
  cwd becomes one it can cut a worktree from.
  """
  use ExUnit.Case, async: true

  alias Managoat.ACP.Peer
  alias Managoat.ACP.Testing.ScriptedAgent

  @advertised %{"sessionCapabilities" => %{"additionalDirectories" => %{}, "resume" => %{}}}
  @dirs ["/workspace/ravix", "/workspace/docs"]

  defp start(agent_opts, opts) do
    {:ok, agent} = ScriptedAgent.start_link(agent_opts)

    {:ok, pid} =
      Peer.start(
        Keyword.merge(
          [
            owner: self(),
            writer: ScriptedAgent.writer(agent),
            ref: make_ref(),
            prompt: "hi",
            mode: :run,
            session_id: nil,
            additional_directories: @dirs
          ],
          opts
        )
      )

    :ok = ScriptedAgent.connect(agent, pid)
    pid
  end

  defp frame(method) do
    assert_receive {:scripted_agent, :wrote, %{"method" => ^method} = frame}, 1_000
    frame
  end

  test "session/new carries the directories when the agent advertises them" do
    start([capabilities: @advertised], [])

    assert frame("session/new")["params"]["additionalDirectories"] == @dirs
  end

  test "session/resume re-sends them rather than assuming they survived" do
    start([capabilities: @advertised], mode: :continue, session_id: "s1")

    assert frame("session/resume")["params"]["additionalDirectories"] == @dirs
  end

  test "session/load re-sends them too" do
    caps = %{"loadSession" => true, "sessionCapabilities" => %{"additionalDirectories" => %{}}}
    start([capabilities: caps], mode: :continue, session_id: "s1")

    assert frame("session/load")["params"]["additionalDirectories"] == @dirs
  end

  test "an agent that does not advertise them is not handed the field" do
    start([capabilities: %{}], [])

    refute Map.has_key?(frame("session/new")["params"], "additionalDirectories")
  end

  test "no directories sends no field, even to an agent that advertises it" do
    start([capabilities: @advertised], additional_directories: [])

    refute Map.has_key?(frame("session/new")["params"], "additionalDirectories")
  end

  test "they sit beside execution limits rather than replacing them" do
    {:ok, limits} = Managoat.ACP.ExecutionLimits.new(:claude, %{max_model_turns: 3})
    start([capabilities: @advertised], execution_limits: limits)

    params = frame("session/new")["params"]
    assert params["additionalDirectories"] == @dirs
    assert params["_meta"]["claudeCode"]["options"]["maxTurns"] == 3
  end

  describe "start/1 refuses before writing a byte" do
    for bad <- [["relative/path"], [""], [:atom], "/not/a/list"] do
      test "additional_directories: #{inspect(bad)}" do
        assert {:error, :invalid_additional_directories} =
                 Peer.start(
                   owner: self(),
                   writer: fn _ -> :ok end,
                   ref: make_ref(),
                   prompt: "hi",
                   mode: :run,
                   session_id: nil,
                   additional_directories: unquote(bad)
                 )
      end
    end
  end
end
