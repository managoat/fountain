defmodule Fountain.Conversations.LaunchCredentialSetTest do
  @moduledoc """
  A launch may run on a credential set other than its agent's (ADR 0053
  decision 3), bounded by `agent.allowed_inference_credential_ids`.

  The precedence is the launch, then the agent, then the account's default,
  and it is `SpriteEnv.credential_set_id/2` that says so -- one function, so
  the provision and the door gate cannot disagree about which credential this
  conversation runs on.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Agents
  alias Fountain.Conversations
  alias Fountain.Conversations.SpriteEnv
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials

  setup do
    # Stop the real ConversationServer from starting: these tests are about
    # what the door resolves and stores, and a live server spawns processes
    # outside the SQL Sandbox's ownership. Same shape the environment
    # override tests in conversations_start_test.exs use.
    stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
      {:ok, spawn(fn -> :ok end)}
    end)

    user = insert_active_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)

    {:ok, default} = InferenceCredentials.create_set(user.id, "Default")
    {:ok, second} = InferenceCredentials.create_set(user.id, "Second subscription")

    %{user: user, dek: dek, default: default, second: second}
  end

  defp agent_for(user, overrides \\ %{}) do
    {:ok, agent} =
      Agents.create_agent(
        agent_attrs(
          Map.merge(
            %{
              "user_id" => user.id,
              "runtime" => "claude",
              "model" => "anthropic/claude-opus-5"
            },
            overrides
          )
        )
      )

    agent
  end

  describe "credential_set_id/2 is the precedence rule" do
    test "the launch wins over the agent", %{default: default, second: second} do
      agent = %{inference_credential_id: default.id}
      conv = %{inference_credential_id: second.id}

      assert SpriteEnv.credential_set_id(conv, agent) == second.id
    end

    test "the agent answers when the launch said nothing", %{default: default} do
      assert SpriteEnv.credential_set_id(%{inference_credential_id: nil}, %{
               inference_credential_id: default.id
             }) == default.id
    end

    test "nil is the account's default, and a conversation with no agent has only that" do
      assert SpriteEnv.credential_set_id(%{inference_credential_id: nil}, nil) == nil

      assert SpriteEnv.credential_set_id(%{inference_credential_id: nil}, %{
               inference_credential_id: nil
             }) == nil
    end
  end

  describe "the launch override at the door" do
    test "is stored on the conversation", %{user: user, second: second} do
      agent = agent_for(user)

      {:ok, conv} =
        Conversations.start_conversation(%{
          "agent_id" => agent.id,
          "user_id" => user.id,
          "inference_credential_id" => second.id
        })

      assert conv.inference_credential_id == second.id
    end

    test "saying nothing leaves it nil, so the conversation follows its agent", %{
      user: user,
      second: second
    } do
      agent = agent_for(user, %{"inference_credential_id" => second.id})

      {:ok, conv} =
        Conversations.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      assert is_nil(conv.inference_credential_id)
      assert SpriteEnv.credential_set_id(conv, agent) == second.id
    end

    test "another tenant's set is not found, not attached", %{user: user} do
      agent = agent_for(user)
      other = insert_verified_user()
      {:ok, theirs} = InferenceCredentials.create_set(other.id, "Theirs")

      assert {:error, :inference_credential_not_found} =
               Conversations.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => theirs.id
               })
    end
  end

  describe "the agent's allowlist" do
    test "nil allows any set the tenant owns", %{user: user, second: second} do
      agent = agent_for(user)
      assert is_nil(agent.allowed_inference_credential_ids)

      assert {:ok, conv} =
               Conversations.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => second.id
               })

      assert conv.inference_credential_id == second.id
    end

    test "an empty list forbids every override", %{user: user, second: second} do
      agent = agent_for(user, %{"allowed_inference_credential_ids" => []})

      assert {:error, :inference_credential_not_allowed} =
               Conversations.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => second.id
               })
    end

    test "a non-empty list is an allowlist", %{user: user, default: default, second: second} do
      agent = agent_for(user, %{"allowed_inference_credential_ids" => [second.id]})

      assert {:ok, _} =
               Conversations.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => second.id
               })

      assert {:error, :inference_credential_not_allowed} =
               Conversations.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => default.id
               })
    end

    # Naming the set the agent already runs on is not an override, so it is
    # not something the allowlist has an opinion about. Same rule the
    # environment allowlist follows.
    test "naming the agent's own set passes an empty allowlist", %{user: user, second: second} do
      agent =
        agent_for(user, %{
          "inference_credential_id" => second.id,
          "allowed_inference_credential_ids" => []
        })

      assert {:ok, conv} =
               Conversations.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => second.id
               })

      assert conv.inference_credential_id == second.id
    end
  end

  describe "deleting a set a conversation named" do
    test "returns the conversation to the agent's rather than deleting the transcript", %{
      user: user,
      second: second
    } do
      agent = agent_for(user)

      {:ok, conv} =
        Conversations.start_conversation(%{
          "agent_id" => agent.id,
          "user_id" => user.id,
          "inference_credential_id" => second.id
        })

      {:ok, _} = InferenceCredentials.delete_set(second)

      reloaded = Repo.reload!(conv)
      assert is_nil(reloaded.inference_credential_id)
      assert SpriteEnv.credential_set_id(reloaded, agent) == nil
    end
  end
end
