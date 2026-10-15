defmodule Managoat.ACP.PeerMcpTest do
  @moduledoc """
  The peer must deliver the configured MCP servers to the agent in
  `session/new` (and on resume). This is the client half of Fountain's #837:
  it proves the peer emits a correct, non-empty `mcpServers` on the wire —
  the drop that bug tracks is downstream, in the agent adapter
  (`claude-agent-acp`), which receives this and fails to launch stdio
  servers. Keep this green so a regression on the client side is caught
  separately from the upstream issue.

  Driven through `Managoat.ACP.Testing.ScriptedAgent`, which answers the
  handshake itself and reports every frame the peer wrote.
  """
  use ExUnit.Case, async: true

  alias Managoat.ACP.Peer
  alias Managoat.ACP.Testing.ScriptedAgent

  @fs %{name: "fs", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "."]}

  defp start(opts) do
    {:ok, agent} = ScriptedAgent.start_link()

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
            cwd: "/home/sprite",
            images: [],
            mcp_servers: [@fs]
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

  test "session/new carries the configured MCP servers" do
    start(mode: :run)

    assert frame("session/new")["params"]["mcpServers"] == [
             %{
               "name" => "fs",
               "command" => "npx",
               "args" => ["-y", "@modelcontextprotocol/server-filesystem", "."]
             }
           ]
  end

  test "an agent with no MCP servers sends an empty list, not a missing key" do
    start(mode: :run, mcp_servers: [])

    assert frame("session/new")["params"]["mcpServers"] == []
  end

  test "the servers are re-sent on resume, not assumed to have survived" do
    # The adapter snapshots {cwd, mcpServers} per session and tears the
    # session down when they change, so omitting them on resume would read
    # as "the client removed every MCP server".
    {:ok, agent} =
      ScriptedAgent.start_link(capabilities: %{"sessionCapabilities" => %{"resume" => %{}}})

    {:ok, pid} =
      Peer.start(
        owner: self(),
        writer: ScriptedAgent.writer(agent),
        ref: make_ref(),
        prompt: "hi",
        mode: :continue,
        session_id: "s1",
        mcp_servers: [@fs]
      )

    :ok = ScriptedAgent.connect(agent, pid)

    assert [%{"name" => "fs"}] = frame("session/resume")["params"]["mcpServers"]
  end
end
