defmodule Managoat.ACP.ExecutionLimitsTest do
  use ExUnit.Case, async: true

  alias Managoat.ACP.{ExecutionLimits, Peer}

  test "only known typed limits enter the session metadata" do
    assert {:ok, limits} =
             ExecutionLimits.new(:claude, %{max_model_turns: 3, max_estimated_cost_usd: 0.25})

    assert ExecutionLimits.session_params(%{cwd: "/work"}, limits) == %{
             cwd: "/work",
             _meta: %{claudeCode: %{options: %{maxTurns: 3, maxBudgetUsd: 0.25}}}
           }

    assert {:ok, requests} = ExecutionLimits.new(:claude, %{max_model_turns: 1})

    assert ExecutionLimits.session_params(%{}, requests) == %{
             _meta: %{claudeCode: %{options: %{maxTurns: 1}}}
           }

    assert {:ok, dollars} = ExecutionLimits.new(:claude, %{max_estimated_cost_usd: 1})

    assert ExecutionLimits.session_params(%{}, dollars) == %{
             _meta: %{claudeCode: %{options: %{maxBudgetUsd: 1}}}
           }

    assert ExecutionLimits.session_params(%{cwd: "/work"}, nil) == %{cwd: "/work"}
  end

  test "invalid, empty and unsupported limits are refused" do
    for adapter <- [:codex, :gemini, nil, "claude"] do
      assert {:error, :unsupported_execution_limit_adapter} =
               ExecutionLimits.new(adapter, %{max_model_turns: 1})
    end

    assert {:error, :empty_execution_limits} = ExecutionLimits.new(:claude, %{})
    assert {:error, :invalid_execution_limits} = ExecutionLimits.new(:claude, %{env: %{}})
    assert {:error, :invalid_execution_limits} = ExecutionLimits.new(:claude, [])
    assert {:error, :invalid_execution_limits} = ExecutionLimits.validate(%{max_model_turns: 1})

    assert {:error, :unsupported_execution_limit_adapter} =
             ExecutionLimits.validate(%ExecutionLimits{adapter: :codex, max_model_turns: 1})

    for value <- [0, -1, 1.5, "1", 9_007_199_254_740_992] do
      assert {:error, :invalid_max_model_turns} =
               ExecutionLimits.new(:claude, %{max_model_turns: value})
    end

    for value <- [0, -1, "1", 9_007_199_254_740_992] do
      assert {:error, :invalid_max_estimated_cost_usd} =
               ExecutionLimits.new(:claude, %{max_estimated_cost_usd: value})
    end
  end

  test "an invalid struct cannot send even an initialize frame" do
    assert {:error, :invalid_max_model_turns} =
             Peer.start(opts(%ExecutionLimits{adapter: :claude, max_model_turns: -1}))

    refute_receive {:wrote, _}
  end

  for {mode, capabilities, method} <- [
        {:run, %{}, "session/new"},
        {:continue, %{"sessionCapabilities" => %{"resume" => %{}}}, "session/resume"},
        {:continue, %{"loadSession" => true}, "session/load"}
      ] do
    test "#{method} carries the same validated limits and preserves a limit stop" do
      {:ok, limits} =
        ExecutionLimits.new(:claude, %{max_model_turns: 2, max_estimated_cost_usd: 0.25})

      {:ok, peer} =
        Peer.start(
          Keyword.merge(opts(limits), mode: unquote(mode), replay_quiet_ms: 1, replay_max_ms: 20)
        )

      init = next_write()
      reply(peer, init["id"], %{"agentCapabilities" => unquote(Macro.escape(capabilities))})
      session = next_write()
      assert session["method"] == unquote(method)

      assert session["params"]["_meta"] == %{
               "claudeCode" => %{"options" => %{"maxTurns" => 2, "maxBudgetUsd" => 0.25}}
             }

      reply(peer, session["id"], %{"sessionId" => "session"})
      prompt = next_write()
      assert prompt["method"] == "session/prompt"

      reply(peer, prompt["id"], %{
        "stopReason" => "max_turn_requests",
        "usage" => %{"inputTokens" => 10, "outputTokens" => 2}
      })

      assert_receive {:acp, :probe,
                      {:done, "max_turn_requests", %{"input" => 10, "output" => 2}}},
                     1000

      {:ok, changed} = ExecutionLimits.new(:claude, %{max_model_turns: 1})

      assert {:error, :acp_execution_limits_changed} =
               Peer.prompt(peer, "again", [], execution_limits: changed)

      assert {:error, :acp_execution_limits_changed} =
               Peer.prompt(peer, "again", [], execution_limits: nil)

      assert {:error, :invalid_execution_limits} =
               Peer.prompt(peer, "again", [], execution_limits: %{})

      refute_receive {:wrote, _}
      assert :ok = Peer.prompt(peer, "again", [], execution_limits: limits)
      assert next_write()["method"] == "session/prompt"
      Peer.close(peer)
    end
  end

  test "reattachment accepts a persisted limit snapshot without resetting the SDK session" do
    {:ok, limits} = ExecutionLimits.new(:claude, %{max_model_turns: 2})
    {:ok, peer} = Peer.start(opts(limits) ++ [attach: 7])
    refute_receive {:wrote, _}
    Peer.stdout(peer, "\n")
    reply(peer, 7, %{"stopReason" => "max_turn_requests"})
    assert_receive {:acp, :probe, {:done, "max_turn_requests", nil}}
    assert :sys.get_state(peer).session_options.execution_limits == limits
    Peer.close(peer)
  end

  for stop <- [nil, "", 42, false] do
    test "malformed stop reason #{inspect(stop)} cannot become end_turn" do
      {:ok, peer} = Peer.start(opts(nil) ++ [attach: 7])
      Peer.stdout(peer, "\n")

      reply(peer, 7, %{
        "stopReason" => unquote(stop),
        "usage" => %{"inputTokens" => 10, "outputTokens" => 2}
      })

      assert_receive {:acp, :probe, {:done, "unknown", %{"input" => 10, "output" => 2}}}
      Peer.close(peer)
    end
  end

  defp opts(limits) do
    owner = self()

    [
      owner: owner,
      writer: fn bytes ->
        send(owner, {:wrote, IO.iodata_to_binary(bytes)})
        :ok
      end,
      ref: :probe,
      prompt: "review",
      mode: :run,
      session_id: "session",
      execution_limits: limits
    ]
  end

  defp next_write do
    assert_receive {:wrote, bytes}, 1000
    Jason.decode!(bytes)
  end

  defp reply(peer, id, result) do
    Peer.stdout(peer, Jason.encode!(%{jsonrpc: "2.0", id: id, result: result}) <> "\n")
  end
end
