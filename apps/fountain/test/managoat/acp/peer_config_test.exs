defmodule Managoat.ACP.PeerConfigTest do
  @moduledoc """
  `:config` sets session config options (reasoning effort, fast mode) through
  `session/set_config_option`, after the model and before every prompt
  (managoat/fountain#2537). The option ids, categories and value shapes below
  are the pinned adapters' own: claude-agent-acp 0.81.2 (`effort`, `fast`)
  and codex-acp 1.10.0 (`reasoning_effort`, `fast-mode`).
  """
  use ExUnit.Case, async: true

  alias Managoat.ACP.Peer
  alias Managoat.ACP.Testing.ScriptedAgent

  import ExUnit.CaptureLog

  @resume %{"sessionCapabilities" => %{"resume" => %{}}}

  defp model_option(current),
    do: %{"id" => "model", "type" => "select", "currentValue" => current}

  defp effort_option(current, values \\ ~w(low medium high)),
    do: %{
      "id" => "effort",
      "category" => "thought_level",
      "type" => "select",
      "currentValue" => current,
      "options" => Enum.map(values, &%{"value" => &1, "name" => &1})
    }

  defp fast_boolean(current),
    do: %{
      "id" => "fast",
      "category" => "model_config",
      "type" => "boolean",
      "currentValue" => current
    }

  defp fast_select(current),
    do: %{
      "id" => "fast-mode",
      "category" => "model_config",
      "type" => "select",
      "currentValue" => current,
      "options" => [%{"value" => "off", "name" => "Off"}, %{"value" => "on", "name" => "On"}]
    }

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
            session_id: nil
          ],
          opts
        )
      )

    :ok = ScriptedAgent.connect(agent, pid)
    {agent, pid}
  end

  defp frame(method) do
    assert_receive {:scripted_agent, :wrote, %{"method" => ^method} = frame}, 1_000
    frame
  end

  # Every method the peer wrote, in order, up to and including the prompt.
  defp methods_through_prompt(acc \\ []) do
    assert_receive {:scripted_agent, :wrote, %{"method" => method} = frame}, 1_000
    acc = [{method, frame["params"]["configId"]} | acc]
    if method == "session/prompt", do: Enum.reverse(acc), else: methods_through_prompt(acc)
  end

  describe "applying" do
    test "model first, then each option in the order the agent lists them, then the prompt" do
      options = [model_option("default"), effort_option("medium"), fast_boolean(false)]

      start([session_result: %{"configOptions" => options}],
        model: "opus",
        config: %{"fast" => true, "effort" => "high"}
      )

      assert methods_through_prompt() == [
               {"initialize", nil},
               {"session/new", nil},
               {"session/set_config_option", "model"},
               {"session/set_config_option", "effort"},
               {"session/set_config_option", "fast"},
               {"session/prompt", nil}
             ]

      # `:model_selected` is last: hosts read it as "the prompt is going out".
      assert_receive {:acp, _, {:config_selected, "effort", "high", "high"}}
      assert_receive {:acp, _, {:config_selected, "fast", true, true}}
      assert_receive {:acp, _, {:config_options, final}}
      assert_receive {:acp, _, {:model_selected, "opus", "opus", "runtime"}}
      assert Enum.find(final, &(&1["id"] == "effort"))["currentValue"] == "high"
      assert_receive {:acp, _, {:done, "end_turn", nil}}
    end

    test "a boolean option is sent with the type the protocol requires beside it" do
      start([session_result: %{"configOptions" => [fast_boolean(false)]}],
        config: %{"fast" => true}
      )

      assert %{"params" => %{"configId" => "fast", "type" => "boolean", "value" => true}} =
               frame("session/set_config_option")
    end

    test "a boolean request against an on/off select is sent as the select's value" do
      # codex-acp without the boolean capability: the fallback shape.
      start([session_result: %{"configOptions" => [fast_select("off")]}],
        config: %{"fast-mode" => true}
      )

      params = frame("session/set_config_option")["params"]
      assert params["value"] == "on"
      refute Map.has_key?(params, "type")
      assert_receive {:acp, _, {:config_selected, "fast-mode", true, "on"}}
    end

    test "an on/off request against a boolean option is sent as a boolean" do
      start([session_result: %{"configOptions" => [fast_boolean(true)]}],
        config: %{"fast" => "off"}
      )

      assert %{"params" => %{"type" => "boolean", "value" => false}} =
               frame("session/set_config_option")
    end

    test "a value the agent already reports is not sent again" do
      start([session_result: %{"configOptions" => [effort_option("high")]}],
        config: %{"effort" => "high"}
      )

      assert_receive {:acp, _, {:config_selected, "effort", "high", "high"}}
      frame("session/prompt")
      refute_received {:scripted_agent, :wrote, %{"method" => "session/set_config_option"}}
    end

    test "with no model requested, config still comes before the prompt" do
      start([session_result: %{"configOptions" => [effort_option("low")]}],
        config: %{"effort" => "medium"}
      )

      assert methods_through_prompt() == [
               {"initialize", nil},
               {"session/new", nil},
               {"session/set_config_option", "effort"},
               {"session/prompt", nil}
             ]
    end

    test "with nothing requested, the offered options are still reported" do
      start([session_result: %{"configOptions" => [effort_option("low")]}], [])

      assert_receive {:acp, _, {:config_options, [%{"id" => "effort"}]}}
      assert_receive {:acp, _, {:done, "end_turn", nil}}
    end

    test "an agent that advertises no options reports none" do
      start([], [])

      assert_receive {:acp, _, {:done, "end_turn", nil}}
      refute_received {:acp, _, {:config_options, _}}
    end
  end

  describe "skipping" do
    test "an id the agent does not advertise is reported and the turn goes on" do
      start([session_result: %{"configOptions" => [effort_option("low")]}],
        config: %{"reasoning_effort" => "high", "effort" => "high"}
      )

      assert_receive {:acp, _, {:config_selected, "effort", "high", "high"}}
      assert_receive {:acp, _, {:config_skipped, "reasoning_effort", "high"}}
      assert_receive {:acp, _, {:done, "end_turn", nil}}
    end

    test "every id is skipped when the agent has no config options at all" do
      start([], config: %{"effort" => "high"})

      assert_receive {:acp, _, {:config_skipped, "effort", "high"}}
      assert_receive {:acp, _, {:done, "end_turn", nil}}
    end
  end

  describe "refusals" do
    test "a value the agent refuses fails the turn with its sentence, before the prompt" do
      start([session_result: %{"configOptions" => [effort_option("low", ~w(low high))]}],
        config: %{"effort" => "max"}
      )

      assert_receive {:acp, _, {:failed, {:config_selection_failed, "effort", "max", detail}}}
      assert detail =~ "Invalid value for config option effort"
      # No prompt, so nothing reads as a turn that spent tokens.
      refute_received {:acp, _, {:model_selected, _, _, _}}
      refute_receive {:scripted_agent, :wrote, %{"method" => "session/prompt"}}, 50
    end

    test "claude's detail is read from data.details, as for the model" do
      test = self()
      writer = fn data -> send(test, {:wrote, Jason.decode!(data)}) && :ok end

      {:ok, pid} =
        Peer.start(
          owner: self(),
          writer: writer,
          ref: make_ref(),
          prompt: "hi",
          mode: :run,
          session_id: nil,
          config: %{"effort" => "max"}
        )

      assert_receive {:wrote, %{"id" => init}}
      reply(pid, init, %{"agentCapabilities" => %{}})
      assert_receive {:wrote, %{"id" => new}}
      reply(pid, new, %{"sessionId" => "s", "configOptions" => [effort_option("low")]})
      assert_receive {:wrote, %{"id" => set, "method" => "session/set_config_option"}}

      line(pid, %{
        "jsonrpc" => "2.0",
        "id" => set,
        "error" => %{
          "code" => -32_603,
          "message" => "Internal error",
          "data" => %{"details" => "Invalid value for config option effort: max"}
        }
      })

      assert_receive {:acp, _,
                      {:failed,
                       {:config_selection_failed, "effort", "max",
                        "Invalid value for config option effort: max"}}}

      refute_receive {:wrote, _}, 50
    end
  end

  describe "against the model" do
    # Claude's effort option exists only on a model that supports effort. The
    # pin's response is the set that counts, not the session result.
    test "options are read from the model pin's response" do
      test = self()
      writer = fn data -> send(test, {:wrote, Jason.decode!(data)}) && :ok end

      {:ok, pid} =
        Peer.start(
          owner: self(),
          writer: writer,
          ref: make_ref(),
          prompt: "hi",
          mode: :run,
          session_id: nil,
          model: "haiku",
          config: %{"effort" => "high"}
        )

      assert_receive {:wrote, %{"id" => init}}
      reply(pid, init, %{"agentCapabilities" => %{}})
      assert_receive {:wrote, %{"id" => new}}

      reply(pid, new, %{
        "sessionId" => "s",
        "configOptions" => [model_option("opus"), effort_option("medium")]
      })

      assert_receive {:wrote, %{"id" => set, "params" => %{"configId" => "model"}}}
      reply(pid, set, %{"configOptions" => [model_option("haiku")]})

      assert_receive {:acp, _, {:config_skipped, "effort", "high"}}
      assert_receive {:wrote, %{"method" => "session/prompt"}}
    end
  end

  describe "later turns" do
    test "each turn re-applies what the agent no longer reports, and prompt/4 replaces the request" do
      {agent, pid} =
        start([session_result: %{"configOptions" => [effort_option("low")]}],
          config: %{"effort" => "high"}
        )

      assert_receive {:acp, _, {:done, "end_turn", nil}}

      # The agent moves the option on its own, as claude does for fast mode's
      # cooldown; the peer reads the notification, so the next turn re-pins.
      ScriptedAgent.update(agent, %{
        "sessionUpdate" => "config_option_update",
        "configOptions" => [effort_option("low")]
      })

      flush_writes()
      assert :ok = Peer.prompt(pid, "again", [])
      assert %{"params" => %{"value" => "high"}} = frame("session/set_config_option")
      assert_receive {:acp, _, {:done, "end_turn", nil}}

      flush_writes()
      assert :ok = Peer.prompt(pid, "lower", [], config: %{"effort" => "medium"})
      assert %{"params" => %{"value" => "medium"}} = frame("session/set_config_option")
      assert_receive {:acp, _, {:done, "end_turn", nil}}

      # Cleared, so the option goes back to what the session started on.
      flush_writes()
      assert :ok = Peer.prompt(pid, "cleared", [], config: nil)
      assert %{"params" => %{"value" => "low"}} = frame("session/set_config_option")
      assert_receive {:acp, _, {:config_restored, "effort", "low"}}
      assert_receive {:acp, _, {:done, "end_turn", nil}}
    end

    test "a resumed session is pinned again from what the resume reports" do
      # A new adapter process after the sandbox slept: the setting did not
      # survive, and the resume result says so.
      start(
        [capabilities: @resume, session_result: %{"configOptions" => [effort_option("medium")]}],
        mode: :continue,
        session_id: "s1",
        config: %{"effort" => "high"}
      )

      frame("session/resume")
      assert %{"params" => %{"value" => "high"}} = frame("session/set_config_option")
      assert_receive {:acp, _, {:done, "end_turn", nil}}
    end

    test "a loaded session is pinned from what the load reports" do
      caps = %{"loadSession" => true}

      start(
        [capabilities: caps, session_result: %{"configOptions" => [effort_option("medium")]}],
        mode: :continue,
        session_id: "s1",
        config: %{"effort" => "high"},
        replay_quiet_ms: 5
      )

      frame("session/load")
      assert %{"params" => %{"value" => "high"}} = frame("session/set_config_option")
      assert_receive {:acp, _, {:done, "end_turn", nil}}
    end
  end

  describe "a turn's options hold for that turn" do
    test "an option only one prompt asked for is put back on the next turn" do
      {_agent, pid} =
        start(
          [session_result: %{"configOptions" => [effort_option("medium"), fast_boolean(false)]}],
          config: %{"effort" => "high", "fast" => true}
        )

      assert_receive {:acp, _, {:done, "end_turn", nil}}
      flush_mailbox()

      assert :ok = Peer.prompt(pid, "plain", [], config: %{})

      assert methods_through_prompt() == [
               {"session/set_config_option", "effort"},
               {"session/set_config_option", "fast"},
               {"session/prompt", nil}
             ]

      assert_receive {:acp, _, {:config_restored, "effort", "medium"}}
      assert_receive {:acp, _, {:config_restored, "fast", false}}
      assert_receive {:acp, _, {:config_options, options}}
      assert Enum.find(options, &(&1["id"] == "effort"))["currentValue"] == "medium"
      assert Enum.find(options, &(&1["id"] == "fast"))["currentValue"] == false
      assert_receive {:acp, _, {:done, "end_turn", nil}}

      # Restored, so a third plain turn has nothing to send.
      flush_writes()
      assert :ok = Peer.prompt(pid, "plain again", [], config: %{})
      assert methods_through_prompt() == [{"session/prompt", nil}]
      refute_received {:acp, _, {:config_restored, _, _}}
    end

    test "an option every turn names is never put back" do
      {_agent, pid} =
        start([session_result: %{"configOptions" => [effort_option("medium")]}],
          config: %{"effort" => "high"}
        )

      assert_receive {:acp, _, {:done, "end_turn", nil}}

      for opts <- [[config: %{"effort" => "high"}], []] do
        flush_writes()
        assert :ok = Peer.prompt(pid, "again", [], opts)
        assert methods_through_prompt() == [{"session/prompt", nil}]
        assert_receive {:acp, _, {:config_selected, "effort", "high", "high"}}
        refute_received {:acp, _, {:config_restored, _, _}}
        assert_receive {:acp, _, {:done, "end_turn", nil}}
      end
    end

    test "only the ids a turn leaves out are put back" do
      {_agent, pid} =
        start(
          [session_result: %{"configOptions" => [effort_option("medium"), fast_boolean(false)]}],
          config: %{"effort" => "high", "fast" => true}
        )

      assert_receive {:acp, _, {:done, "end_turn", nil}}
      flush_writes()

      assert :ok = Peer.prompt(pid, "fast only", [], config: %{"fast" => true})

      assert methods_through_prompt() == [
               {"session/set_config_option", "effort"},
               {"session/prompt", nil}
             ]

      assert_receive {:acp, _, {:config_restored, "effort", "medium"}}
      assert_receive {:acp, _, {:config_selected, "fast", true, true}}
    end

    test "the baseline is the value before the session's first change, not the last" do
      {_agent, pid} =
        start([session_result: %{"configOptions" => [effort_option("low")]}],
          config: %{"effort" => "high"}
        )

      assert_receive {:acp, _, {:done, "end_turn", nil}}
      assert :ok = Peer.prompt(pid, "medium", [], config: %{"effort" => "medium"})
      assert_receive {:acp, _, {:done, "end_turn", nil}}
      flush_writes()

      assert :ok = Peer.prompt(pid, "plain", [], config: %{})
      assert %{"params" => %{"value" => "low"}} = frame("session/set_config_option")
      assert_receive {:acp, _, {:config_restored, "effort", "low"}}
    end

    test "a restore is skipped when the option is already at its baseline" do
      {_agent, pid} =
        start([session_result: %{"configOptions" => [effort_option("medium")]}],
          config: %{"effort" => "high"}
        )

      assert_receive {:acp, _, {:done, "end_turn", nil}}

      # Asked back to the starting value explicitly: sent as a selection.
      flush_writes()
      assert :ok = Peer.prompt(pid, "back", [], config: %{"effort" => "medium"})
      assert %{"params" => %{"value" => "medium"}} = frame("session/set_config_option")
      assert_receive {:acp, _, {:done, "end_turn", nil}}

      # Now nothing names it, and it already is the baseline.
      flush_writes()
      assert :ok = Peer.prompt(pid, "plain", [], config: %{})
      assert methods_through_prompt() == [{"session/prompt", nil}]
      refute_received {:acp, _, {:config_restored, _, _}}
    end

    test "a restore is skipped when the agent no longer offers the option or the value" do
      {agent, pid} =
        start(
          [session_result: %{"configOptions" => [effort_option("medium"), fast_boolean(false)]}],
          config: %{"effort" => "high", "fast" => true}
        )

      assert_receive {:acp, _, {:done, "end_turn", nil}}

      # Another model: effort no longer takes "medium", fast is gone.
      ScriptedAgent.update(agent, %{
        "sessionUpdate" => "config_option_update",
        "configOptions" => [effort_option("high", ~w(high max))]
      })

      flush_writes()
      assert :ok = Peer.prompt(pid, "plain", [], config: %{})
      assert methods_through_prompt() == [{"session/prompt", nil}]
      refute_received {:acp, _, {:config_restored, _, _}}
      assert_receive {:acp, _, {:done, "end_turn", nil}}
    end

    test "a restore checks a grouped select's values, and takes an option that lists none at its word" do
      grouped = %{
        "id" => "effort",
        "type" => "select",
        "currentValue" => "medium",
        "options" => [
          %{"group" => "fast", "name" => "Fast", "options" => [%{"value" => "low"}]},
          %{
            "group" => "deep",
            "name" => "Deep",
            "options" => [%{"value" => "medium"}, %{"value" => "high"}]
          },
          %{"name" => "malformed"}
        ]
      }

      free = %{"id" => "persona", "type" => "select", "currentValue" => "plain"}
      unset = %{"id" => "style", "type" => "select"}

      {_agent, pid} =
        start([session_result: %{"configOptions" => [grouped, free, unset]}],
          config: %{"effort" => "high", "persona" => "pirate", "style" => "terse"}
        )

      assert_receive {:acp, _, {:done, "end_turn", nil}}
      flush_mailbox()

      assert :ok = Peer.prompt(pid, "plain", [], config: %{})

      # `style` had no value before the change, so there is nothing to restore.
      assert methods_through_prompt() == [
               {"session/set_config_option", "effort"},
               {"session/set_config_option", "persona"},
               {"session/prompt", nil}
             ]

      assert_receive {:acp, _, {:config_restored, "effort", "medium"}}
      assert_receive {:acp, _, {:config_restored, "persona", "plain"}}
    end

    test "a refused restore does not fail the turn" do
      test = self()
      writer = fn data -> send(test, {:wrote, Jason.decode!(data)}) && :ok end

      {:ok, pid} =
        Peer.start(
          owner: self(),
          writer: writer,
          ref: make_ref(),
          prompt: "hi",
          mode: :run,
          session_id: nil,
          config: %{"effort" => "high"}
        )

      assert_receive {:wrote, %{"id" => init}}
      reply(pid, init, %{"agentCapabilities" => %{}})
      assert_receive {:wrote, %{"id" => new}}
      reply(pid, new, %{"sessionId" => "s", "configOptions" => [effort_option("low")]})
      assert_receive {:wrote, %{"id" => set, "method" => "session/set_config_option"}}
      reply(pid, set, %{"configOptions" => [effort_option("high")]})
      assert_receive {:wrote, %{"id" => prompt, "method" => "session/prompt"}}
      reply(pid, prompt, %{"stopReason" => "end_turn"})
      assert_receive {:acp, _, {:done, "end_turn", nil}}

      assert :ok = Peer.prompt(pid, "plain", [], config: %{})
      assert_receive {:wrote, %{"id" => restore, "params" => %{"value" => "low"}}}

      log =
        capture_log(fn ->
          line(pid, %{
            "jsonrpc" => "2.0",
            "id" => restore,
            "error" => %{"code" => -32_602, "message" => "Invalid value"}
          })

          assert_receive {:wrote, %{"id" => prompt, "method" => "session/prompt"}}
          send(test, {:prompt_id, prompt})
        end)

      assert log =~ "could not restore effort"
      assert_received {:prompt_id, prompt}
      refute_received {:acp, _, {:failed, _}}
      reply(pid, prompt, %{"stopReason" => "end_turn"})
      assert_receive {:acp, _, {:done, "end_turn", nil}}

      # The baseline went with the refusal: the next plain turn tries nothing.
      assert :ok = Peer.prompt(pid, "plain again", [], config: %{})
      assert_receive {:wrote, %{"method" => "session/prompt"}}
    end

    test "a new session starts with no baselines" do
      test = self()
      writer = fn data -> send(test, {:wrote, Jason.decode!(data)}) && :ok end

      {:ok, pid} =
        Peer.start(
          owner: self(),
          writer: writer,
          ref: make_ref(),
          prompt: "hi",
          mode: :continue,
          session_id: "gone"
        )

      assert_receive {:wrote, %{"id" => init}}
      reply(pid, init, %{"agentCapabilities" => %{"loadSession" => true}})
      assert_receive {:wrote, %{"id" => load, "method" => "session/load"}}

      line(pid, %{
        "jsonrpc" => "2.0",
        "id" => load,
        "error" => %{"code" => -32_603, "message" => "gone"}
      })

      assert_receive {:acp, _, {:failed, _}}

      # A baseline left from the old session (effort was "low" before a
      # change) must not be carried into the new one.
      :sys.replace_state(pid, fn state ->
        put_in(state.config.baseline, %{"effort" => "low"})
      end)

      assert :ok = Peer.restart_session(pid)
      assert %{config: %{baseline: baseline}} = :sys.get_state(pid)
      assert baseline == %{}
      assert_receive {:wrote, %{"id" => new, "method" => "session/new"}}
      reply(pid, new, %{"sessionId" => "fresh", "configOptions" => [effort_option("high")]})
      assert_receive {:wrote, %{"method" => "session/prompt"}}
      refute_received {:wrote, %{"method" => "session/set_config_option"}}
    end
  end

  describe "validation" do
    for bad <- [
          %{"model" => "opus"},
          %{"" => "x"},
          %{effort: "high"},
          %{"effort" => 3},
          %{"effort" => nil},
          [effort: "high"]
        ] do
      test "start refuses #{inspect(bad)}" do
        assert {:error, :invalid_config} =
                 Peer.start(
                   owner: self(),
                   writer: fn _ -> :ok end,
                   ref: make_ref(),
                   prompt: "hi",
                   mode: :run,
                   session_id: nil,
                   config: unquote(Macro.escape(bad))
                 )
      end
    end

    test "prompt/4 refuses a malformed map without writing" do
      {_agent, pid} = start([], [])
      assert_receive {:acp, _, {:done, "end_turn", nil}}
      flush_writes()

      assert {:error, :invalid_config} = Peer.prompt(pid, "x", [], config: %{"model" => "y"})
      refute_receive {:scripted_agent, :wrote, _}, 50
    end
  end

  defp reply(pid, id, result),
    do: line(pid, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp line(pid, map), do: Peer.stdout(pid, Jason.encode!(map) <> "\n")

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp flush_writes do
    receive do
      {:scripted_agent, :wrote, _} -> flush_writes()
    after
      0 -> :ok
    end
  end
end
