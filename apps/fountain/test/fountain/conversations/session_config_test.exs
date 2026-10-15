defmodule Fountain.Conversations.SessionConfigTest do
  # ADR 0062: ACP session config options (reasoning effort, fast mode) on the
  # agent, copied onto the conversation at launch, recorded on the turn, and
  # the peer's reports about them. A conversation and a prompt carry none of
  # their own (addendum of 2026-10-15, agent only).
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Crypto, InferenceCredentials}
  alias Fountain.Agents.SessionConfig

  alias Fountain.Conversations
  alias Fountain.Conversations.{Launch, PromptDelivery, TurnMachine}

  describe "SessionConfig.check/1" do
    test "accepts string and boolean values under adapter-style ids" do
      assert :ok = SessionConfig.check(nil)
      assert :ok = SessionConfig.check(%{})

      assert :ok =
               SessionConfig.check(%{
                 "effort" => "high",
                 "fast" => true,
                 "reasoning_effort" => "xhigh",
                 "fast-mode" => false
               })
    end

    for {bad, why} <- [
          {%{"model" => "opus"}, "model"},
          # The harness's permission mode (ADR 0062 addendum, 2026-10-14):
          # claude's and codex's `mode`, codex's `collaboration_mode`.
          {%{"mode" => "bypassPermissions"}, "permission_policy"},
          {%{"mode" => "agent-full-access"}, "permission_policy"},
          {%{"effort" => "high", "collaboration_mode" => "plan"}, "permission_policy"},
          {%{"" => "x"}, "invalid option id"},
          {%{"has space" => "x"}, "invalid option id"},
          {%{"effort" => ""}, "string of 1 to"},
          {%{"effort" => 3}, "string of 1 to"},
          {%{"effort" => nil}, "string of 1 to"},
          {%{"effort" => "a\u0000b"}, "string of 1 to"},
          {"effort=high", "object"}
        ] do
      test "refuses #{inspect(bad)}" do
        assert {:error, message} = SessionConfig.check(unquote(Macro.escape(bad)))
        assert message =~ unquote(why)
      end
    end

    test "refuses more options than the cap" do
      many = Map.new(1..(SessionConfig.max_options() + 1), &{"opt#{&1}", "x"})
      assert {:error, message} = SessionConfig.check(many)
      assert message =~ "at most"
    end

    test "effective/1 is the agent's options as the conversation launched with them" do
      conv = %{agent_session_config: %{"effort" => "low", "fast" => true}}

      assert SessionConfig.effective(conv) == %{"effort" => "low", "fast" => true}
      assert SessionConfig.effective(%{agent_session_config: nil}) == %{}
      assert SessionConfig.effective(nil) == %{}
    end

    test "effective/1 drops a harness mode a row stored before the refusal" do
      # Rows written between ADR 0062 and its 2026-10-14 addendum passed the
      # shape check with any id; a turn runs without the mode, not failed.
      conv = %{agent_session_config: %{"mode" => "bypassPermissions", "fast" => true}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert SessionConfig.effective(conv) == %{"fast" => true}
        end)

      assert log =~ "mode"
      refute log =~ "bypassPermissions"
    end

    test "requested?/1 is false only for nothing" do
      refute SessionConfig.requested?(nil)
      refute SessionConfig.requested?(%{})
      assert SessionConfig.requested?(%{"effort" => "high"})
      assert SessionConfig.requested?("effort=high")
    end

    test "for_launch/1 copies the agent's, without a harness mode" do
      agent = %{session_config: %{"mode" => "bypassPermissions", "fast" => true}}

      assert SessionConfig.for_launch(agent) == %{"fast" => true}
      assert SessionConfig.for_launch(nil) == %{}
    end
  end

  describe "the agent" do
    test "stores a session config and versions it" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "claude")

      assert {:ok, updated} = Agents.update_agent(agent, %{session_config: %{"effort" => "high"}})
      assert updated.session_config == %{"effort" => "high"}
      assert Agents.snapshot_config(updated)["session_config"] == %{"effort" => "high"}

      assert {:ok, cleared} = Agents.update_agent(updated, %{session_config: nil})
      assert cleared.session_config == %{}
    end

    test "refuses a malformed session config" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "claude")

      assert {:error, changeset} =
               Agents.update_agent(agent, %{session_config: %{"model" => "x"}})

      assert {"cannot set model; use the model field", _} = changeset.errors[:session_config]
    end
  end

  describe "the agent's harness mode" do
    test "is refused on create and update" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "claude")

      assert {:error, changeset} =
               Agents.update_agent(agent, %{session_config: %{"mode" => "bypassPermissions"}})

      assert {msg, _} = changeset.errors[:session_config]
      assert msg =~ "permission_policy"
    end
  end

  describe "launch" do
    setup do
      stub_server_start(fn _sup, _spec -> {:ok, spawn(fn -> :ok end)} end)
      user = insert_active_user()
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "k")
      agent = insert_agent(user_id: user.id, runtime: "claude", model: "anthropic/claude-opus-5")
      %{user: user, agent: agent}
    end

    defp attrs(ctx, extra \\ %{}),
      do: Map.merge(%{"agent_id" => ctx.agent.id, "user_id" => ctx.user.id}, extra)

    test "none requested copies an agent with none as an empty map", ctx do
      assert {:ok, conv} = Launch.start_conversation(attrs(ctx))
      assert conv.agent_session_config == %{}
    end

    test "copies and audits the agent's session config", ctx do
      {:ok, agent} =
        Agents.update_agent(ctx.agent, %{session_config: %{"effort" => "low"}})

      # nil and {} ask for nothing, so older clients that send them launch.
      assert {:ok, conv} = Launch.start_conversation(attrs(ctx, %{"session_config" => %{}}))
      assert {:ok, _} = Launch.start_conversation(attrs(ctx, %{"session_config" => nil}))

      assert conv.agent_session_config == %{"effort" => "low"}

      [audit | _] =
        Fountain.Audit.list_for_user(ctx.user.id)
        |> Enum.filter(&(&1.action == "conversation.created"))

      assert audit.metadata["agent_session_config"] == %{"effort" => "low"}
      refute Map.has_key?(audit.metadata, "session_config")

      # A later edit to the agent leaves the launched conversation's copy alone.
      {:ok, _} = Agents.update_agent(agent, %{session_config: %{"effort" => "max"}})
      assert Repo.reload!(conv).agent_session_config == %{"effort" => "low"}
    end

    test "an agent row stored with a harness mode before the refusal still launches", ctx do
      {1, _} =
        Repo.update_all(
          from(a in Agents.Agent, where: a.id == ^ctx.agent.id),
          set: [session_config: %{"mode" => "bypassPermissions", "effort" => "low"}]
        )

      assert {:ok, conv} = Launch.start_conversation(attrs(ctx))
      assert conv.agent_session_config == %{"effort" => "low"}
    end

    test "a conversation's own session config is refused before anything is written", ctx do
      for config <- [
            %{"effort" => "high"},
            %{"mode" => "bypassPermissions"},
            %{"model" => "x"},
            "effort=high"
          ] do
        assert {:error, :session_config_agent_only} =
                 Launch.start_conversation(attrs(ctx, %{"session_config" => config}))
      end

      assert Repo.aggregate(Conversations.Conversation, :count) == 0
    end

    test "a channel resume naming session config is refused", ctx do
      base = attrs(ctx, %{"channel_id" => "chan-0062"})
      assert {:ok, first, :created} = Launch.start_or_resume_conversation(base)

      assert {:ok, %{id: id}, :resumed} =
               Launch.start_or_resume_conversation(Map.put(base, "session_config", %{}))

      assert id == first.id

      assert {:error, :session_config_agent_only} =
               Launch.start_or_resume_conversation(
                 Map.put(base, "session_config", %{"effort" => "low"})
               )

      assert {:error, :session_config_agent_only} =
               Launch.start_or_resume_conversation(
                 base
                 |> Map.put("session_config", %{"effort" => "low"})
                 |> Map.put("fresh", true)
               )
    end
  end

  describe "opening a turn" do
    setup do
      user = insert_verified_user()

      agent =
        insert_agent(
          user_id: user.id,
          runtime: "claude",
          session_config: %{"effort" => "low", "fast" => true}
        )

      conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")

      %{agent: agent, conv: conv}
    end

    test "records the agent's options from launch as the turn's request", c do
      assert {:ok, _conv, turn} =
               TurnMachine.open(c.conv.id, c.conv.sandbox_id, "p", c.agent, :unspecified, [])

      requested = %{"effort" => "low", "fast" => true}
      assert turn.config_selection == %{"requested" => requested}
      assert TurnMachine.acp_session_config(turn) == requested

      saved = Repo.get!(Conversations.Turn, turn.id)
      assert saved.config_selection == %{"requested" => requested}
    end

    test "a session_config in the opts is not a layer any more", c do
      {:ok, _, turn} =
        TurnMachine.open(c.conv.id, c.conv.sandbox_id, "p", c.agent, :unspecified,
          session_config: %{"effort" => "high"}
        )

      assert TurnMachine.acp_session_config(turn) == %{"effort" => "low", "fast" => true}
    end

    test "an edit to the agent after launch does not reach the conversation's turns", c do
      {:ok, edited} =
        Agents.update_agent(c.agent, %{
          session_config: %{"effort" => "max", "fast" => false, "thinking" => "on"}
        })

      {:ok, _, turn} =
        TurnMachine.open(c.conv.id, c.conv.sandbox_id, "p", edited, :unspecified, [])

      assert TurnMachine.acp_session_config(turn) == %{"effort" => "low", "fast" => true}

      # A conversation launched after the edit runs it.
      later =
        insert_conversation(user_id: c.agent.user_id, agent: edited, status: "idle")

      {:ok, _, turn} =
        TurnMachine.open(later.id, later.sandbox_id, "p", edited, :unspecified, [])

      assert TurnMachine.acp_session_config(turn) ==
               %{"effort" => "max", "fast" => false, "thinking" => "on"}
    end

    test "a turn opened with a harness mode before the refusal does not send it", c do
      {:ok, _, turn} =
        TurnMachine.open(c.conv.id, c.conv.sandbox_id, "p", c.agent, :unspecified, [])

      legacy = %{turn | config_selection: %{"requested" => %{"mode" => "x", "effort" => "low"}}}

      ExUnit.CaptureLog.capture_log(fn ->
        assert TurnMachine.acp_session_config(legacy) == %{"effort" => "low"}
      end)
    end

    test "a turn that requests nothing records nothing" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "claude")
      conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")

      {:ok, _, turn} =
        TurnMachine.open(conv.id, conv.sandbox_id, "p", agent, :unspecified, [])

      assert turn.config_selection == nil
      assert TurnMachine.acp_session_config(turn) == %{}
    end
  end

  describe "the peer's reports" do
    setup do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "claude")
      conv = insert_conversation(user_id: user.id, agent: agent)

      row =
        insert_turn(conv,
          status: "running",
          started_at: DateTime.utc_now(),
          config_selection: %{"requested" => %{"effort" => "high", "reasoning_effort" => "high"}}
        )

      machine = %TurnMachine{conversation_id: conv.id, sandbox_id: conv.sandbox_id, row: row}
      %{conv: conv, machine: machine}
    end

    defp stages(conv_id) do
      Repo.all(
        from(e in Conversations.LogEvent,
          where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == "config",
          order_by: e.id
        )
      )
      |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
    end

    test "applied and skipped options land on the turn and the stream", %{machine: m} = c do
      {m, []} = TurnMachine.handle(m, {:config_selected, "effort", "high", "high"})
      {m, []} = TurnMachine.handle(m, {:config_skipped, "reasoning_effort", "high"})

      saved = Repo.get!(Conversations.Turn, m.row.id)

      assert saved.config_selection == %{
               "requested" => %{"effort" => "high", "reasoning_effort" => "high"},
               "applied" => %{"effort" => "high"},
               "skipped" => ["reasoning_effort"]
             }

      assert [
               {"done",
                %{
                  "outcome" => "applied",
                  "id" => "effort",
                  "requested" => "high",
                  "confirmed" => "high"
                }},
               {"done", %{"outcome" => "skipped", "id" => "reasoning_effort", "reason" => reason}}
             ] = stages(c.conv.id)

      assert reason =~ "not advertised"
    end

    test "a restore report is ignored: every turn requests the same options",
         %{machine: m} = c do
      assert {^m, []} = TurnMachine.handle(m, {:config_restored, "fast", false})

      refute Map.has_key?(Repo.get!(Conversations.Turn, m.row.id).config_selection, "restored")
      assert stages(c.conv.id) == []
    end

    test "the harness mode options are not kept, since they cannot be requested",
         %{machine: m, conv: conv} do
      effort = %{"id" => "effort", "type" => "select", "currentValue" => "high"}

      options = [
        %{"id" => "mode", "category" => "mode", "currentValue" => "default"},
        effort,
        %{"id" => "collaboration_mode", "currentValue" => "default"}
      ]

      assert {^m, []} = TurnMachine.handle(m, {:config_options, options})
      assert Repo.reload!(conv).session_config_options == [effort]
    end

    test "the advertised options are kept on the conversation", %{machine: m, conv: conv} do
      options = [%{"id" => "effort", "type" => "select", "currentValue" => "high"}]
      assert {^m, []} = TurnMachine.handle(m, {:config_options, options})
      assert Repo.reload!(conv).session_config_options == options

      # Unchanged: no write, same value.
      assert {^m, []} = TurnMachine.handle(m, {:config_options, options})
      assert Repo.reload!(conv).session_config_options == options
    end

    test "a refused value fails the turn with the adapter's sentence", %{machine: m} = c do
      assert {updated,
              [
                {:finish, "failed", %{"error" => message, "acp.config_selection_failed" => true},
                 %{reason: message}},
                {:drop_connection, "failed"}
              ]} =
               TurnMachine.handle(
                 m,
                 {:failed, {:config_selection_failed, "effort", "max", "Invalid value: max"}}
               )

      assert message =~ "Could not set effort to \"max\": Invalid value: max"
      assert updated.row.config_selection["status"] == "failed"
      assert updated.row.config_selection["failed_id"] == "effort"

      assert [{"failed", %{"id" => "effort", "detail" => "Invalid value: max"}}] =
               stages(c.conv.id)
    end
  end

  describe "PromptDelivery" do
    test "does not carry a prompt's session config" do
      assert PromptDelivery.travelling(session_config: %{"effort" => "high"}) == []

      assert PromptDelivery.travelling(client_request_id: "r-1", session_config: %{}) ==
               [client_request_id: "r-1"]
    end
  end
end
