defmodule Fountain.Conversations.ModelOverrideTest do
  # ADR 0061: a conversation may run a different model from its agent, set at
  # launch or by reapply, and read wherever a turn meets the model.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Crypto, InferenceCredentials}

  alias Fountain.Conversations.{
    Conversation,
    InferenceBinding,
    InferenceResolution,
    Launch,
    Reapply,
    SpriteEnv,
    TurnMachine
  }

  alias Fountain.InferenceCredentials.Source

  @agent_model "anthropic/claude-opus-5"
  @override "anthropic/claude-sonnet-5"

  describe "launch" do
    setup do
      stub_server_start(fn _sup, _spec -> {:ok, spawn(fn -> :ok end)} end)
      user = insert_active_user()
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "k")
      agent = insert_agent(user_id: user.id, runtime: "claude", model: @agent_model)
      %{user: user, agent: agent}
    end

    defp attrs(ctx, extra \\ %{}),
      do: Map.merge(%{"agent_id" => ctx.agent.id, "user_id" => ctx.user.id}, extra)

    test "no model leaves the column nil and resolves the agent's model", ctx do
      assert {:ok, conv} = Launch.start_conversation(attrs(ctx))
      assert conv.model == nil
      assert conv.inference_source["model"] == @agent_model
    end

    test "a model is stored, resolved and audited", ctx do
      assert {:ok, conv} = Launch.start_conversation(attrs(ctx, %{"model" => @override}))
      assert conv.model == @override
      assert conv.inference_source["model"] == @override

      [audit] =
        Fountain.Audit.list_for_user(ctx.user.id)
        |> Enum.filter(&(&1.action == "conversation.created"))

      assert audit.metadata["model"] == @override
    end

    test "a provider the runtime does not drive is refused before anything is written", ctx do
      assert {:error, {:model_invalid, message}} =
               Launch.start_conversation(attrs(ctx, %{"model" => "openai/gpt-5"}))

      assert message =~ "anthropic/"

      assert {:error, {:model_invalid, _}} =
               Launch.start_conversation(attrs(ctx, %{"model" => "claude-sonnet-5"}))

      assert Repo.aggregate(Conversation, :count) == 0
    end

    test "the acp runtime resolves no model, so an override there is refused", ctx do
      agent = insert_agent(user_id: ctx.user.id, runtime: "acp")

      assert {:error, {:model_invalid, message}} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => ctx.user.id,
                 "model" => @override
               })

      assert message =~ "acp"
    end

    test "a channel resume refuses a model the conversation does not run", ctx do
      base = attrs(ctx, %{"channel_id" => "chan-0061"})

      assert {:ok, first, :created} =
               Launch.start_or_resume_conversation(Map.put(base, "model", @override))

      # Omitted, or the one it runs: resumed.
      assert {:ok, %{id: id}, :resumed} = Launch.start_or_resume_conversation(base)
      assert id == first.id

      assert {:ok, %{id: ^id}, :resumed} =
               Launch.start_or_resume_conversation(Map.put(base, "model", @override))

      # Another: refused, naming the one it runs, and nothing moves.
      assert {:error, {:conversation_model_differs, @override}} =
               Launch.start_or_resume_conversation(Map.put(base, "model", @agent_model))

      assert Repo.reload!(first).model == @override
    end

    test "naming the agent's model resumes a conversation with no override", ctx do
      base = attrs(ctx, %{"channel_id" => "chan-0061-plain"})
      assert {:ok, first, :created} = Launch.start_or_resume_conversation(base)

      assert {:ok, %{id: id}, :resumed} =
               Launch.start_or_resume_conversation(Map.put(base, "model", @agent_model))

      assert id == first.id
    end
  end

  describe "reapply" do
    setup do
      user = insert_verified_user()
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "same-key")
      env = insert_env(user_id: user.id)

      agent =
        insert_agent(
          user_id: user.id,
          runtime: "claude",
          model: @agent_model,
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

      assert :ok = InferenceBinding.reserve(conv, source)

      %{
        user: user,
        agent: agent,
        env: env,
        sandbox: sandbox,
        conv: Repo.reload!(conv),
        source: source
      }
    end

    test "a model applies from the next turn on the same credential", c do
      assert {:ok, reapplied} = Reapply.reapply_conversation(c.conv, %{"model" => @override})
      assert reapplied.model == @override
      assert reapplied.configuration_revision == c.conv.configuration_revision + 1

      # What the turn path reads: the agent as this conversation runs it.
      agent = TurnMachine.agent_for(reapplied)
      assert agent.model == @override
      assert TurnMachine.acp_model(reapplied, agent) == "claude-sonnet-5"

      assert {:ok, _, source, %{anthropic_api_key: "same-key"}} =
               SpriteEnv.resolve_inference(reapplied, agent, c.env, nil)

      assert source.model == @override
      assert source.identity == c.source.identity
      assert source.revision == c.source.revision

      assert {:ok, _, _turn} =
               TurnMachine.open(
                 reapplied.id,
                 c.sandbox.id,
                 "next",
                 agent,
                 reapplied.configuration_revision,
                 source
               )
    end

    test "editing the agent's model does not reach a conversation with an override", c do
      {:ok, reapplied} = Reapply.reapply_conversation(c.conv, %{"model" => @override})
      {:ok, source, _} = SpriteEnv.resolve_inference(reapplied, c.agent, c.env, nil) |> drop_dek()

      {:ok, _} = Agents.update_agent(c.agent, %{model: "anthropic/claude-fable-5-1"})

      agent = TurnMachine.agent_for(reapplied)
      assert agent.model == @override

      # Revalidation reads the override even when handed the plain agent.
      assert {:ok, _, _} =
               InferenceResolution.revalidate(reapplied, Agents.get_agent(c.agent.id, c.user.id),
                 environment_id: c.env.id
               )

      assert {:ok, _, _} =
               TurnMachine.open(
                 reapplied.id,
                 c.sandbox.id,
                 "next",
                 agent,
                 reapplied.configuration_revision,
                 source
               )
    end

    test "null returns to the agent's model; an omitted model keeps the override", c do
      {:ok, reapplied} = Reapply.reapply_conversation(c.conv, %{"model" => @override})
      assert {:ok, kept} = Reapply.reapply_conversation(reapplied, %{})
      assert kept.model == @override

      assert {:ok, cleared} = Reapply.reapply_conversation(kept, %{"model" => nil})
      assert cleared.model == nil
      assert cleared.inference_source["model"] == @agent_model
    end

    test "is audited with the previous and current model", c do
      {:ok, _} = Reapply.reapply_conversation(c.conv, %{"model" => @override}, actor: "api")

      [audit] =
        Fountain.Audit.list_for_user(c.user.id)
        |> Enum.filter(&(&1.action == "conversation.configuration_reapplied"))

      # The fixture leaves agent_version_id unset, so a reapply records that too.
      assert "model" in audit.metadata["changed_fields"]
      assert audit.metadata["previous"]["model"] == nil
      assert audit.metadata["current"]["model"] == @override
    end

    test "a model the runtime cannot run is refused and nothing changes", c do
      before = Repo.reload!(c.conv)

      assert {:error, {:model_invalid, _}} =
               Reapply.reapply_conversation(c.conv, %{"model" => "openai/gpt-5"})

      assert Repo.reload!(c.conv) == before
    end
  end

  describe "a model the pinned credential does not serve" do
    test "is refused as inference_source_changed and nothing changes" do
      user = insert_verified_user()
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "a")
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "o")
      env = insert_env(user_id: user.id)

      agent =
        insert_agent(
          user_id: user.id,
          runtime: "opencode",
          model: @agent_model,
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
      before = Repo.reload!(conv)

      assert {:error, :inference_source_changed} =
               Reapply.reapply_conversation(before, %{"model" => "openai/gpt-5"})

      assert Repo.reload!(conv) == before
      assert before.inference_source == Source.dump(source)
    end
  end

  test "with_model/2 overrides only when the conversation has a model" do
    agent = %Agents.Agent{model: @agent_model}
    assert Conversation.with_model(agent, %{model: nil}).model == @agent_model
    assert Conversation.with_model(agent, %{model: @override}).model == @override
    assert Conversation.with_model(nil, %{model: @override}) == nil
  end

  defp drop_dek({:ok, _dek, source, creds}), do: {:ok, source, creds}
end
