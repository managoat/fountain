defmodule Fountain.Conversations.LaunchCredentialSetTest do
  @moduledoc """
  A launch may run on a credential set other than its agent's (ADR 0053
  decision 3), bounded by `agent.allowed_inference_credential_ids`.

  The precedence is the launch, then the agent, then the account's default,
  and it is `InferenceResolution.credential_set_id/2` that says so -- one function, so
  the provision and the door gate cannot disagree about which credential this
  conversation runs on.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Agents
  alias Fountain.Conversations
  alias Fountain.Conversations.InferenceResolution
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.Conversations.Launch

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

    default = write_key(default, dek, :anthropic_api_key, "sk-default")
    second = write_key(second, dek, :anthropic_api_key, "sk-second")
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

      assert InferenceResolution.credential_set_id(conv, agent) == second.id
    end

    test "the agent answers when the launch said nothing", %{default: default} do
      assert InferenceResolution.credential_set_id(%{inference_credential_id: nil}, %{
               inference_credential_id: default.id
             }) == default.id
    end

    test "nil is the account's default, and a conversation with no agent has only that" do
      assert InferenceResolution.credential_set_id(%{inference_credential_id: nil}, nil) == nil

      assert InferenceResolution.credential_set_id(%{inference_credential_id: nil}, %{
               inference_credential_id: nil
             }) == nil
    end

    # A conversation admitted before sources were stored has no expected
    # source, and re-validating it is a new selection on the set it or its
    # agent names, not the account default. Review on #2197: the helper
    # once dropped the set whenever it re-validated, and the resolver then
    # chose the default for every legacy row.
    test "revalidate/3 with no stored source selects the set the agent names", %{
      user: user,
      default: default,
      second: second
    } do
      agent = agent_for(user, %{"inference_credential_id" => second.id})
      conv = %{user_id: user.id, runtime: "claude", inference_source: nil}

      assert {:ok, source, _} = InferenceResolution.revalidate(conv, agent, [])
      assert source.set_id == second.id
      refute source.set_id == default.id

      override = Map.put(conv, :inference_credential_id, default.id)
      assert {:ok, source, _} = InferenceResolution.revalidate(override, agent, [])
      assert source.set_id == default.id
    end
  end

  describe "the launch override at the door" do
    test "is stored on the conversation", %{user: user, second: second} do
      agent = agent_for(user)

      {:ok, conv} =
        Launch.start_conversation(%{
          "agent_id" => agent.id,
          "user_id" => user.id,
          "inference_credential_id" => second.id
        })

      assert conv.inference_credential_id == second.id
    end

    test "saying nothing pins the agent's selected set at admission", %{
      user: user,
      second: second
    } do
      agent = agent_for(user, %{"inference_credential_id" => second.id})

      {:ok, conv} =
        Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      assert conv.inference_credential_id == second.id
      assert conv.inference_source["set_id"] == second.id
      assert InferenceResolution.credential_set_id(conv, agent) == second.id
    end

    test "another tenant's set is not found, not attached", %{user: user} do
      agent = agent_for(user)
      other = insert_verified_user()
      {:ok, theirs} = InferenceCredentials.create_set(other.id, "Theirs")

      assert {:error, :inference_credential_not_found} =
               Launch.start_conversation(%{
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
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => second.id
               })

      assert conv.inference_credential_id == second.id
    end

    test "an empty list forbids every override", %{user: user, second: second} do
      agent = agent_for(user, %{"allowed_inference_credential_ids" => []})

      assert {:error, :inference_credential_not_allowed} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => second.id
               })
    end

    test "a non-empty list is an allowlist", %{user: user, default: default, second: second} do
      agent = agent_for(user, %{"allowed_inference_credential_ids" => [second.id]})

      assert {:ok, _} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => second.id
               })

      assert {:error, :inference_credential_not_allowed} =
               Launch.start_conversation(%{
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
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => second.id
               })

      assert conv.inference_credential_id == second.id
    end

    test "an unrestricted policy reaches a set created after the agent", %{user: user, dek: dek} do
      agent = agent_for(user)
      assert agent.inference_credential_access == "all_tenant_credential_sets"
      {:ok, later} = InferenceCredentials.create_set(user.id, "Created later")
      later = write_key(later, dek, :anthropic_api_key, "sk-later")

      assert {:ok, conv} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => later.id
               })

      assert conv.inference_credential_id == later.id
    end

    test "another tenant's set is refused even when explicitly allowlisted", %{user: user} do
      {:ok, theirs} = InferenceCredentials.create_set(insert_active_user().id, "Theirs")
      agent = agent_for(user, %{"allowed_inference_credential_ids" => [theirs.id]})

      assert {:error, :inference_credential_not_found} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "inference_credential_id" => theirs.id
               })
    end
  end

  describe "deleting a set a conversation named" do
    test "preserves the transcript and source reference without selecting a fallback", %{
      user: user,
      second: second
    } do
      agent = agent_for(user)

      {:ok, conv} =
        Launch.start_conversation(%{
          "agent_id" => agent.id,
          "user_id" => user.id,
          "inference_credential_id" => second.id
        })

      {:ok, _} = InferenceCredentials.delete_set(second)

      reloaded = Repo.reload!(conv)
      assert is_nil(reloaded.inference_credential_id)
      assert reloaded.inference_source["set_id"] == second.id

      assert {:error, :inference_credential_not_found} =
               InferenceCredentials.resolve(user.id, agent.model, agent.runtime,
                 expected_source: reloaded.inference_source
               )
    end
  end

  describe "channel credential binding" do
    test "an explicit different set creates another conversation on the same workspace", ctx do
      agent = agent_for(ctx.user)
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      attrs = channel_attrs(ctx.user, agent, sandbox)

      assert {:ok, first, :created} =
               Launch.start_or_resume_conversation(
                 Map.put(attrs, "inference_credential_id", ctx.default.id)
               )

      assert {:ok, second, :created} =
               Launch.start_or_resume_conversation(
                 Map.put(attrs, "inference_credential_id", ctx.second.id)
               )

      refute first.id == second.id
      assert first.sandbox_id == second.sandbox_id

      assert Launch.channel_conversation(Map.put(attrs, "inference_credential_id", ctx.second.id)).id ==
               second.id
    end

    test "an omitted selection retains its source after the default changes", ctx do
      agent = agent_for(ctx.user)
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      attrs = channel_attrs(ctx.user, agent, sandbox)
      assert {:ok, first, :created} = Launch.start_or_resume_conversation(attrs)
      assert first.inference_source["set_id"] == ctx.default.id
      assert {:ok, _} = InferenceCredentials.set_default(ctx.second)

      assert {:ok, resumed, :resumed} = Launch.start_or_resume_conversation(attrs)
      assert resumed.id == first.id
      assert Repo.reload!(resumed).inference_source == first.inference_source
    end

    test "an existing channel cannot bypass a narrowed allowlist", ctx do
      agent = agent_for(ctx.user)
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")

      attrs =
        Map.put(channel_attrs(ctx.user, agent, sandbox), "inference_credential_id", ctx.second.id)

      assert {:ok, first, :created} = Launch.start_or_resume_conversation(attrs)
      assert {:ok, _} = Agents.update_agent(agent, %{"allowed_inference_credential_ids" => []})

      assert {:error, :inference_credential_not_allowed} =
               Launch.start_or_resume_conversation(attrs)

      assert is_nil(Launch.channel_conversation(attrs))
      assert Repo.reload!(first).channel_id == attrs["channel_id"]
    end

    test "replacing a bound credential refuses channel resume", ctx do
      agent = agent_for(ctx.user)
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      attrs = channel_attrs(ctx.user, agent, sandbox)
      assert {:ok, first, :created} = Launch.start_or_resume_conversation(attrs)
      write_key(ctx.default, ctx.dek, :anthropic_api_key, "sk-replaced")

      assert {:error, :inference_source_changed} =
               Launch.start_or_resume_conversation(attrs)

      assert Repo.reload!(first).inference_source == first.inference_source
    end

    test "deleting a bound set never resumes against the current default", ctx do
      agent = agent_for(ctx.user, %{"inference_credential_id" => ctx.second.id})
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      attrs = channel_attrs(ctx.user, agent, sandbox)
      assert {:ok, first, :created} = Launch.start_or_resume_conversation(attrs)
      assert {:ok, _} = InferenceCredentials.delete_set(ctx.second)

      assert {:error, :inference_credential_not_found} =
               Launch.start_or_resume_conversation(attrs)

      assert Repo.reload!(first).inference_source["set_id"] == ctx.second.id
    end

    # Rows admitted before sources were stored resume with `inference_source`
    # nil, and `InferenceBinding.reserve/2` persists whatever resume resolves
    # for them. That must be the set the agent (or the launch) named, or the
    # first resume pins the account default to the conversation for good.
    test "a legacy conversation with no stored source resumes on the agent's set", ctx do
      agent = agent_for(ctx.user, %{"inference_credential_id" => ctx.second.id})
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      attrs = channel_attrs(ctx.user, agent, sandbox)
      assert {:ok, first, :created} = Launch.start_or_resume_conversation(attrs)
      assert first.inference_source["set_id"] == ctx.second.id
      first |> Ecto.Changeset.change(inference_source: nil) |> Repo.update!()

      assert {:ok, resumed, :resumed} = Launch.start_or_resume_conversation(attrs)
      assert resumed.id == first.id
      assert Repo.reload!(resumed).inference_source["set_id"] == ctx.second.id
    end

    test "a legacy conversation with no stored source resumes on its own override", ctx do
      agent = agent_for(ctx.user)
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")

      attrs =
        Map.put(channel_attrs(ctx.user, agent, sandbox), "inference_credential_id", ctx.second.id)

      assert {:ok, first, :created} = Launch.start_or_resume_conversation(attrs)
      assert first.inference_source["set_id"] == ctx.second.id
      first |> Ecto.Changeset.change(inference_source: nil) |> Repo.update!()

      assert {:ok, resumed, :resumed} = Launch.start_or_resume_conversation(attrs)
      assert resumed.id == first.id
      assert Repo.reload!(resumed).inference_source["set_id"] == ctx.second.id
    end
  end

  describe "turn source binding" do
    test "admission persists a nonsecret source and refuses a replacement", ctx do
      agent = agent_for(ctx.user)
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      attrs = Map.delete(channel_attrs(ctx.user, agent, sandbox), "channel_id")
      assert {:ok, conv} = Launch.start_conversation(attrs)

      turn_attrs = %{
        conversation_id: conv.id,
        turn_number: 1,
        prompt: "hello",
        status: "running",
        inference_source: conv.inference_source
      }

      assert {:ok, turn} =
               Conversations._unsafe_create_turn_on_sandbox(turn_attrs, sandbox.id)

      assert turn.inference_source == conv.inference_source
      refute inspect(turn.inference_source) =~ "sk-default"
      assert {:ok, _} = Conversations._unsafe_update_turn(turn, %{status: "completed"})
      write_key(ctx.default, ctx.dek, :anthropic_api_key, "sk-replaced")

      assert {:error, :inference_source_changed} =
               Conversations._unsafe_create_turn_on_sandbox(
                 %{turn_attrs | turn_number: 2},
                 sandbox.id
               )

      assert Repo.aggregate(
               from(t in Fountain.Conversations.Turn, where: t.conversation_id == ^conv.id),
               :count
             ) == 1
    end

    test "a stale actor cannot adopt a newly persisted source", ctx do
      agent = agent_for(ctx.user)
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")

      assert {:ok, conv} =
               Launch.start_conversation(
                 Map.delete(channel_attrs(ctx.user, agent, sandbox), "channel_id")
               )

      attrs = %{
        conversation_id: conv.id,
        turn_number: 1,
        prompt: "hello",
        status: "running",
        inference_source: Map.put(conv.inference_source, "revision", Ecto.UUID.generate())
      }

      assert {:error, :inference_source_changed} =
               Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id)

      assert Repo.aggregate(
               from(t in Fountain.Conversations.Turn, where: t.conversation_id == ^conv.id),
               :count
             ) == 0
    end
  end

  describe "Codex admission" do
    test "an attached peer reserves its source before any process starts", ctx do
      write_key(ctx.default, ctx.dek, :openai_api_key, "sk-openai-first")
      write_key(ctx.second, ctx.dek, :openai_api_key, "sk-openai-second")
      agent = agent_for(ctx.user, %{"runtime" => "codex", "model" => "openai/gpt-5"})
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")

      {:ok, source, _} =
        InferenceCredentials.resolve(ctx.user.id, agent.model, agent.runtime,
          credential_set_id: ctx.default.id
        )

      # This fixture represents a machine initially provisioned on this source.
      # An existing machine with unknown auth state cannot safely accept one.
      Ecto.Changeset.change(sandbox,
        codex_inference_source: Fountain.InferenceCredentials.Source.dump(source)
      )
      |> Repo.update!()

      attrs = Map.delete(channel_attrs(ctx.user, agent, sandbox), "channel_id")

      assert {:ok, first} =
               Launch.start_conversation(
                 Map.put(attrs, "inference_credential_id", ctx.default.id)
               )

      assert first.status == "idle"

      assert {:error, :codex_inference_conflict} =
               Launch.start_conversation(Map.put(attrs, "inference_credential_id", ctx.second.id))

      assert Repo.aggregate(
               from(c in Fountain.Conversations.Conversation,
                 where: c.sandbox_id == ^sandbox.id
               ),
               :count
             ) == 1
    end
  end

  defp channel_attrs(user, agent, sandbox) do
    %{
      "user_id" => user.id,
      "agent_id" => agent.id,
      "sandbox_id" => sandbox.id,
      "channel_id" => "credential-binding"
    }
  end

  defp write_key(set, dek, kind, value) do
    field = String.to_existing_atom("#{kind}_ciphertext")
    set |> Ecto.Changeset.change(%{field => Crypto.encrypt(value, dek)}) |> Repo.update!()
  end
end
