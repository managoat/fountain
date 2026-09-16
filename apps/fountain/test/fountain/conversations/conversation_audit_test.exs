defmodule Fountain.Conversations.ConversationAuditTest do
  @moduledoc """
  Conversation lifecycle actions leave a trail (#545).

  These were audited when driven through `/api`, by the blanket plug on that
  pipeline, and silent through the UI — where conversations are actually
  started, prompted and stopped. They are also the spend-relevant actions in
  the product: every conversation runs a sandbox, so the trail matters for a
  billing dispute as much as for a security question.

  The one rule these tests exist to hold: **prompt content never reaches the
  trail.** A prompt is usually the most sensitive thing in the system.
  """

  use Fountain.ConversationServerCase

  alias Fountain.{Audit, Conversations}
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Launch
  alias Fountain.Conversations.Termination

  # Ending a conversation whose server is gone now destroys its machine through
  # `Fountain.Machines.Machine` (ADR 0058 stage 5) rather than leaving the
  # sprite for the reaper, so these tests reach the provider where they did not
  # before. Nothing here is about the provider, so the adapter seam answers
  # yes and the assertions stay about the rows and the trail. Stubbed at
  # `Managoat.Sandbox.Sprites` rather than at the `Managoat.Sandbox` facade so
  # a test that drives either layer itself still overrides it.
  setup do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    # These start real servers with the real runtime module and assert the
    # audit trail, not the turn pipeline. The default claude agent provisions
    # over the ACP path (the adapter install is covered by the harness's
    # Sprites.cmd/4 stub); the turn's spawn may fail against the fake sprite,
    # which is fine — the trail records the action, not the outcome.
    agent = insert_agent(user_id: user.id, environment_id: env.id)

    {:ok, user: user, env: env, agent: agent}
  end

  defp events_for(user_id), do: Audit.list_recent_for_user(user_id, 200)

  defp find_action(user_id, action) do
    Enum.find(events_for(user_id), &(&1.action == action))
  end

  defp actions_for(user_id), do: Enum.map(events_for(user_id), & &1.action)

  describe "conversation.created" do
    test "records the agent and how it was started", %{user: user, agent: agent} do
      stub_happy_sprite()

      {:ok, conv} =
        Launch.start_conversation(
          %{"agent_id" => agent.id, "user_id" => user.id, "source" => "ui"},
          actor: "ui"
        )

      event = find_action(user.id, "conversation.created")
      assert event.resource_type == "conversation"
      assert event.resource_id == conv.id
      assert event.actor == "ui"
      assert event.metadata["agent_id"] == agent.id
      assert event.metadata["agent_name"] == agent.name
      assert event.metadata["source"] == "ui"
      assert event.metadata["with_prompt"] == false

      _ = Termination.terminate_conversation(conv.id, audit: false)
    end

    test "an opening prompt is described, never quoted", %{user: user, agent: agent} do
      stub_happy_sprite()

      {:ok, conv} =
        Launch.start_conversation(%{
          "agent_id" => agent.id,
          "user_id" => user.id,
          "prompt" => "my private business plan, in detail"
        })

      event = find_action(user.id, "conversation.created")
      assert event.metadata["with_prompt"] == true

      for e <- events_for(user.id) do
        refute inspect(e) =~ "private business plan"
      end

      _ = Termination.terminate_conversation(conv.id, audit: false)
    end

    test "a refused start records nothing", %{user: user, agent: agent} do
      # At the sandbox cap: no conversation exists, so the trail must not
      # claim one was created.
      for _ <- 1..Fountain.Quotas.sandbox_limit(user.id),
          do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, _} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      refute "conversation.created" in actions_for(user.id)
    end
  end

  describe "conversation.terminated" do
    test "is recorded when the server is already gone", %{user: user, agent: agent} do
      # The dead-server branch still marks the rows terminated, so it is still
      # a termination and still belongs in the trail.
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox_id: sandbox.id)

      assert :ok = Termination.terminate_conversation(conv.id, actor: "ui")

      event = find_action(user.id, "conversation.terminated")
      assert event.resource_id == conv.id
      assert event.actor == "ui"
    end

    test "a terminate that changed nothing records nothing", %{user: user} do
      assert {:error, :not_running} =
               Termination.terminate_conversation(Ecto.UUID.generate())

      refute "conversation.terminated" in actions_for(user.id)
    end

    test "audit: false suppresses the row", %{user: user, agent: agent} do
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox_id: sandbox.id)

      assert :ok = Termination.terminate_conversation(conv.id, audit: false)

      refute "conversation.terminated" in actions_for(user.id)
    end
  end

  describe "conversation.deleted" do
    test "records the delete and not the cascade terminate", %{user: user, agent: agent} do
      # Deleting cascades through terminate. Two rows would read as though the
      # user stopped the conversation and then deleted it, which is not what
      # they did.
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          sandbox_id: sandbox.id,
          title: "notes"
        )

      {:ok, _} = Conversations.delete_conversation(conv, actor: "ui")

      event = find_action(user.id, "conversation.deleted")
      assert event.resource_id == conv.id
      assert event.actor == "ui"
      assert event.metadata["title"] == "notes"

      refute "conversation.terminated" in actions_for(user.id)
    end
  end

  describe "conversation.prompted" do
    test "records size and image count, never the text", %{user: user, agent: agent} do
      stub_happy_sprite()

      {:ok, conv} =
        Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      secret = "transfer the funds to account 12345"
      assert :ok = ConversationServer.send_prompt(conv.id, secret, [], actor: "ui")

      event = find_action(user.id, "conversation.prompted")
      assert event, "sending a prompt must be audited"
      assert event.actor == "ui"
      assert event.resource_id == conv.id
      assert event.metadata["prompt_bytes"] == byte_size(secret)
      assert event.metadata["image_count"] == 0

      # The whole point of recording a size instead of the prompt.
      for e <- events_for(user.id) do
        refute inspect(e) =~ "account 12345"
      end

      _ = Termination.terminate_conversation(conv.id, audit: false)
    end
  end

  describe "system callers" do
    test "a reaped sandbox attributes its terminations to the reaper", %{
      user: user,
      agent: agent
    } do
      stub_happy_sprite()

      {:ok, conv} =
        Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      {:ok, :terminated} = Termination.reap_sandbox(conv.sandbox_id)

      event = find_action(user.id, "conversation.terminated")
      assert event, "a reclaimed sandbox ends conversations the tenant did not stop"
      assert event.actor == "system:sandbox_reaper"
    end
  end

  describe "admin.sandbox.reaped (#2255 decision 4)" do
    test "reap_sandbox/2 with an admin_user_id leaves exactly one admin event", %{user: user} do
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      admin = insert_verified_user()

      assert {:ok, :released} = Termination.reap_sandbox(sandbox.id, admin_user_id: admin.id)

      admin_events =
        Enum.filter(
          Audit._unsafe_list_recent_admin(50),
          &(&1.event_type == "admin.sandbox.reaped" and &1.metadata["sandbox_id"] == sandbox.id)
        )

      assert [event] = admin_events
      assert event.actor_user_id == admin.id
      assert is_nil(event.target_user_id)
      assert event.metadata["outcome"] == "released"
    end

    test "reap_sandbox/1 with no admin_user_id leaves no admin event", %{user: user} do
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      assert {:ok, :released} = Termination.reap_sandbox(sandbox.id)

      refute Enum.any?(
               Audit._unsafe_list_recent_admin(50),
               &(&1.event_type == "admin.sandbox.reaped" and
                   &1.metadata["sandbox_id"] == sandbox.id)
             )
    end
  end
end
