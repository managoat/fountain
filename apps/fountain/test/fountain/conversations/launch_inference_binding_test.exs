defmodule Fountain.Conversations.LaunchInferenceBindingTest do
  @moduledoc """
  Admission binds a conversation to the inference source it resolved: the
  user's one credential record, at its revision (ADR 0053 decisions 2 and 5;
  named sets retired by its 2026-10-14 addendum). A key rotated in place is
  the same source at a new revision, and carries on (#2602); a different
  record is a different source, so the binding refuses it.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Agents
  alias Fountain.Conversations
  alias Fountain.Conversations.InferenceResolution
  alias Fountain.Conversations.Launch
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials

  setup do
    # Stop the real ConversationServer from starting: these tests are about
    # what the door resolves and stores, and a live server spawns processes
    # outside the SQL Sandbox's ownership.
    stub_server_start(fn _sup, _spec ->
      {:ok, spawn(fn -> :ok end)}
    end)

    user = insert_active_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    {:ok, record} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-a")
    %{user: user, dek: dek, record: record}
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

  test "admission pins the user's record", %{user: user, record: record} do
    agent = agent_for(user)
    {:ok, conv} = Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

    assert conv.inference_source["set_id"] == record.id
    assert conv.inference_source["identity"] == "credential:#{record.id}:anthropic_api_key"
  end

  test "a source whose record is gone is not found, never re-selected", %{user: user} do
    agent = agent_for(user)
    {:ok, conv} = Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})
    Repo.delete_all(InferenceCredentials.Credential)

    assert {:error, :inference_credential_not_found} =
             InferenceCredentials.resolve(user.id, agent.model, agent.runtime,
               expected_source: conv.inference_source
             )
  end

  test "a source bound to no record stays bound to none after a key is added" do
    other = insert_active_user()
    agent = agent_for(other)
    {:ok, source, _} = InferenceResolution.select(other.id, agent, [])
    assert source.scope == :missing
    assert is_nil(source.set_id)

    {:ok, dek} = Crypto.load_tenant_key(other.id)
    {:ok, _} = InferenceCredentials.put_credential(other.id, dek, :anthropic_api_key, "sk-b")

    assert {:ok, ^source, _} =
             InferenceCredentials.resolve(other.id, agent.model, agent.runtime,
               expected_source: InferenceCredentials.Source.dump(source)
             )
  end

  describe "channel credential binding" do
    test "resume keeps the stored source", ctx do
      agent = agent_for(ctx.user)
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      attrs = channel_attrs(ctx.user, agent, sandbox)
      assert {:ok, first, :created} = Launch.start_or_resume_conversation(attrs)

      assert {:ok, resumed, :resumed} = Launch.start_or_resume_conversation(attrs)
      assert resumed.id == first.id
      assert Repo.reload!(resumed).inference_source == first.inference_source
    end

    test "rotating a bound credential in place keeps channel resume", ctx do
      agent = agent_for(ctx.user)
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      attrs = channel_attrs(ctx.user, agent, sandbox)
      assert {:ok, first, :created} = Launch.start_or_resume_conversation(attrs)
      write_key(ctx.record, ctx.dek, :anthropic_api_key, "sk-replaced")

      assert {:ok, resumed, :resumed} = Launch.start_or_resume_conversation(attrs)
      assert resumed.id == first.id
    end

    test "a bound credential replaced by another record refuses channel resume", ctx do
      agent = agent_for(ctx.user)
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      attrs = channel_attrs(ctx.user, agent, sandbox)
      assert {:ok, first, :created} = Launch.start_or_resume_conversation(attrs)
      Repo.delete!(ctx.record)

      {:ok, _} =
        InferenceCredentials.put_credential(ctx.user.id, ctx.dek, :anthropic_api_key, "sk-a")

      assert {:error, :inference_credential_not_found} =
               Launch.start_or_resume_conversation(attrs)

      assert Repo.reload!(first).inference_source == first.inference_source
    end

    # Rows admitted before sources were stored resume with `inference_source`
    # nil, and `InferenceBinding.reserve/2` persists whatever resume resolves
    # for them: the user's record.
    test "a legacy conversation with no stored source resumes on the user's record", ctx do
      agent = agent_for(ctx.user)
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      attrs = channel_attrs(ctx.user, agent, sandbox)
      assert {:ok, first, :created} = Launch.start_or_resume_conversation(attrs)
      first |> Ecto.Changeset.change(inference_source: nil) |> Repo.update!()

      assert {:ok, resumed, :resumed} = Launch.start_or_resume_conversation(attrs)
      assert resumed.id == first.id
      assert Repo.reload!(resumed).inference_source["set_id"] == ctx.record.id
    end
  end

  describe "turn source binding" do
    test "admission persists a nonsecret source, admits a rotation and refuses a replacement",
         ctx do
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
               Conversations._unsafe_create_turn_on_sandbox(turn_attrs, conv.sandbox_id)

      assert turn.inference_source == conv.inference_source
      refute inspect(turn.inference_source) =~ "sk-a"
      assert {:ok, _} = Conversations._unsafe_update_turn(turn, %{status: "completed"})
      write_key(ctx.record, ctx.dek, :anthropic_api_key, "sk-rotated")

      assert {:ok, second} =
               Conversations._unsafe_create_turn_on_sandbox(
                 %{turn_attrs | turn_number: 2},
                 conv.sandbox_id
               )

      assert second.inference_source == conv.inference_source
      assert {:ok, _} = Conversations._unsafe_update_turn(second, %{status: "completed"})

      Repo.delete!(Repo.reload!(ctx.record))

      {:ok, _} =
        InferenceCredentials.put_credential(ctx.user.id, ctx.dek, :anthropic_api_key, "sk-a")

      assert {:error, :inference_source_changed} =
               Conversations._unsafe_create_turn_on_sandbox(
                 %{turn_attrs | turn_number: 3},
                 conv.sandbox_id
               )

      assert Repo.aggregate(
               from(t in Fountain.Conversations.Turn, where: t.conversation_id == ^conv.id),
               :count
             ) == 2
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
               Conversations._unsafe_create_turn_on_sandbox(attrs, conv.sandbox_id)

      assert Repo.aggregate(
               from(t in Fountain.Conversations.Turn, where: t.conversation_id == ^conv.id),
               :count
             ) == 0
    end
  end

  defp channel_attrs(user, agent, _sandbox) do
    %{
      "user_id" => user.id,
      "agent_id" => agent.id,
      "channel_id" => "credential-binding"
    }
  end

  defp write_key(record, dek, kind, value) do
    field = String.to_existing_atom("#{kind}_ciphertext")
    record |> Ecto.Changeset.change(%{field => Crypto.encrypt(value, dek)}) |> Repo.update!()
  end
end
