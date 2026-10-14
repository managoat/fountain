defmodule Fountain.Conversations.ModelOverrideTest do
  # ADR 0061: a conversation may run a different model from its agent, set at
  # launch, and read wherever a turn meets the model.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Crypto, InferenceCredentials}

  alias Fountain.Conversations.{
    Conversation,
    InferenceBinding,
    InferenceResolution,
    Launch,
    SpriteEnv,
    TurnMachine
  }

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

  describe "a conversation with an override" do
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
          environment_id: env.id
        )

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          sandbox: sandbox,
          status: "idle",
          model: @override
        )

      {:ok, source, _} =
        InferenceCredentials.resolve(user.id, @override, agent.runtime, environment_id: env.id)

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

    test "every turn runs the override on the conversation's credential", c do
      # What the turn path reads: the agent as this conversation runs it.
      agent = TurnMachine.agent_for(c.conv)
      assert agent.model == @override
      assert TurnMachine.acp_model(c.conv, agent) == "claude-sonnet-5"

      assert {:ok, _, source, %{anthropic_api_key: "same-key"}} =
               SpriteEnv.resolve_inference(c.conv, agent, c.env, nil)

      assert source.model == @override
      assert source.identity == c.source.identity
      assert source.revision == c.source.revision

      assert {:ok, _, _turn} = TurnMachine.open(c.conv.id, c.sandbox.id, "next", agent, source)
    end

    test "editing the agent's model does not reach a conversation with an override", c do
      {:ok, source, _} = SpriteEnv.resolve_inference(c.conv, c.agent, c.env, nil) |> drop_dek()

      {:ok, _} = Agents.update_agent(c.agent, %{model: "anthropic/claude-fable-5-1"})

      agent = TurnMachine.agent_for(c.conv)
      assert agent.model == @override

      # Revalidation reads the override even when handed the plain agent.
      assert {:ok, _, _} =
               InferenceResolution.revalidate(c.conv, Agents.get_agent(c.agent.id, c.user.id),
                 environment_id: c.env.id
               )

      assert {:ok, _, _} = TurnMachine.open(c.conv.id, c.sandbox.id, "next", agent, source)
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
