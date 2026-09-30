defmodule Fountain.Conversations.SessionConfigTest do
  # ADR 0062: ACP session config options (reasoning effort, fast mode) on the
  # agent, the conversation and the prompt, recorded on the turn, and the
  # peer's reports about them.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Crypto, InferenceCredentials}
  alias Fountain.Agents.SessionConfig

  alias Fountain.Conversations
  alias Fountain.Conversations.{InferenceBinding, Launch, PromptDelivery, Reapply, TurnMachine}

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

    test "effective/3 layers agent, conversation and prompt" do
      agent = %{session_config: %{"effort" => "low", "fast" => true}}
      conv = %{session_config: %{"effort" => "medium"}}

      assert SessionConfig.effective(agent, conv, nil) == %{"effort" => "medium", "fast" => true}

      assert SessionConfig.effective(agent, conv, %{"effort" => "high"}) ==
               %{"effort" => "high", "fast" => true}

      assert SessionConfig.effective(nil, nil, nil) == %{}
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

    test "stores and audits the conversation's session config", ctx do
      config = %{"effort" => "high", "fast" => true}
      assert {:ok, conv} = Launch.start_conversation(attrs(ctx, %{"session_config" => config}))
      assert conv.session_config == config

      [audit] =
        Fountain.Audit.list_for_user(ctx.user.id)
        |> Enum.filter(&(&1.action == "conversation.created"))

      assert audit.metadata["session_config"] == config
    end

    test "none requested is an empty map", ctx do
      assert {:ok, conv} = Launch.start_conversation(attrs(ctx))
      assert conv.session_config == %{}
    end

    test "a malformed session config is refused before anything is written", ctx do
      assert {:error, {:session_config_invalid, message}} =
               Launch.start_conversation(attrs(ctx, %{"session_config" => %{"model" => "x"}}))

      assert message =~ "model"
      assert Repo.aggregate(Conversations.Conversation, :count) == 0
    end

    test "a channel resume refuses session config the conversation does not request", ctx do
      base = attrs(ctx, %{"channel_id" => "chan-0062"})
      config = %{"effort" => "high"}

      assert {:ok, first, :created} =
               Launch.start_or_resume_conversation(Map.put(base, "session_config", config))

      assert {:ok, %{id: id}, :resumed} = Launch.start_or_resume_conversation(base)
      assert id == first.id

      assert {:ok, %{id: ^id}, :resumed} =
               Launch.start_or_resume_conversation(Map.put(base, "session_config", config))

      assert {:error, {:conversation_session_config_differs, ^config}} =
               Launch.start_or_resume_conversation(
                 Map.put(base, "session_config", %{"effort" => "low"})
               )
    end
  end

  describe "reapply" do
    setup do
      user = insert_verified_user()
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "k")
      env = insert_env(user_id: user.id)

      agent =
        insert_agent(
          user_id: user.id,
          runtime: "claude",
          model: "anthropic/claude-opus-5",
          environment_id: env.id
        )

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          mode: "ephemeral",
          agent_id: agent.id,
          environment_id: env.id,
          build_fingerprint: Reapply.fingerprint(env)
        )

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      {:ok, source, _} =
        InferenceCredentials.resolve(user.id, agent.model, agent.runtime, environment_id: env.id)

      :ok = InferenceBinding.reserve(conv, source)
      %{user: user, conv: Repo.reload!(conv)}
    end

    test "sets, keeps when omitted, and clears with null", c do
      config = %{"effort" => "max"}
      assert {:ok, set} = Reapply.reapply_conversation(c.conv, %{"session_config" => config})
      assert set.session_config == config
      assert set.configuration_revision == c.conv.configuration_revision + 1

      assert {:ok, kept} = Reapply.reapply_conversation(set, %{})
      assert kept.session_config == config

      assert {:ok, cleared} = Reapply.reapply_conversation(kept, %{"session_config" => nil})
      assert cleared.session_config == %{}
    end

    test "is audited with the previous and current options", c do
      config = %{"fast" => true}
      {:ok, _} = Reapply.reapply_conversation(c.conv, %{"session_config" => config}, actor: "api")

      [audit] =
        Fountain.Audit.list_for_user(c.user.id)
        |> Enum.filter(&(&1.action == "conversation.configuration_reapplied"))

      assert "session_config" in audit.metadata["changed_fields"]
      assert audit.metadata["previous"]["session_config"] == %{}
      assert audit.metadata["current"]["session_config"] == config
    end

    test "a malformed session config is refused and nothing changes", c do
      before = Repo.reload!(c.conv)

      assert {:error, {:session_config_invalid, _}} =
               Reapply.reapply_conversation(c.conv, %{"session_config" => %{"effort" => 1}})

      assert Repo.reload!(c.conv) == before
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

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          status: "idle",
          session_config: %{"effort" => "medium"}
        )

      %{agent: agent, conv: conv}
    end

    test "records agent, then conversation, then prompt as the turn's request", c do
      assert {:ok, _conv, turn} =
               TurnMachine.open(c.conv.id, c.conv.sandbox_id, "p", c.agent, nil, :unspecified,
                 session_config: %{"effort" => "high"}
               )

      requested = %{"effort" => "high", "fast" => true}
      assert turn.config_selection == %{"requested" => requested}
      assert TurnMachine.acp_session_config(turn) == requested

      saved = Repo.get!(Conversations.Turn, turn.id)
      assert saved.config_selection == %{"requested" => requested}
    end

    test "the next turn goes back to the conversation's", c do
      {:ok, _, first} =
        TurnMachine.open(c.conv.id, c.conv.sandbox_id, "p", c.agent, nil, :unspecified,
          session_config: %{"effort" => "high"}
        )

      Conversations._unsafe_update_turn(first, %{status: "completed"})

      {:ok, _, second} =
        TurnMachine.open(c.conv.id, c.conv.sandbox_id, "p2", c.agent, nil, :unspecified, [])

      assert TurnMachine.acp_session_config(second) == %{"effort" => "medium", "fast" => true}
    end

    test "a turn that requests nothing records nothing" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "claude")
      conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")

      {:ok, _, turn} =
        TurnMachine.open(conv.id, conv.sandbox_id, "p", agent, nil, :unspecified, [])

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
    test "carries a prompt's session config, and drops an empty or malformed one" do
      assert PromptDelivery.travelling(session_config: %{"effort" => "high"}) ==
               [session_config: %{"effort" => "high"}]

      assert PromptDelivery.travelling(session_config: %{}) == []
      assert PromptDelivery.travelling(session_config: %{"model" => "x"}) == []
      assert PromptDelivery.travelling(session_config: nil) == []
    end
  end
end
