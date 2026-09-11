defmodule Fountain.Conversations.TurnMachineTest do
  @moduledoc """
  The turn state machine (#1374), driven without a server, a sandbox or a
  peer: every peer payload through `handle/3`, the effects it hands back,
  the row and stage writes it makes itself, and the bookkeeping around a
  turn's start and end.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.TurnMachine

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    conv = insert_conversation(user_id: user.id, agent: agent)
    row = insert_turn(conv, status: "running", started_at: DateTime.utc_now())

    machine = %TurnMachine{
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      row: row,
      metrics: TurnMachine.start_metrics("claude", :runner, System.monotonic_time(:millisecond))
    }

    {:ok, user: user, agent: agent, conv: conv, row: row, machine: machine}
  end

  defp idle(machine), do: %{machine | row: nil, metrics: nil}

  defp stages(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  defp attach_telemetry(events) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      events,
      fn event, measurements, metadata, _ ->
        send(test, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  @metadata_line ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"session_info_update","title":"t"}}})
  @update_line ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}})

  describe "from_state/1 and into_state/2" do
    test "round-trip the server's turn fields and nothing else", %{row: row} do
      state = %{
        conversation_id: "c",
        sandbox_id: "s",
        current_turn: row,
        current_turn_span: :span,
        turn_metrics: %{a: 1},
        stream_tracer: :tracer,
        replay_dedup: MapSet.new(["x"]),
        other: :untouched
      }

      machine = TurnMachine.from_state(state)

      assert %TurnMachine{
               sandbox_id: "s",
               row: ^row,
               span: :span,
               metrics: %{a: 1},
               tracer: :tracer
             } = machine

      assert MapSet.member?(machine.replay_dedup, "x")

      assert TurnMachine.into_state(state, %{machine | row: nil, span: nil}) ==
               %{state | current_turn: nil, current_turn_span: nil}
    end
  end

  describe "handle/3 with lines" do
    test "a replayed line is consumed from the dedup set and persisted nowhere", %{machine: m} do
      m = %{m | replay_dedup: MapSet.new([@update_line])}

      assert {%{replay_dedup: dedup}, []} = TurnMachine.handle(m, {:lines, "acp", @update_line})
      assert MapSet.size(dedup) == 0
    end

    test "session metadata lands on a running turn and is dropped without one", %{machine: m} do
      assert {^m, [{:persist_lines, "acp", @metadata_line}]} =
               TurnMachine.handle(m, {:lines, "acp", @metadata_line})

      idle = idle(m)
      assert {^idle, []} = TurnMachine.handle(idle, {:lines, "acp", @metadata_line})
    end

    test "an update with no turn opens an autonomous one before persisting", %{machine: m} do
      idle = idle(m)

      assert {^idle, [:open_autonomous_turn, {:persist_lines, "acp", @update_line}]} =
               TurnMachine.handle(idle, {:lines, "acp", @update_line})
    end

    test "an update on an autonomous turn re-arms the quiet timer", %{machine: m} do
      assert {^m, [:arm_autonomous_quiet, {:persist_lines, "acp", @update_line}]} =
               TurnMachine.handle(m, {:lines, "acp", @update_line}, %{autonomous?: true})

      assert {^m, [{:persist_lines, "acp", @update_line}]} =
               TurnMachine.handle(m, {:lines, "acp", @update_line}, %{autonomous?: false})
    end

    test "a stderr line is only persisted", %{machine: m} do
      assert {^m, [{:persist_lines, "stderr", "oops"}]} =
               TurnMachine.handle(m, {:lines, "stderr", "oops"})
    end
  end

  describe "handle/3 with the cycle and the session" do
    test "cycle_end closes an autonomous turn as completed and nothing else", %{machine: m} do
      assert {^m,
              [
                {:finish, "completed", %{"origin" => "task"},
                 %{origin: "autonomous", cycle: "task"}}
              ]} = TurnMachine.handle(m, {:cycle_end, "task"}, %{autonomous?: true})

      assert {^m, []} = TurnMachine.handle(m, {:cycle_end, "task"}, %{autonomous?: false})
    end

    test "the session id is the server's to persist", %{machine: m} do
      assert {^m, [{:session_id, "sess-1"}]} = TurnMachine.handle(m, {:session, "sess-1"})
    end

    test "the prompt's JSON-RPC id is written on the row at once", %{machine: m, row: row} do
      assert {%{row: %{acp_prompt_id: 7}}, []} = TurnMachine.handle(m, {:prompt_sent, 7})
      assert Fountain.Repo.get!(Conversations.Turn, row.id).acp_prompt_id == 7
    end

    test "the handshake cost is a telemetry event and a span stamp", %{machine: m, row: row} do
      attach_telemetry([[:fountain, :acp, :handshake]])

      assert {^m, []} = TurnMachine.handle(m, {:handshake_ms, 42, "session/new"})

      assert_receive {:telemetry, [:fountain, :acp, :handshake], %{duration_ms: 42},
                      %{turn_id: turn_id, method: "session/new"}}

      assert turn_id == row.id
    end
  end

  describe "handle/3 with a refused model" do
    test "model_rejected fails the turn and persists selection evidence", %{
      machine: m,
      conv: conv
    } do
      assert {updated, [{:finish, "failed", _, _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(m, {:model_rejected, "gpt-9", "no such model"})

      assert updated.row.model_selection[:requested_model] == "gpt-9"

      assert [{"failed", %{"requested_model" => "gpt-9", "effective_model" => nil}}] =
               stages(conv.id, "model")

      assert Fountain.Repo.get!(Conversations.Turn, m.row.id).model_selection["status"] ==
               "failed"
    end

    test "selected model evidence comes from the peer", %{machine: m, conv: conv} do
      assert {updated, []} = TurnMachine.handle(m, {:model_selected, "astra", "astra", "runtime"})
      assert updated.row.model_selection[:effective_model] == "astra"

      assert [{"done", %{"effective_model" => "astra", "source" => "runtime"}}] =
               stages(conv.id, "model")
    end

    test "model_unavailable fails the turn with the provider's sentence and drops the peer",
         %{machine: m, conv: conv} do
      assert {^m,
              [
                {:finish, "failed", %{"error" => message, "acp.model_unavailable" => true},
                 %{reason: message}},
                {:drop_connection, "failed"}
              ]} = TurnMachine.handle(m, {:failed, {:model_unavailable, "gpt-9", "Not found."}})

      assert message =~ "(gpt-9): Not found."
      assert message =~ "Change the agent's model"

      assert [{"failed", %{"requested" => "gpt-9", "using" => "none, the turn failed"}}] =
               stages(conv.id, "model")
    end
  end

  describe "handle/3 with permissions" do
    test "an ask is the server's, on an autonomous turn if none is open", %{machine: m} do
      assert {^m, [{:ask_permission, 3, "bash", ["allow"]}]} =
               TurnMachine.handle(m, {:permission_ask, 3, "bash", ["allow"]})

      idle = idle(m)

      assert {^idle, [:open_autonomous_turn, {:ask_permission, 3, "bash", ["allow"]}]} =
               TurnMachine.handle(idle, {:permission_ask, 3, "bash", ["allow"]})
    end

    test "a denial is audited with the tool and the verdict, never the input", %{
      machine: m,
      conv: conv
    } do
      assert {^m, []} = TurnMachine.handle(m, {:permission_denied, "rm", "auto_deny"})

      assert [%{metadata: %{"tool" => "rm", "verdict" => "auto_deny"}}] =
               Fountain.Repo.all(
                 from(a in Fountain.Audit.Event,
                   where:
                     a.resource_id == ^conv.id and a.action == "conversation.permission_denied"
                 )
               )
    end
  end

  describe "handle/3 with the turn's end" do
    test "done records usage and finishes; a refusal or cancel is a failed turn", %{
      machine: m,
      row: row
    } do
      assert {^m,
              [{:finish, "completed", %{"stop_reason" => "end_turn"}, %{stop_reason: "end_turn"}}]} =
               TurnMachine.handle(m, {:done, "end_turn", %{"input" => 3, "output" => 5}})

      assert Fountain.Repo.get!(Conversations.Turn, row.id).usage == %{
               "input" => 3,
               "output" => 5
             }

      assert {^m, [{:finish, "failed", _, %{stop_reason: "refusal"}}]} =
               TurnMachine.handle(m, {:done, "refusal", nil})

      assert {^m, [{:finish, "failed", _, %{stop_reason: "cancelled"}}]} =
               TurnMachine.handle(m, {:done, "cancelled", nil})
    end

    test "adapter accounting survives termination and storage without invented counts", %{
      machine: machine,
      row: row,
      conv: conv
    } do
      accounting = %{
        "version" => 1,
        "source" => "codex/thread-token-usage-delta",
        "scope" => "root_thread_prompt",
        "completeness" => "partial"
      }

      usage =
        Managoat.ACP.Usage.from_prompt_result(%{
          "stopReason" => "cancelled",
          "usage" => nil,
          "_meta" => %{"usageAccounting" => accounting}
        })

      assert {^machine, [{:finish, "failed", _, _}]} =
               TurnMachine.handle(machine, {:done, "cancelled", usage})

      stored = Fountain.Repo.get!(Conversations.Turn, row.id) |> Fountain.Repo.preload(:images)
      assert stored.usage == %{"accounting" => accounting}

      assert %{data: [%{usage: %{accounting: ^accounting}}]} =
               FountainWeb.ConversationJSON.turns(%{turns: [stored]})

      assert %{usage_input_tokens: 0, usage_output_tokens: 0} =
               Conversations._unsafe_get_conversation!(conv.id)

      assert {:error, :already_recorded} = Conversations._unsafe_record_turn_usage(stored, usage)
    end

    test "a failed peer ends the turn it drove and drops the connection", %{machine: m} do
      assert {^m,
              [
                {:finish, "failed", %{"error" => ":boom"}, %{reason: "acp: :boom"}},
                {:drop_connection, "failed"}
              ]} = TurnMachine.handle(m, {:failed, :boom})

      idle = idle(m)
      assert {^idle, [{:drop_connection, "failed"}]} = TurnMachine.handle(idle, {:failed, :boom})
    end

    test "an org-refused OAuth token on Claude says whether a key was swapped in", %{machine: m} do
      ctx = %{runtime_module: Managoat.Runtimes.Claude, oauth_switched?: true}

      assert {^m,
              [
                {:finish, "failed", %{"error" => switched, "acp.oauth_org_not_allowed" => true},
                 %{reason: switched}},
                {:drop_connection, "failed"}
              ]} = TurnMachine.handle(m, {:failed, {:oauth_org_not_allowed, "policy"}}, ctx)

      assert switched =~ "Switched to the Anthropic API key"

      {_, [{:finish, "failed", %{"error" => no_key}, _} | _]} =
        TurnMachine.handle(m, {:failed, {:oauth_org_not_allowed, "policy"}}, %{
          ctx
          | oauth_switched?: false
        })

      assert no_key =~ "no Anthropic API key is on file"
    end

    # The failure that reads as a quiet conversation. A first turn whose ACP
    # `initialize` fails leaves `runtime_session_id` set — `session_plan/2`
    # persisted it before the turn ran — and no rollout under it, so every
    # later prompt resumes a session that was never opened and fails the same
    # way, with the conversation back to `idle` in between.
    test "a resume against a session that is not there clears the id first", %{machine: m} do
      error = %{
        "code" => -32_603,
        "message" => "Internal error",
        "data" => %{"details" => "no rollout found for thread id be412434-0b99"}
      }

      assert {^m,
              [
                {:forget_runtime_session, "session_gone",
                 "no rollout found for thread id be412434-0b99"},
                {:finish, "failed", %{"error" => message, "acp.session_gone" => true},
                 %{reason: message}},
                {:drop_connection, "failed"}
              ]} = TurnMachine.handle(m, {:failed, {:acp_error, :resume_session, error}})

      assert message =~ "no rollout found for thread id be412434-0b99"
      assert message =~ "Send your prompt again"
      assert message =~ "will not remember"
    end

    test "the -32002 a replaced disk answers with is the same failure", %{machine: m} do
      assert {^m, [{:forget_runtime_session, "session_gone", _} | _]} =
               TurnMachine.handle(
                 m,
                 {:failed,
                  {:acp_error, :load_session,
                   %{"code" => -32_002, "message" => "Resource not found"}}}
               )
    end

    test "a resume that failed for any other reason keeps the session", %{machine: m} do
      assert {^m, [{:finish, "failed", %{"error" => error}, _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(
                 m,
                 {:failed,
                  {:acp_error, :resume_session, %{"code" => -32_603, "message" => "peer died"}}}
               )

      # The catch-all's inspected tuple, and no clearing: a session that may
      # still be good is not thrown away over a transient failure.
      assert error =~ "acp_error"
    end

    test "a failure on any other call is never read as a missing session", %{machine: m} do
      assert {^m, [{:finish, "failed", _, _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(
                 m,
                 {:failed, {:acp_error, :prompt, %{"message" => "resource not found"}}}
               )
    end

    test "the same failure with no turn open still clears the session", %{machine: m} do
      idle = idle(m)

      assert {^idle, [{:forget_runtime_session, "session_gone", _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(
                 idle,
                 {:failed, {:acp_error, :resume_session, %{"code" => -32_002}}}
               )
    end

    test "the same refusal on another runtime is an ordinary peer failure", %{machine: m} do
      assert {^m, [{:finish, "failed", %{"error" => error}, _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(
                 m,
                 {:failed, {:oauth_org_not_allowed, "policy"}},
                 %{runtime_module: Managoat.Runtimes.Gemini}
               )

      assert error =~ "oauth_org_not_allowed"
    end
  end

  describe "finish/4" do
    test "closes the row, publishes the stage, emits the metric, idles the conversation and clears",
         %{machine: m, conv: conv, row: row} do
      attach_telemetry([[:fountain, :turn, :completed]])
      {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

      assert %TurnMachine{row: nil, span: nil, metrics: nil, tracer: nil} =
               TurnMachine.finish(m, "completed", %{"stop_reason" => "end_turn"}, %{
                 stop_reason: "end_turn"
               })

      assert %{status: "completed", ended_at: %DateTime{}} =
               Fountain.Repo.get!(Conversations.Turn, row.id)

      assert [{"done", %{"turn_id" => turn_id, "stop_reason" => "end_turn"}}] =
               stages(conv.id, "turn")

      assert turn_id == row.id
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      assert_receive {:telemetry, [:fountain, :turn, :completed], %{duration_ms: _},
                      %{
                        runtime: "claude",
                        provider: "runner",
                        status: "completed",
                        conv_id: conv_id
                      }}

      assert conv_id == conv.id
    end

    for stale <- [:reassigned, :terminated, :failed, :completed, :interrupted, :deleted] do
      @tag stale: stale
      test "a #{stale} completion preserves the persisted result without duplicate events", ctx do
        attach_telemetry([[:fountain, :turn, :completed]])
        insert_log_event(ctx.conv, turn_id: ctx.row.id, stream: "acp", data: @update_line)

        case ctx.stale do
          :reassigned ->
            replacement = insert_sandbox(user_id: ctx.user.id)

            Conversations.update_conversation(ctx.conv, %{
              sandbox_id: replacement.id,
              status: "running"
            })

          terminal when terminal in [:terminated, :failed] ->
            Conversations.update_conversation(ctx.conv, %{status: Atom.to_string(terminal)})

          ended when ended in [:completed, :interrupted] ->
            ctx.row
            |> Ecto.Changeset.change(status: Atom.to_string(ended))
            |> Fountain.Repo.update!()

            Conversations.update_conversation(ctx.conv, %{status: "running"})
            insert_turn(ctx.conv, status: "running")

          :deleted ->
            Fountain.Repo.delete!(ctx.conv)
        end

        persisted_turn = Fountain.Repo.get(Conversations.Turn, ctx.row.id)
        persisted_conv = Fountain.Repo.get(Conversations.Conversation, ctx.conv.id)

        assert %TurnMachine{row: nil, span: nil, metrics: nil, tracer: nil} =
                 TurnMachine.finish(ctx.machine, "completed", %{}, %{})

        assert Fountain.Repo.get(Conversations.Turn, ctx.row.id) == persisted_turn
        assert Fountain.Repo.get(Conversations.Conversation, ctx.conv.id) == persisted_conv
        assert stages(ctx.conv.id, "turn") == []
        refute Fountain.Repo.reload!(ctx.user).onboarding_completed_at
        refute_receive {:telemetry, [:fountain, :turn, :completed], _, _}, 50
      end
    end

    test "completion materializes a reply and activates the account", ctx do
      insert_log_event(ctx.conv, turn_id: ctx.row.id, stream: "acp", data: @update_line)
      TurnMachine.finish(ctx.machine, "completed", %{}, %{})
      assert Fountain.Repo.reload!(ctx.row).reply_text == "hi"
      assert Fountain.Repo.reload!(ctx.user).onboarding_completed_at
    end

    test "a failed status is the failed stage, and no metric without metrics", %{
      machine: m,
      conv: conv
    } do
      attach_telemetry([[:fountain, :turn, :completed]])

      TurnMachine.finish(%{m | metrics: nil}, "failed", %{"error" => "x"}, %{reason: "x"})

      assert [{"failed", %{"reason" => "x"}}] = stages(conv.id, "turn")
      refute_receive {:telemetry, [:fountain, :turn, :completed], _, _}, 50
    end
  end

  describe "the interrupt pair" do
    test "marks the row, publishes, then closes the span and idles", %{
      machine: m,
      conv: conv,
      row: row
    } do
      attach_telemetry([[:fountain, :turn, :completed]])

      {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})
      marked = TurnMachine.mark_interrupted(m)
      assert marked.interrupted?
      assert Fountain.Repo.reload!(conv).status == "running"
      assert marked.row == row
      assert Fountain.Repo.get!(Conversations.Turn, row.id).status == "interrupted"
      assert [{"interrupted", %{"turn_id" => _}}] = stages(conv.id, "turn")

      assert %TurnMachine{row: nil, metrics: nil} = TurnMachine.close_interrupted(marked)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
      assert_receive {:telemetry, [:fountain, :turn, :completed], _, %{status: "interrupted"}}
    end

    for stale <- [:reassigned, :terminated, :completed, :interrupted] do
      @tag stale: stale
      test "a #{stale} turn is not interrupted by the stale actor", ctx do
        attach_telemetry([[:fountain, :turn, :completed]])

        case ctx.stale do
          :reassigned ->
            replacement = insert_sandbox(user_id: ctx.user.id)

            Conversations.update_conversation(ctx.conv, %{
              sandbox_id: replacement.id,
              status: "running"
            })

          :terminated ->
            Conversations.update_conversation(ctx.conv, %{status: "terminated"})

          status ->
            ctx.row
            |> Ecto.Changeset.change(status: Atom.to_string(status))
            |> Fountain.Repo.update!()
        end

        persisted_turn = Fountain.Repo.reload!(ctx.row)
        persisted_conv = Fountain.Repo.get!(Conversations.Conversation, ctx.conv.id)
        marked = TurnMachine.mark_interrupted(ctx.machine)
        refute marked.interrupted?

        assert %TurnMachine{row: nil, metrics: nil, interrupted?: false} =
                 TurnMachine.close_interrupted(marked)

        assert Fountain.Repo.reload!(ctx.row) == persisted_turn
        assert Fountain.Repo.get!(Conversations.Conversation, ctx.conv.id) == persisted_conv
        assert stages(ctx.conv.id, "turn") == []
        refute_receive {:telemetry, [:fountain, :turn, :completed], _, _}, 50
      end
    end

    for change <- [:reassigned, :terminated, :new_turn, :deleted] do
      @tag between: change
      test "#{change} between interrupt halves keeps the newer conversation state", ctx do
        attach_telemetry([[:fountain, :turn, :completed]])
        Conversations.update_conversation(ctx.conv, %{status: "running"})
        marked = TurnMachine.mark_interrupted(ctx.machine)
        assert marked.interrupted?

        case ctx.between do
          :reassigned ->
            replacement = insert_sandbox(user_id: ctx.user.id)
            Conversations.update_conversation(ctx.conv, %{sandbox_id: replacement.id})

          :terminated ->
            Conversations.update_conversation(ctx.conv, %{status: "terminated"})

          :new_turn ->
            insert_turn(ctx.conv, status: "running")

          :deleted ->
            Fountain.Repo.delete!(ctx.conv)
        end

        persisted_conv = Fountain.Repo.get(Conversations.Conversation, ctx.conv.id)
        prior_stages = stages(ctx.conv.id, "turn")

        assert %TurnMachine{row: nil, metrics: nil, interrupted?: false} =
                 TurnMachine.close_interrupted(marked)

        assert Fountain.Repo.get(Conversations.Conversation, ctx.conv.id) == persisted_conv
        assert stages(ctx.conv.id, "turn") == prior_stages
        assert_receive {:telemetry, [:fountain, :turn, :completed], _, %{status: "interrupted"}}
        refute_receive {:telemetry, [:fountain, :turn, :completed], _, _}, 50
      end
    end
  end

  describe "the metrics" do
    test "first output is reported once, and never without metrics", %{machine: m} do
      attach_telemetry([[:fountain, :turn, :first_output]])

      once = TurnMachine.maybe_emit_first_output(m)
      assert once.metrics.first_output?

      assert_receive {:telemetry, [:fountain, :turn, :first_output], %{elapsed_ms: _},
                      %{runtime: "claude", provider: "runner"}}

      assert TurnMachine.maybe_emit_first_output(once) == once
      refute_receive {:telemetry, [:fountain, :turn, :first_output], _, _}, 50

      assert TurnMachine.maybe_emit_first_output(idle(m)) == idle(m)
    end

    test "record_usage/2 records nothing for nil, and warns on a second recording", %{
      machine: m,
      row: row
    } do
      assert :ok = TurnMachine.record_usage(m, nil)
      assert :ok = TurnMachine.record_usage(%{m | row: nil}, %{"input" => 1})
      assert :ok = TurnMachine.record_usage(m, %{"input" => 1})
      assert Fountain.Repo.get!(Conversations.Turn, row.id).usage == %{"input" => 1}
    end
  end

  describe "starting a turn" do
    test "open/3 creates the running row, numbered after the last", %{conv: conv} do
      assert {:ok, %{id: conv_id}, %{turn_number: 2, status: "running", prompt: "hi"}} =
               TurnMachine.open(conv.id, conv.sandbox_id, "hi")

      assert conv_id == conv.id
    end

    test "open/3 refuses, with a stage, when another conversation holds the sandbox",
         %{user: user} do
      # gemini takes one turn at a time: with one conversation mid-turn on the
      # machine, a second conversation on it is refused, not queued.
      {busy, other} = two_gemini_conversations(user)

      assert :at_capacity = TurnMachine.open(other.id, busy.sandbox_id, "hi")

      assert [{"done", %{"event" => "at_capacity", "runtime" => "gemini"}}] =
               stages(other.id, "sandbox")
    end

    test "capacity_gate/2 is the same question, unlocked", %{user: user} do
      {busy, other} = two_gemini_conversations(user)
      assert {:error, :sandbox_at_capacity} = TurnMachine.capacity_gate(busy.sandbox_id, other)
      assert :ok = TurnMachine.capacity_gate(busy.sandbox_id, busy)
    end

    test "gate/1 admits a verified account", %{user: user} do
      assert :ok = TurnMachine.gate(user.id)
    end

    test "session_plan/2 runs fresh with a persisted placeholder, and continues an existing id",
         %{conv: conv} do
      assert {:run, id} = TurnMachine.session_plan(conv, nil)
      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id == id
      assert {:continue, "keep"} = TurnMachine.session_plan(conv, "keep")
    end

    test "command/7 is the ACP adapter with the sandbox's cwd, or the runtime's own argv",
         %{conv: conv, agent: agent} do
      handle = %Managoat.Sandbox.Handle{provider: :sprites, name: "s"}

      assert {cmd, _args, stdin?: true, dir: dir} =
               TurnMachine.command(true, conv, agent, "hi", :run, "sid", handle: handle)

      assert is_binary(cmd)
      assert dir == Managoat.Sandbox.host_path(handle, Managoat.Runtimes.ACP.cwd("claude"))

      assert {"echo", ["hi"], _} =
               TurnMachine.command(false, conv, agent, "hi", :run, "sid",
                 handle: handle,
                 runtime_module: Managoat.Runtimes.Testing.FakeRuntime
               )
    end

    test "store_images/2 keeps a rejected image from taking the turn down", %{row: row} do
      assert :ok =
               TurnMachine.store_images(row, [
                 %{media_type: "image/png", data: <<137, 80, 78, 71>>}
               ])

      assert :ok = TurnMachine.store_images(row, [%{media_type: "text/plain", data: "nope"}])
    end

    test "generate_title/4 is a no-op after the first turn and on the team channel",
         %{conv: conv, row: row} do
      assert :ok = TurnMachine.generate_title(conv, %{row | turn_number: 2}, "hi", %{})
      team = %{conv | channel_id: Fountain.Team.channel()}
      assert :ok = TurnMachine.generate_title(team, %{row | turn_number: 1}, "hi", %{})
    end

    test "effective_permission_policy/2 and agent_for/1", %{conv: conv, agent: agent} do
      assert TurnMachine.agent_for(conv).id == agent.id
      assert TurnMachine.agent_for(%{conv | agent_id: nil}) == nil

      assert TurnMachine.effective_permission_policy(conv, agent) ==
               Managoat.ACP.Permissions.effective(agent.permission_policy, conv.permission_policy)
    end
  end

  describe "a turn that never started" do
    test "fail_before_start/5 fails the row with the detail, and idles a running conversation",
         %{conv: conv, row: row} do
      {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})
      detail = TurnMachine.failure_detail(:command_exited, 1)
      assert detail == ":command_exited (runtime exited 1)"

      assert :ok = TurnMachine.fail_before_start(row, conv.id, "prompt write failed", detail, 1)

      assert %{status: "failed", exit_code: 1} = Fountain.Repo.get!(Conversations.Turn, row.id)
      assert [{"failed", %{"reason" => ^detail, "exit_code" => 1}}] = stages(conv.id, "turn")
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
    end

    test "failure_detail/2 without an exit code is the inspected reason alone" do
      assert TurnMachine.failure_detail(:enoent, nil) == ":enoent"
    end

    test "drain_exited_command/1 collects what the runtime said before it exited" do
      ref = make_ref()
      send(self(), {:stdout, %{ref: ref}, "hello"})
      send(self(), {:stderr, %{ref: ref}, "bad key"})
      send(self(), {:exit, %{ref: ref}, 1})
      send(self(), {:stdout, %{ref: make_ref()}, "another command"})

      assert {1, [{"stdout", "hello"}, {"stderr", "bad key"}]} =
               TurnMachine.drain_exited_command(ref)

      assert_receive {:stdout, _, "another command"}
    end

    test "drain_exited_command/1 gives up after the deadline with what it has" do
      ref = make_ref()
      send(self(), {:stdout, %{ref: ref}, "partial"})
      assert {nil, [{"stdout", "partial"}]} = TurnMachine.drain_exited_command(ref)
    end

    test "drain_exited_command/1 ends on the error frame with no exit code" do
      # A transport that closed with no exit frame (managoat_sandbox 0.2.0
      # reports `:closed_before_exit` where it used to fabricate an exit 0).
      # The frame is as stranded as the output around it, so the drain takes
      # it rather than paying the deadline and dropping it.
      ref = make_ref()
      send(self(), {:stdout, %{ref: ref}, "partial"})
      send(self(), {:error, %{ref: ref}, :closed_before_exit})

      assert {nil, [{"stdout", "partial"}]} = TurnMachine.drain_exited_command(ref)
      refute_received {:error, %{ref: ^ref}, _}
    end
  end

  describe "the session reset and the messages" do
    test "reset_runtime_session/2 clears the row and says why", %{conv: conv} do
      {:ok, conv} = Conversations.update_conversation(conv, %{runtime_session_id: "old"})
      assert :ok = TurnMachine.reset_runtime_session(conv, conv.id)
      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id == nil

      assert [{"done", %{"event" => "reset", "reason" => "fresh_sandbox"}}] =
               stages(conv.id, "session")
    end

    test "reset_runtime_session/4 records the reason the caller knows", %{conv: conv} do
      {:ok, conv} = Conversations.update_conversation(conv, %{runtime_session_id: "old"})
      assert :ok = TurnMachine.reset_runtime_session(conv, conv.id, "session_gone", "no rollout")
      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id == nil

      assert [{"done", %{"reason" => "session_gone", "detail" => "no rollout"}}] =
               stages(conv.id, "session")
    end

    test "forget_runtime_session/2 clears the server's copy along with the row", %{conv: conv} do
      {:ok, conv} = Conversations.update_conversation(conv, %{runtime_session_id: "old"})
      state = %{conversation_id: conv.id, runtime_session_id: "old"}

      assert %{runtime_session_id: nil} = TurnMachine.forget_runtime_session(state, conv)
      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id == nil
      assert [{"done", %{"reason" => "fresh_sandbox"}}] = stages(conv.id, "session")
    end

    test "forget_runtime_session/2 on a conversation with no session is not an event",
         %{conv: conv} do
      state = %{conversation_id: conv.id, runtime_session_id: nil}

      assert ^state = TurnMachine.forget_runtime_session(state, conv)
      assert stages(conv.id, "session") == []
    end

    test "model_unavailable_message/2 names the model when there is one" do
      assert TurnMachine.model_unavailable_message("m", " gone ") =~ "model (m): gone Change"
      refute TurnMachine.model_unavailable_message(nil, "gone") =~ "("
    end
  end

  # Two gemini conversations on one sandbox, the first mid-turn, so the
  # one-turn-at-a-time rule bites for the second.
  defp two_gemini_conversations(user) do
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    busy = insert_conversation(user_id: user.id, agent: agent)
    insert_turn(busy, status: "running", started_at: DateTime.utc_now())
    sandbox = Conversations._unsafe_get_sandbox!(busy.sandbox_id)
    other = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox)
    {busy, other}
  end
end
