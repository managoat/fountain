defmodule Managoat.ACP.PeerTest do
  @moduledoc """
  Drives a real peer against a hand-scripted agent, one frame at a time.

  The transport is the writer function the peer takes (`Managoat.ACP.Transport`):
  here it forwards whatever the peer writes to the test process, so every
  assertion is about bytes that would actually have gone down the pipe, and
  the test feeds the agent's replies back through `Peer.stdout/2`. No
  process is stubbed and nothing is global, which is what lets the suite
  run async — and is the acceptance test for the transport seam: a peer test
  that needed a sandbox stub would mean the seam was not cut.

  `Managoat.ACP.Testing.ScriptedAgent` drives whole turns; these tests want
  the individual frames, so they script by hand.
  """

  use ExUnit.Case, async: true

  alias Managoat.ACP.Peer

  setup do
    test = self()

    writer = fn data ->
      send(test, {:wrote, IO.iodata_to_binary(data)})
      :ok
    end

    {:ok, ref: make_ref(), writer: writer}
  end

  defp start_peer(ctx, opts) do
    {:ok, pid} =
      Peer.start(
        [
          owner: self(),
          writer: ctx.writer,
          ref: ctx.ref,
          prompt: "do the thing",
          mode: :run,
          session_id: nil,
          cwd: "/work",
          images: [],
          mcp_servers: []
        ]
        |> Keyword.merge(opts)
      )

    pid
  end

  defp permission_line(id, tool) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "session/request_permission",
      "params" => %{
        "toolCall" => %{"title" => tool, "kind" => "execute"},
        "options" => [
          %{"optionId" => "yes", "kind" => "allow_always"},
          %{"optionId" => "no", "kind" => "reject_once"}
        ]
      }
    }) <> "\n"
  end

  # Receive the next thing the peer wrote, decoded.
  defp next_write do
    assert_receive {:wrote, line}, 1_000
    Jason.decode!(line)
  end

  defp send_response(pid, id, result) do
    Peer.stdout(pid, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n")
  end

  defp update_line(update, session_id \\ "sess_abc") do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => session_id, "update" => update}
    }) <> "\n"
  end

  defp caps(extra \\ %{}) do
    Map.merge(%{"loadSession" => true, "sessionCapabilities" => %{"resume" => %{}}}, extra)
  end

  describe "handshake" do
    test "the first thing on the wire is initialize", ctx do
      start_peer(ctx, [])

      assert %{"method" => "initialize", "id" => _} = next_write()
    end

    test "declares no filesystem or terminal capabilities", ctx do
      # 0016 makes servicing fs/* and terminal/* its own gate. Gate 2 asks for
      # nothing, so a well-behaved adapter never calls them.
      start_peer(ctx, [])

      assert %{"params" => params} = next_write()
      assert params["clientCapabilities"]["terminal"] == false
      assert params["clientCapabilities"]["fs"]["readTextFile"] == false
      assert params["clientCapabilities"]["fs"]["writeTextFile"] == false
    end

    test "reports the handshake cost, labelled with the call it is about to make", ctx do
      pid = start_peer(ctx, [])
      %{"id" => id} = next_write()

      send_response(pid, id, %{"agentCapabilities" => caps()})

      assert_receive {:acp, _ref, {:handshake_ms, ms, "session/new"}}
      assert is_integer(ms) and ms >= 0
    end
  end

  describe "turn 1 — session/new" do
    test "creates a session, reports the id, then prompts", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})

      assert %{"method" => "session/new", "id" => new_id, "params" => params} = next_write()
      assert params["cwd"] == "/work"

      send_response(pid, new_id, %{"sessionId" => "sess_abc"})

      assert_receive {:acp, _ref, {:session, "sess_abc"}}

      assert %{"method" => "session/prompt", "id" => prompt_id, "params" => prompt_params} =
               next_write()

      assert prompt_params["sessionId"] == "sess_abc"
      assert [%{"type" => "text", "text" => "do the thing"}] = prompt_params["prompt"]

      # The id is reported the moment the prompt is on the wire: it is what a
      # reattach after a restart resumes the turn by.
      assert_receive {:acp, _ref, {:prompt_sent, ^prompt_id}}
    end

    test "a session response with no id fails the turn rather than prompting blind", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()

      send_response(pid, new_id, %{})

      assert_receive {:acp, _ref, {:failed, {:acp_no_session_id, _}}}
    end
  end

  describe "turn N — resumption" do
    test "prefers session/resume when the agent advertises it", ctx do
      # This is the whole reason Claude is the gate 2 runtime: resume restores
      # context without replaying, so a turn costs a handshake and nothing else.
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})

      assert %{"method" => "session/resume", "params" => params} = next_write()
      assert params["sessionId"] == "sess_abc"
    end

    test "falls back to session/load when resume is not advertised", ctx do
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{"loadSession" => true}})

      assert %{"method" => "session/load"} = next_write()
    end

    test "the handshake measurement names the expensive path when it takes it", ctx do
      # A load pays for a full history replay and a resume does not. Reporting
      # both as "a resume" would average away the only number that would tell us
      # a pinned adapter had stopped advertising `sessionCapabilities.resume`.
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{"loadSession" => true}})

      assert_receive {:acp, _ref, {:handshake_ms, _ms, "session/load"}}
    end

    test "an agent that can do neither fails the turn instead of starting a second session",
         ctx do
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{}})

      assert_receive {:acp, _ref, {:failed, :acp_agent_cannot_resume}}
    end

    test "continue with no session id is a contradiction and fails loudly", ctx do
      pid = start_peer(ctx, mode: :continue, session_id: nil)
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})

      assert_receive {:acp, _ref, {:failed, :acp_resume_without_session_id}}
    end
  end

  describe "replay discard" do
    test "updates arriving during session/load are dropped, and later ones are not", ctx do
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{"loadSession" => true}})
      %{"id" => load_id} = next_write()

      # The replay: history we already hold as log_events.
      Peer.stdout(
        pid,
        update_line(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "OLD TURN"}
        })
      )

      refute_receive {:acp, _, {:lines, _, _}}, 100

      send_response(pid, load_id, %{})
      %{"method" => "session/prompt"} = next_write()

      Peer.stdout(
        pid,
        update_line(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "NEW"}
        })
      )

      assert_receive {:acp, _ref, {:lines, "acp", data}}
      assert data =~ "NEW"
      refute data =~ "OLD TURN"
    end

    test "a replay that lands after the load response is still discarded", ctx do
      # #657: gemini streams its replay as a floating promise, so `session/load`
      # answers *before* replaying. Measured against a live agent — closing the
      # window on the response duplicated the whole transcript.
      pid =
        start_peer(ctx,
          mode: :continue,
          session_id: "sess_abc",
          replay_quiet_ms: 40,
          replay_max_ms: 2_000
        )

      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{"loadSession" => true}})
      %{"id" => load_id} = next_write()

      send_response(pid, load_id, %{})

      # Late replay, in two bursts, each of which pushes the quiet period out.
      for text <- ["OLD ONE", "OLD TWO"] do
        Peer.stdout(
          pid,
          update_line(%{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => text}
          })
        )

        Process.sleep(20)
      end

      refute_receive {:acp, _, {:lines, _, _}}, 20

      # Only once the stream goes quiet does the turn's own prompt go out.
      assert %{"method" => "session/prompt"} = next_write()

      Peer.stdout(
        pid,
        update_line(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "NEW"}
        })
      )

      assert_receive {:acp, _ref, {:lines, "acp", data}}
      assert data =~ "NEW"
      refute data =~ "OLD"
    end

    test "a replay that never goes quiet still prompts, rather than holding the turn open", ctx do
      # An unbounded wait would be the #413 shape: a turn in flight disarms idle
      # reclaim, so a chatty agent could bill a sprite to its ceiling.
      pid =
        start_peer(ctx,
          mode: :continue,
          session_id: "sess_abc",
          replay_quiet_ms: 30,
          replay_max_ms: 60
        )

      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{"loadSession" => true}})
      %{"id" => load_id} = next_write()
      send_response(pid, load_id, %{})

      noisy = fn ->
        Peer.stdout(
          pid,
          update_line(%{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => "chatter"}
          })
        )
      end

      for _ <- 1..12 do
        noisy.()
        Process.sleep(10)
      end

      assert %{"method" => "session/prompt"} = next_write()
    end

    test "session/resume never enters replay-discard, so nothing is lost", ctx do
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => resume_id} = next_write()
      send_response(pid, resume_id, %{})
      %{"method" => "session/prompt"} = next_write()

      Peer.stdout(
        pid,
        update_line(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "kept"}
        })
      )

      assert_receive {:acp, _ref, {:lines, "acp", data}}
      assert data =~ "kept"
    end
  end

  describe "the turn's end" do
    test "a stop reason ends the turn", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})
      %{"id" => prompt_id} = next_write()

      send_response(pid, prompt_id, %{"stopReason" => "end_turn"})

      assert_receive {:acp, _ref, {:done, "end_turn", nil}}
    end

    test "the response's usage rides along, normalised (#827)", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})
      %{"id" => prompt_id} = next_write()

      send_response(pid, prompt_id, %{
        "stopReason" => "end_turn",
        "usage" => %{
          "inputTokens" => 1200,
          "outputTokens" => 340,
          "cachedReadTokens" => 900,
          "cachedWriteTokens" => 0,
          "totalTokens" => 2440
        }
      })

      assert_receive {:acp, _ref,
                      {:done, "end_turn",
                       %{
                         "input" => 1200,
                         "output" => 340,
                         "cache_read" => 900,
                         "cache_write" => 0
                       }}}
    end

    test "partial accounting survives the protocol without fabricated counters", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})
      %{"id" => prompt_id} = next_write()

      accounting = %{
        "version" => 1,
        "source" => "codex/thread-token-usage-delta",
        "scope" => "root_thread_prompt",
        "completeness" => "partial"
      }

      send_response(pid, prompt_id, %{
        "stopReason" => "cancelled",
        "usage" => nil,
        "_meta" => %{"usageAccounting" => accounting}
      })

      assert_receive {:acp, _ref, {:done, "cancelled", %{"accounting" => ^accounting}}}
    end

    test "an error response fails the turn", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => init_id,
          "error" => %{"code" => -32_000, "message" => "bad key"}
        }) <> "\n"
      )

      assert_receive {:acp, _ref, {:failed, {:acp_error, :initialize, %{"message" => "bad key"}}}}
    end

    test "an org-disallowed oauth error at the prompt is distinguished from a generic error (#655)",
         ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})
      %{"id" => prompt_id} = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => prompt_id,
          "error" => %{
            "code" => -32_603,
            "message" => "Internal error",
            "data" => %{
              "details" =>
                "oauth_org_not_allowed: Your organization has disabled Claude subscription access"
            }
          }
        }) <> "\n"
      )

      assert_receive {:acp, _ref, {:failed, {:oauth_org_not_allowed, detail}}}
      assert detail =~ "oauth_org_not_allowed"
    end

    test "a provider that refuses the model is distinguished from a generic error (#970)", ctx do
      pid = start_peer(ctx, model: "gemini-2.5-pro")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s", "models" => %{}})
      %{"id" => set_id} = next_write()
      send_response(pid, set_id, %{})
      %{"id" => prompt_id} = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => prompt_id,
          "error" => %{
            "code" => 500,
            "message" =>
              "This model models/gemini-2.5-pro is no longer available to new users. " <>
                "Please update your code to use models/gemini-3.1-pro-preview for the " <>
                "latest features and improvements."
          }
        }) <> "\n"
      )

      assert_receive {:acp, _ref, {:failed, {:model_unavailable, "gemini-2.5-pro", detail}}}
      assert detail =~ "no longer available to new users"
      assert detail =~ "gemini-3.1-pro-preview"
    end

    test "a not-found that is not about a model stays a generic error (#970)", ctx do
      pid = start_peer(ctx, model: "gemini-3.1-pro-preview")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s", "models" => %{}})
      %{"id" => set_id} = next_write()
      send_response(pid, set_id, %{})
      %{"id" => prompt_id} = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => prompt_id,
          "error" => %{"code" => -32_602, "message" => "session not found"}
        }) <> "\n"
      )

      assert_receive {:acp, _ref, {:failed, {:acp_error, :prompt, _error}}}
    end

    test "the same error kind at session setup is not special-cased — only the prompt call is",
         ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => init_id,
          "error" => %{"code" => -32_603, "message" => "oauth_org_not_allowed"}
        }) <> "\n"
      )

      assert_receive {:acp, _ref,
                      {:failed,
                       {:acp_error, :initialize, %{"message" => "oauth_org_not_allowed"}}}}
    end

    test "a write failure fails the turn rather than exiting the peer", ctx do
      # #603: a sandbox's write is a bare GenServer.call underneath, and the
      # command process stops :normal the moment the runtime's exit frame
      # arrives. The sandbox writer turns that into {:error, :command_exited};
      # the peer must report it, because a peer that dies silently leaves a
      # turn with no terminator at all. (The exit-to-error catch itself is
      # pinned in the sandbox adapter's own tests; here the writer is total
      # by contract and the peer's half is what is under test.)
      start_peer(ctx, writer: fn _iodata -> {:error, :command_exited} end)

      assert_receive {:acp, _ref, {:failed, {:acp_write_failed, :command_exited}}}
    end

    test "a write failure mid-prompt reports the same failure and writes nothing more", ctx do
      # The shape the owner relies on today: the runtime exits while a turn
      # is in flight, the next write fails, the owner sees exactly one
      # {:failed, {:acp_write_failed, reason}} and can close the turn.
      test = self()

      {:ok, agent} = Agent.start_link(fn -> :ok end)

      writer = fn data ->
        case Agent.get(agent, & &1) do
          :ok ->
            send(test, {:wrote, IO.iodata_to_binary(data)})
            :ok

          {:error, _} = error ->
            send(test, {:refused, IO.iodata_to_binary(data)})
            error
        end
      end

      pid = start_peer(ctx, writer: writer)
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})
      %{"method" => "session/prompt"} = next_write()

      # The runtime goes away; the next thing the peer has to write fails.
      Agent.update(agent, fn _ -> {:error, :command_exited} end)
      Peer.cancel(pid)

      assert_receive {:refused, line}
      assert line =~ "session/cancel"
      assert_receive {:acp, _ref, {:failed, {:acp_write_failed, :command_exited}}}

      # Failed is terminal: nothing else reaches the writer, and a second
      # failure is not reported twice.
      Peer.cancel(pid)
      refute_receive {:refused, _}, 50
      refute_receive {:acp, _ref, {:failed, _}}, 50
      assert {:error, {:not_idle, :failed}} = Peer.prompt(pid, "again")
    end

    test "start/1 refuses to start without a writer, naming the seam", ctx do
      assert_raise ArgumentError, ~r/writer: \(iodata -> :ok/, fn ->
        Peer.start(
          owner: self(),
          command: :the_old_option,
          ref: ctx.ref,
          prompt: "p",
          mode: :run,
          session_id: nil
        )
      end
    end
  end

  describe "the connection outlives the prompt (#817)" do
    # Drive one full turn to its stop reason and hand back the pid.
    defp answered_turn(ctx) do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      assert_receive {:acp, _ref, {:handshake_ms, _, "session/new"}}
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})
      %{"id" => prompt_id} = next_write()
      send_response(pid, prompt_id, %{"stopReason" => "end_turn"})
      assert_receive {:acp, _ref, {:done, "end_turn", nil}}
      pid
    end

    defp usage_update_line(meta) do
      update = Map.merge(%{"sessionUpdate" => "usage_update", "used" => 10}, meta)
      update_line(update, "s")
    end

    test "the peer stays up after the stop reason", ctx do
      pid = answered_turn(ctx)
      assert Process.alive?(pid)
    end

    test "a second prompt reuses the connection — no second handshake", ctx do
      pid = answered_turn(ctx)

      assert :ok = Peer.prompt(pid, "again")

      # The very next thing on the wire is the prompt itself: no initialize,
      # no session/resume, no model pin.
      assert %{"method" => "session/prompt", "id" => id, "params" => params} = next_write()
      assert params["sessionId"] == "s"
      assert [%{"type" => "text", "text" => "again"}] = params["prompt"]
      assert_receive {:acp, _ref, {:prompt_sent, ^id}}
      refute_received {:acp, _ref, {:handshake_ms, _, _}}

      send_response(pid, id, %{"stopReason" => "end_turn"})
      assert_receive {:acp, _ref, {:done, "end_turn", nil}}
      assert Process.alive?(pid)
    end

    test "a second prompt carries its own images", ctx do
      pid = answered_turn(ctx)

      assert :ok = Peer.prompt(pid, "look", [%{media_type: "image/png", data: "abc"}])

      assert %{"params" => %{"prompt" => [_text, image]}} = next_write()
      assert image["type"] == "image" and image["data"] == Base.encode64("abc")
    end

    test "a prompt while one is outstanding is refused, not sent", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})
      %{"method" => "session/prompt"} = next_write()

      assert {:error, {:not_idle, :prompting}} = Peer.prompt(pid, "too soon")
      refute_received {:wrote, _}
    end

    test "a prompt during the handshake is refused too", ctx do
      pid = start_peer(ctx, [])
      %{"method" => "initialize"} = next_write()

      assert {:error, {:not_idle, :initializing}} = Peer.prompt(pid, "too soon")
    end

    test "an out-of-turn update is still reported", ctx do
      pid = answered_turn(ctx)

      Peer.stdout(pid, update_line(%{"sessionUpdate" => "agent_message_chunk"}, "s"))

      assert_receive {:acp, _ref, {:lines, "acp", line}}
      assert line =~ "agent_message_chunk"
    end

    test "cycle_end fires on a usage_update from the autonomous set", ctx do
      pid = answered_turn(ctx)

      Peer.stdout(
        pid,
        usage_update_line(%{"_meta" => %{"_claude/origin" => %{"kind" => "task-notification"}}})
      )

      assert_receive {:acp, _ref, {:cycle_end, "task-notification"}}
    end

    test "cycle_end does not fire on a plain usage_update, nor on a user origin", ctx do
      pid = answered_turn(ctx)

      Peer.stdout(pid, usage_update_line(%{}))

      Peer.stdout(
        pid,
        usage_update_line(%{"_meta" => %{"_claude/origin" => %{"kind" => "user"}}})
      )

      assert_receive {:acp, _ref, {:lines, "acp", _}}
      assert_receive {:acp, _ref, {:lines, "acp", _}}
      refute_received {:acp, _ref, {:cycle_end, _}}
    end

    test "close stops the peer cleanly", ctx do
      pid = answered_turn(ctx)
      mon = Process.monitor(pid)

      Peer.close(pid)

      assert_receive {:DOWN, ^mon, :process, ^pid, :normal}
    end
  end

  describe "agent → client requests" do
    test "a permission request is auto-allowed, matching the legacy bypass flags", ctx do
      # Gate 2 keeps parity with `--dangerously-skip-permissions`: answering is
      # mandatory (a blocked agent is a turn in flight, which disarms idle
      # reclaim), and gate 3 is where the answer starts coming from a policy.
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})
      _prompt = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 99,
          "method" => "session/request_permission",
          "params" => %{
            "options" => [
              %{"optionId" => "no", "kind" => "reject_once"},
              %{"optionId" => "yes", "kind" => "allow_always"}
            ]
          }
        }) <> "\n"
      )

      assert %{"id" => 99, "result" => %{"outcome" => outcome}} = next_write()
      assert outcome["outcome"] == "selected"
      assert outcome["optionId"] == "yes"
    end

    test "a policy that denies a tool picks the agent's own rejection, and reports it", ctx do
      pid = start_peer(ctx, permission_policy: %{"Bash" => "auto_deny"})
      _init = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 101,
          "method" => "session/request_permission",
          "params" => %{
            "toolCall" => %{"title" => "Bash", "kind" => "execute"},
            "options" => [
              %{"optionId" => "yes", "kind" => "allow_always"},
              %{"optionId" => "no", "kind" => "reject_once"}
            ]
          }
        }) <> "\n"
      )

      assert %{"id" => 101, "result" => %{"outcome" => outcome}} = next_write()
      assert outcome["outcome"] == "selected"
      assert outcome["optionId"] == "no"

      # The refusal reaches the owner so it can be audited in the context.
      assert_receive {:acp, _ref, {:permission_denied, "Bash", "auto_deny"}}
    end

    test "a denied tool with no rejection offered is cancelled, never allowed", ctx do
      pid = start_peer(ctx, permission_policy: %{"default" => "auto_deny"})
      _init = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 102,
          "method" => "session/request_permission",
          "params" => %{
            "toolCall" => %{"title" => "Bash"},
            "options" => [%{"optionId" => "yes", "kind" => "allow_always"}]
          }
        }) <> "\n"
      )

      assert %{"id" => 102, "result" => %{"outcome" => %{"outcome" => "cancelled"}}} =
               next_write()
    end

    test "a tool the policy does not name is still allowed, and is not reported", ctx do
      pid = start_peer(ctx, permission_policy: %{"Bash" => "auto_deny"})
      _init = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 103,
          "method" => "session/request_permission",
          "params" => %{
            "toolCall" => %{"title" => "Read"},
            "options" => [%{"optionId" => "yes", "kind" => "allow_always"}]
          }
        }) <> "\n"
      )

      assert %{"id" => 103, "result" => %{"outcome" => %{"optionId" => "yes"}}} = next_write()

      # Allows are deliberately not recorded — a row each would make the audit
      # trail a second copy of the transcript.
      refute_receive {:acp, _ref, {:permission_denied, _, _}}, 50
    end

    test "ask holds the request open instead of answering it", ctx do
      pid = start_peer(ctx, permission_policy: %{"Bash" => "ask"})
      _init = next_write()

      Peer.stdout(pid, permission_line(201, "Bash"))

      # The agent stays blocked: nothing is written back until a human answers.
      # The request is persisted so it renders inline as a block, and the owner
      # is told so it can publish the stage event and arm a timeout.
      assert_receive {:acp, _ref, {:lines, "acp", line}}
      assert line =~ "session/request_permission"
      assert_receive {:acp, _ref, {:permission_ask, request_id, "Bash", options}}
      assert Enum.map(options, & &1["optionId"]) == ["yes", "no"]

      # The id a client answers with is minted here, not the adapter's own: it
      # keeps the adapter id in front, then eight random bytes.
      assert request_id =~ ~r/^201\.[0-9a-f]{16}$/

      # And the block a client renders carries the same minted id, because the
      # persisted line is the one we build.
      assert %{"id" => ^request_id} = Jason.decode!(line)

      refute_receive {:wrote, _}, 50
    end

    test "two requests the adapter numbers alike get different ids", ctx do
      # Measured against claude-agent-acp 0.66 in production (2026-08-22): it
      # numbers `session/request_permission` from 0 *per turn*, so a
      # conversation's second request arrives as id 0 again. Left as the public
      # id, that pairs turn 2's resolution to turn 3's card — the card renders
      # already-resolved — and lets a stale card answer a tool nobody saw.
      pid = start_peer(ctx, permission_policy: %{"Bash" => "ask"})
      _init = next_write()

      Peer.stdout(pid, permission_line(0, "Bash"))
      assert_receive {:acp, _ref, {:permission_ask, first, _, _}}
      assert :ok = Peer.answer_permission(pid, first, "yes")
      _answer = next_write()

      Peer.stdout(pid, permission_line(0, "Bash"))
      assert_receive {:acp, _ref, {:permission_ask, second, _, _}}

      refute first == second

      # The stale card misses, so it loses the race rather than answering the
      # request that is open now.
      assert {:error, :no_pending_permission} = Peer.answer_permission(pid, first, "yes")
      assert :ok = Peer.answer_permission(pid, second, "yes")
      assert %{"id" => 0, "result" => %{"outcome" => %{"optionId" => "yes"}}} = next_write()
    end

    test "an answer selects the option, and only an offered one", ctx do
      pid = start_peer(ctx, permission_policy: %{"Bash" => "ask"})
      _init = next_write()
      Peer.stdout(pid, permission_line(202, "Bash"))
      assert_receive {:acp, _ref, {:permission_ask, request_id, _, _}}

      assert {:error, :unknown_option} = Peer.answer_permission(pid, request_id, "made-up")
      assert :ok = Peer.answer_permission(pid, request_id, "yes")

      assert %{"id" => 202, "result" => %{"outcome" => outcome}} = next_write()
      assert outcome["outcome"] == "selected"
      assert outcome["optionId"] == "yes"
    end

    test "a second answer is too late, not a second write", ctx do
      # First answer wins: the web apps and an editor are peer clients of this
      # door, so losing the race is an ordinary outcome, not a caller error.
      pid = start_peer(ctx, permission_policy: %{"Bash" => "ask"})
      _init = next_write()
      Peer.stdout(pid, permission_line(203, "Bash"))
      assert_receive {:acp, _ref, {:permission_ask, request_id, _, _}}

      assert :ok = Peer.answer_permission(pid, request_id, "yes")
      _answer = next_write()

      assert {:error, :no_pending_permission} = Peer.answer_permission(pid, request_id, "no")
      refute_receive {:wrote, _}, 50
    end

    test "denying a held request picks the agent's own rejection", ctx do
      pid = start_peer(ctx, permission_policy: %{"Bash" => "ask"})
      _init = next_write()
      Peer.stdout(pid, permission_line(204, "Bash"))
      assert_receive {:acp, _ref, {:permission_ask, request_id, _, _}}

      Peer.deny_permission(pid, request_id)

      assert %{"id" => 204, "result" => %{"outcome" => outcome}} = next_write()
      assert outcome["optionId"] == "no"
    end

    test "a request handed back on reattach is still answerable", ctx do
      # The JSON-RPC id lives in the peer and dies with it, so a request raised
      # before a deploy is only answerable after one because the turn row wrote
      # it down. Same trap as `acp_prompt_id` (#772).
      pid =
        start_peer(ctx,
          permission_policy: %{"Bash" => "ask"},
          pending_permission: %{
            "request_id" => "205.f00dcafef00dcafe",
            "tool" => "Bash",
            "options" => [%{"optionId" => "yes", "kind" => "allow_once"}]
          }
        )

      _init = next_write()

      # Answered with the minted id the client is holding; the adapter is
      # answered with the id it is actually blocked on, read back out of it.
      assert :ok = Peer.answer_permission(pid, "205.f00dcafef00dcafe", "yes")
      assert %{"id" => 205, "result" => %{"outcome" => %{"optionId" => "yes"}}} = next_write()
    end

    test "a request written down before ids were minted is still answerable", ctx do
      # Rows written before #955 hold the bare adapter id. A deploy landing on
      # top of one must not orphan the request it describes.
      pid =
        start_peer(ctx,
          permission_policy: %{"Bash" => "ask"},
          pending_permission: %{
            "request_id" => "206",
            "tool" => "Bash",
            "options" => [%{"optionId" => "yes", "kind" => "allow_once"}]
          }
        )

      _init = next_write()

      assert :ok = Peer.answer_permission(pid, "206", "yes")
      assert %{"id" => 206, "result" => %{"outcome" => %{"optionId" => "yes"}}} = next_write()
    end

    test "an adapter that names its requests instead of numbering them is answerable", ctx do
      # `Protocol.response/2` echoes the id's JSON type, so a string id has to
      # come back a string. Before ids were minted this shape restored as nil
      # and the request was orphaned on reattach.
      pid =
        start_peer(ctx,
          permission_policy: %{"Bash" => "ask"},
          pending_permission: %{
            "request_id" => "req-7.f00dcafef00dcafe",
            "tool" => "Bash",
            "options" => [%{"optionId" => "yes", "kind" => "allow_once"}]
          }
        )

      _init = next_write()

      assert :ok = Peer.answer_permission(pid, "req-7.f00dcafef00dcafe", "yes")
      assert %{"id" => "req-7", "result" => %{"outcome" => %{"optionId" => "yes"}}} = next_write()
    end

    test "the replay of a held request is not raised a second time", ctx do
      # A reattached peer reads the sprite's buffer, which still holds the
      # `session/request_permission` line the agent is blocked on (#967).
      # Raising it again would publish a second card for one question, and
      # would leave the card someone is looking at unanswerable, because the
      # id a client answers with is minted per hold.
      pid =
        start_peer(ctx,
          permission_policy: %{"Bash" => "ask"},
          attach: 900,
          pending_permission: %{
            "request_id" => "210.abcdefabcdefabcd",
            "tool" => "Bash",
            "options" => [
              %{"optionId" => "yes", "kind" => "allow_always"},
              %{"optionId" => "no", "kind" => "reject_once"}
            ]
          }
        )

      Peer.stdout(pid, permission_line(210, "Bash"))

      refute_receive {:acp, _ref, {:permission_ask, _, _, _}}, 100
      refute_receive {:acp, _ref, {:lines, "acp", _}}, 50

      # And the id the client is holding still answers the agent.
      assert :ok = Peer.answer_permission(pid, "210.abcdefabcdefabcd", "yes")
      assert %{"id" => 210, "result" => %{"outcome" => %{"optionId" => "yes"}}} = next_write()
    end

    test "a different request while one is held is still raised", ctx do
      # The guard is about the id, not about holding: an adapter that asked
      # again under a new id is asking a new question.
      pid = start_peer(ctx, permission_policy: %{"Bash" => "ask"})
      _init = next_write()

      Peer.stdout(pid, permission_line(211, "Bash"))
      assert_receive {:acp, _ref, {:permission_ask, first, _, _}}

      Peer.stdout(pid, permission_line(212, "Bash"))
      assert_receive {:acp, _ref, {:permission_ask, second, _, _}}

      refute first == second
    end

    test "an fs/* request is refused, not ignored", ctx do
      # Silence would block the agent forever. We declared no fs capability, so
      # the honest answer is method-not-found.
      pid = start_peer(ctx, [])
      _init = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 5, "method" => "fs/read_text_file"}) <> "\n"
      )

      assert %{"id" => 5, "error" => %{"code" => -32_601}} = next_write()
    end
  end

  describe "noise" do
    test "a non-JSON line is persisted as ordinary output", ctx do
      pid = start_peer(ctx, [])
      _init = next_write()

      Peer.stdout(pid, "npm warn deprecated punycode@2.3.1\n")

      assert_receive {:acp, _ref, {:lines, "stdout", data}}
      assert data =~ "npm warn"
    end
  end

  describe "images" do
    test "ride along in session/prompt as base64 content blocks", ctx do
      # The legacy path writes the bytes into the sandbox and appends the paths
      # to the prompt, hoping the model reaches for its Read tool. ACP carries
      # them in the prompt itself.
      pid = start_peer(ctx, images: [%{media_type: "image/png", data: <<1, 2, 3>>}])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})

      assert %{"method" => "session/prompt", "params" => params} = next_write()

      assert [
               %{"type" => "text", "text" => "do the thing"},
               %{"type" => "image", "mimeType" => "image/png", "data" => data}
             ] = params["prompt"]

      assert Base.decode64!(data) == <<1, 2, 3>>
    end

    test "a prompt with no images is text only", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})

      assert %{"params" => %{"prompt" => [%{"type" => "text"}]}} = next_write()
    end
  end

  describe "mcp servers" do
    @servers [%{name: "files", command: "mcp-files", env: [%{name: "K", value: "v"}]}]

    test "are sent with session/new", ctx do
      pid = start_peer(ctx, mcp_servers: @servers)
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})

      assert %{"method" => "session/new", "params" => params} = next_write()
      assert [%{"name" => "files", "command" => "mcp-files"}] = params["mcpServers"]
    end

    test "are re-sent on resume, not assumed to have survived", ctx do
      # The adapter snapshots {cwd, mcpServers} per session and tears the
      # session down when they change, so omitting them on resume would read as
      # "the client removed every MCP server".
      pid = start_peer(ctx, mode: :continue, session_id: "s1", mcp_servers: @servers)
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})

      assert %{"method" => "session/resume", "params" => params} = next_write()
      assert [%{"name" => "files"}] = params["mcpServers"]
    end
  end

  test "the peer dies with its owner", ctx do
    owner = spawn(fn -> receive do: (:never -> :ok) end)

    {:ok, pid} =
      Peer.start(
        owner: owner,
        writer: ctx.writer,
        ref: ctx.ref,
        prompt: "p",
        mode: :run,
        session_id: nil,
        cwd: "/work",
        images: [],
        mcp_servers: []
      )

    # Prove the peer is up and past its handshake write before the owner
    # goes: a peer that had already died would make this exit loudly with
    # its reason, where a bare monitor would only ever report :noproc.
    _ = :sys.get_state(pid)
    assert_receive {:wrote, _initialize}

    monitor = Process.monitor(pid)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  describe "model selection" do
    # ACP carries no model in session/new, so without this the runtime's own
    # default silently wins over the model the tenant configured — and for a
    # multi-provider runtime that is the entire configuration.
    defp caps_with_model_option,
      do: %{"sessionId" => "s", "configOptions" => [%{"id" => "model"}]}

    test "pins the configured model when the agent advertises the option", ctx do
      pid = start_peer(ctx, model: "claude-sonnet-4-6")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())

      assert %{"method" => "session/set_config_option", "id" => set_id, "params" => params} =
               next_write()

      assert params["configId"] == "model"
      assert params["value"] == "claude-sonnet-4-6"
      assert params["sessionId"] == "s"

      send_response(pid, set_id, %{})
      assert %{"method" => "session/prompt"} = next_write()
    end

    test "fails before inference when the runtime has no model option", ctx do
      # Silently running someone else's model is the failure mode this whole
      # campaign keeps turning up. Not fatal, but not invisible either.
      pid = start_peer(ctx, model: "gemini-3.1-pro-preview")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})

      assert_receive {:acp, _ref,
                      {:failed, {:model_selection_failed, "gemini-3.1-pro-preview", detail}}}

      assert detail =~ "does not expose model selection"
      refute_receive {:wrote, _}, 50
    end

    test "a refused model fails before inference", ctx do
      pid = start_peer(ctx, model: "not-a-real-model")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())
      %{"id" => set_id} = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => set_id,
          "error" => %{"code" => -32_602, "message" => "Invalid value for config option model"}
        }) <> "\n"
      )

      # Reported as a structured event, not an stderr line: stderr is the one
      # stream `?streams=acp,stage` and `fountain acp` both drop, so the
      # warning was invisible to protocol clients (#724).
      assert_receive {:acp, _ref,
                      {:failed, {:model_selection_failed, "not-a-real-model", detail}}}

      assert detail =~ "Invalid value for config option model"

      refute_receive {:wrote, _}, 50
    end

    test "repins changed models on the same session and reports runtime metadata", ctx do
      pid = start_peer(ctx, model: "old")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())
      %{"id" => set_id} = next_write()

      send_response(pid, set_id, %{
        "configOptions" => [%{"id" => "model", "currentValue" => "old"}]
      })

      assert_receive {:acp, _, {:model_selected, "old", "old", "runtime"}}
      %{"id" => prompt_id} = next_write()
      send_response(pid, prompt_id, %{"stopReason" => "end_turn"})
      assert_receive {:acp, _, {:done, _, _}}

      assert :ok = Peer.prompt(pid, "next", [], model: "new")

      assert %{
               "method" => "session/set_config_option",
               "id" => set_id,
               "params" => %{"sessionId" => "s", "value" => "new"}
             } = next_write()

      refute_receive {:wrote, _}, 50

      send_response(pid, set_id, %{
        "configOptions" => [%{"id" => "model", "currentValue" => "new"}]
      })

      assert_receive {:acp, _, {:model_selected, "new", "new", "runtime"}}
      assert %{"method" => "session/prompt", "params" => %{"sessionId" => "s"}} = next_write()
    end

    test "rejecting a changed model on reuse leaves the next prompt unwritten", ctx do
      pid = start_peer(ctx, model: "old")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())
      %{"id" => set_id} = next_write()
      send_response(pid, set_id, %{})
      assert_receive {:acp, _, {:model_selected, "old", "old", "selection_ack"}}
      %{"id" => prompt_id} = next_write()
      send_response(pid, prompt_id, %{"stopReason" => "end_turn"})
      assert_receive {:acp, _, {:done, _, _}}
      assert :ok = Peer.prompt(pid, "must not run", [], model: "unavailable")
      %{"id" => set_id, "method" => "session/set_config_option"} = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => set_id,
          "error" => %{"code" => -32_602, "message" => "Invalid params"}
        }) <> "\n"
      )

      assert_receive {:acp, _,
                      {:failed, {:model_selection_failed, "unavailable", "Invalid params"}}}

      refute_receive {:wrote, _}, 50
    end

    test "a mismatched confirmation never sends the prompt", ctx do
      pid = start_peer(ctx, model: "wanted")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())
      %{"id" => set_id} = next_write()

      send_response(pid, set_id, %{
        "configOptions" => [%{"id" => "model", "currentValue" => "other"}]
      })

      assert_receive {:acp, _, {:failed, {:model_selection_failed, "wanted", _}}}
      refute_receive {:wrote, _}, 50
    end

    # Claude's adapter accepts the full id and confirms its own canonical
    # designation. Strict equality read that as a substitution and failed the
    # turn, which took down every claude agent on an instance; codex, which
    # echoes the id verbatim, was unaffected and hid it.
    # The bracketed cases are a variant qualifier, not a second model: claude
    # confirms `opus[1m]` for the 1M-context build of `claude-opus-5`. Dropping
    # separators fused it into `opus1m`, so the fix above for strict equality
    # still failed the turn on a model that answers perfectly well (#8).
    for {requested, confirmed} <- [
          {"claude-opus-5", "opus"},
          {"claude-sonnet-5", "sonnet"},
          {"claude-haiku-4-5", "haiku"},
          {"gpt-6-astra", "gpt-6-astra"},
          {"claude-opus-5", "opus[1m]"},
          {"claude-opus-5", "claude-opus-5[1m]"},
          {"claude-sonnet-5", "sonnet (1m)"}
        ] do
      test "#{requested} confirmed as #{confirmed} is the same model", ctx do
        pid = start_peer(ctx, model: unquote(requested))
        %{"id" => init_id} = next_write()
        send_response(pid, init_id, %{"agentCapabilities" => caps()})
        %{"id" => new_id} = next_write()
        send_response(pid, new_id, caps_with_model_option())
        %{"id" => set_id} = next_write()

        send_response(pid, set_id, %{
          "configOptions" => [%{"id" => "model", "currentValue" => unquote(confirmed)}]
        })

        assert_receive {:acp, _,
                        {:model_selected, unquote(requested), unquote(confirmed), "runtime"}}

        assert %{"method" => "session/prompt"} = next_write()
      end
    end

    # The case the comparison exists for: a different model, not a shorter
    # name for the same one.
    test "a different family is still a substitution and fails", ctx do
      pid = start_peer(ctx, model: "claude-opus-5")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())
      %{"id" => set_id} = next_write()

      send_response(pid, set_id, %{
        "configOptions" => [%{"id" => "model", "currentValue" => "claude-haiku-4-5"}]
      })

      assert_receive {:acp, _, {:failed, {:model_selection_failed, "claude-opus-5", detail}}}
      assert detail =~ "claude-haiku-4-5"
      refute_receive {:wrote, _}, 50
    end

    # Stripping the variant qualifier must not swallow the family with it: a
    # different model wearing one is still a substitution.
    test "a variant qualifier on a different family still fails", ctx do
      pid = start_peer(ctx, model: "claude-opus-5")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())
      %{"id" => set_id} = next_write()

      send_response(pid, set_id, %{
        "configOptions" => [%{"id" => "model", "currentValue" => "haiku[1m]"}]
      })

      assert_receive {:acp, _, {:failed, {:model_selection_failed, "claude-opus-5", detail}}}
      assert detail =~ "haiku[1m]"
      refute_receive {:wrote, _}, 50
    end

    # A confirmation that is nothing but a qualifier names no model at all.
    test "a bare qualifier is not a confirmation", ctx do
      pid = start_peer(ctx, model: "claude-opus-5")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())
      %{"id" => set_id} = next_write()

      send_response(pid, set_id, %{
        "configOptions" => [%{"id" => "model", "currentValue" => "[1m]"}]
      })

      assert_receive {:acp, _, {:failed, {:model_selection_failed, "claude-opus-5", _}}}
      refute_receive {:wrote, _}, 50
    end

    test "no configured model means no round trip at all", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())

      assert %{"method" => "session/prompt"} = next_write()
    end
  end

  describe "authentication on demand" do
    # gemini opens a session from ambient credentials but answers session/load
    # with -32000 "Authentication required", so every turn after the first
    # failed outright until the peer learned to authenticate. Measured live on
    # 2026-08-10; the method ids below are gemini's own.
    @gemini_auth [
      %{"id" => "oauth-personal", "name" => "Log in with Google"},
      %{"id" => "gemini-api-key", "name" => "Gemini API key", "_meta" => %{"api-key" => %{}}},
      %{"id" => "vertex-ai", "name" => "Vertex AI"}
    ]

    defp init_with_auth(pid, methods) do
      %{"id" => init_id} = next_write()

      send_response(pid, init_id, %{
        "agentCapabilities" => %{"loadSession" => true},
        "authMethods" => methods
      })

      init_id
    end

    defp refuse(pid, id, message) do
      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32_000, "message" => message}
        }) <> "\n"
      )
    end

    test "authenticates before opening a session, not after being refused", ctx do
      # Reactive was too late. Gemini opens a session from ambient credentials
      # without being told a method, but does not *persist* one — the next
      # turn's session/load then answers "No previous sessions found for this
      # project", so the retry authenticates correctly and finds nothing.
      # Measured live 2026-08-10.
      pid = start_peer(ctx, [])
      init_with_auth(pid, @gemini_auth)

      assert %{"method" => "authenticate", "id" => auth_id, "params" => params} = next_write()

      # The api-key method, not the OAuth one: a headless sandbox can never
      # complete an interactive Google login, and gemini lists oauth first.
      assert params["methodId"] == "gemini-api-key"

      send_response(pid, auth_id, %{})

      # Only then is the session opened.
      assert %{"method" => "session/new"} = next_write()
    end

    # codex-acp advertises `api-key` and `chat-gpt`. Its api-key method reads a
    # key from the env and runs `accountLogin({type: "apiKey"})`, which
    # rewrites `~/.codex/auth.json` — and a host that has written an
    # externally managed ChatGPT login there (chatgptAuthTokens) loses it.
    # Measured 2026-09-08.
    @codex_auth [
      %{
        "id" => "api-key",
        "name" => "API Key",
        "_meta" => %{"api-key" => %{"provider" => "openai"}}
      },
      %{"id" => "chat-gpt", "name" => "ChatGPT"}
    ]

    test "auth: :none opens the session on the agent's own credentials", ctx do
      pid = start_peer(ctx, auth: :none)
      init_with_auth(pid, @codex_auth)

      assert %{"method" => "session/new"} = next_write()
    end

    test "auth: :none does not authenticate on a refusal either", ctx do
      pid = start_peer(ctx, auth: :none)
      init_with_auth(pid, @codex_auth)

      assert %{"method" => "session/new", "id" => new_id} = next_write()
      refuse(pid, new_id, "Authentication required")

      # No authenticate: the failure is reported as the turn's, not retried
      # into a method that would overwrite what the host wrote.
      refute_receive {:wrote, _}, 100
    end

    test "a named method is used when advertised, and nothing when it is not", ctx do
      pid = start_peer(ctx, auth: "chat-gpt")
      init_with_auth(pid, @codex_auth)

      assert %{"method" => "authenticate", "id" => auth_id, "params" => params} = next_write()
      assert params["methodId"] == "chat-gpt"
      send_response(pid, auth_id, %{})
      assert %{"method" => "session/new"} = next_write()

      pid = start_peer(ctx, auth: "not-advertised")
      init_with_auth(pid, @codex_auth)
      assert %{"method" => "session/new"} = next_write()
    end

    test "an agent advertising no methods is never sent authenticate", ctx do
      # claude's adapter returns authMethods: [] (measured), so this must be a
      # complete no-op for it rather than a guessed method.
      pid = start_peer(ctx, [])
      init_with_auth(pid, [])

      assert %{"method" => "session/new"} = next_write()
    end

    test "never picks a method that is not an api key", ctx do
      # opencode advertises exactly ["opencode-login"], an interactive flow a
      # headless sandbox cannot complete. A first-in-the-list fallback picked
      # it and got away with it; an agent that *blocked* on that login would
      # leave the turn in flight forever, which disarms idle reclaim.
      pid = start_peer(ctx, [])
      init_with_auth(pid, [%{"id" => "opencode-login", "name" => "Log in to OpenCode"}])

      assert %{"method" => "session/new"} = next_write()
    end

    test "does not authenticate a second time", ctx do
      # An agent that refuses after we have already authenticated is refusing
      # for a reason authentication will not fix; looping would hold the turn
      # open indefinitely.
      pid = start_peer(ctx, mode: :continue, session_id: "gem-1")
      init_with_auth(pid, @gemini_auth)

      %{"id" => auth_id, "method" => "authenticate"} = next_write()
      send_response(pid, auth_id, %{})
      %{"id" => load_id} = next_write()
      refuse(pid, load_id, "Authentication required")

      assert_receive {:acp, _ref, {:failed, {:acp_error, :load_session, _}}}
    end

    test "the reactive backstop still covers an agent that advertised nothing", ctx do
      # Eager covers everything measured; this covers being wrong about that,
      # once, rather than failing the turn outright.
      pid = start_peer(ctx, mode: :continue, session_id: "gem-1")

      %{"id" => init_id} = next_write()

      send_response(pid, init_id, %{
        "agentCapabilities" => %{"loadSession" => true},
        "authMethods" => []
      })

      %{"id" => load_id, "method" => "session/load"} = next_write()
      refuse(pid, load_id, "Authentication required")

      # Nothing to pick, so it fails rather than inventing a method.
      assert_receive {:acp, _ref, {:failed, {:acp_error, :load_session, _}}}
    end

    test "a non-auth error is not retried as an auth problem", ctx do
      pid = start_peer(ctx, mode: :continue, session_id: "gem-1")
      init_with_auth(pid, @gemini_auth)

      %{"id" => auth_id, "method" => "authenticate"} = next_write()
      send_response(pid, auth_id, %{})
      %{"id" => load_id} = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => load_id,
          "error" => %{"code" => -32_602, "message" => "Session not found"}
        }) <> "\n"
      )

      assert_receive {:acp, _ref, {:failed, {:acp_error, :load_session, _}}}
    end
  end

  describe "model selection, second shape" do
    test "uses session/set_model when the agent advertises models", ctx do
      # gemini exposes `models` in the session response and implements ACP's
      # own session/set_model; claude's adapter exposes `configOptions` and
      # takes session/set_config_option. Neither is a superset of the other.
      pid = start_peer(ctx, model: "gemini-flash-latest")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()

      send_response(pid, new_id, %{
        "sessionId" => "s",
        "models" => %{"availableModels" => [], "currentModelId" => "x"}
      })

      assert %{"method" => "session/set_model", "id" => set_id, "params" => params} = next_write()
      assert params["modelId"] == "gemini-flash-latest"
      assert params["sessionId"] == "s"

      send_response(pid, set_id, %{})
      assert %{"method" => "session/prompt"} = next_write()
    end
  end

  describe "attach — resuming a turn already in flight" do
    # A deploy restarts the peer while the adapter, a detachable session in the
    # sprite, keeps running with `session/prompt` outstanding. The new peer is
    # handed the prompt's id and joins the stream: no handshake, replayed
    # history ignored, live requests answered, the prompt's answer ends it.

    defp attached_peer(ctx, prompt_id \\ 4) do
      start_peer(ctx, mode: :continue, session_id: "sess_abc", attach: prompt_id)
    end

    test "writes nothing on start — no initialize, no session call, no second prompt", ctx do
      pid = attached_peer(ctx)
      _ = :sys.get_state(pid)
      refute_receive {:wrote, _}, 100
    end

    test "the replayed handshake — responses and a model refusal — is ignored", ctx do
      pid = attached_peer(ctx, 4)

      # initialize, session/resume, then the set_config_option the previous
      # peer already reported as a `model failed` stage event.
      send_response(pid, 1, %{"agentCapabilities" => caps()})
      send_response(pid, 2, %{"configOptions" => [%{"id" => "model"}]})

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 3,
          "error" => %{"code" => -32_603, "data" => %{"details" => "Invalid value"}}
        }) <> "\n"
      )

      _ = :sys.get_state(pid)
      refute_received {:acp, _, {:failed, _}}
      refute_received {:acp, _, {:done, _, _}}
      refute_received {:acp, _, {:model_rejected, _, _}}
    end

    test "a live permission request is answered — the reason the turn used to hang", ctx do
      pid = attached_peer(ctx)

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "session/request_permission",
          "params" => %{"options" => [%{"optionId" => "allow", "kind" => "allow_once"}]}
        }) <> "\n"
      )

      assert %{"id" => 5, "result" => %{"outcome" => %{"optionId" => "allow"}}} = next_write()
    end

    test "updates are relayed for persistence", ctx do
      pid = attached_peer(ctx)
      Peer.stdout(pid, update_line(%{"sessionUpdate" => "agent_message_chunk"}))
      assert_receive {:acp, _ref, {:lines, "acp", line}}
      assert line =~ "agent_message_chunk"
    end

    test "the response to the prompt id ends the turn; an error to it fails the turn", ctx do
      pid = attached_peer(ctx, 4)
      send_response(pid, 4, %{"stopReason" => "end_turn"})
      assert_receive {:acp, _ref, {:done, "end_turn", nil}}

      pid2 = attached_peer(ctx, 7)

      Peer.stdout(
        pid2,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "error" => %{"message" => "gone"}}) <>
          "\n"
      )

      assert_receive {:acp, _ref, {:failed, {:acp_error, :prompt, %{"message" => "gone"}}}}
    end

    test "cancel still reaches the agent, addressed to the live session", ctx do
      pid = attached_peer(ctx)
      Peer.cancel(pid)

      assert %{"method" => "session/cancel", "params" => %{"sessionId" => "sess_abc"}} =
               next_write()
    end

    test "the replay's partial first line is dropped, not persisted as noise", ctx do
      # Sprites replays the tail of its buffer, which starts wherever it starts.
      pid = attached_peer(ctx)
      good = update_line(%{"sessionUpdate" => "usage_update", "used" => 1})
      Peer.stdout(pid, ~s(le":"garbage"}}}\n) <> good)

      assert_receive {:acp, _ref, {:lines, "acp", line}}
      assert line =~ "usage_update"
      refute_receive {:acp, _ref, {:lines, "stdout", _}}, 100
    end

    test "a first chunk that opens a JSON line is kept whole", ctx do
      pid = attached_peer(ctx)
      Peer.stdout(pid, update_line(%{"sessionUpdate" => "usage_update", "used" => 2}))
      assert_receive {:acp, _ref, {:lines, "acp", line}}
      assert line =~ ~s("used":2)
    end

    test "a first fragment with no newline yet is held until the line boundary arrives", ctx do
      pid = attached_peer(ctx)
      Peer.stdout(pid, "tail-of-a-line")
      Peer.stdout(pid, "-still-going\n" <> update_line(%{"sessionUpdate" => "usage_update"}))
      assert_receive {:acp, _ref, {:lines, "acp", _}}
      refute_receive {:acp, _ref, {:lines, "stdout", _}}, 100
    end
  end
end
