defmodule Fountain.Conversations.WakeRaceTest do
  @moduledoc """
  Waking a dormant conversation races: two prompts a second apart, a Horde
  registry that has not caught up, and both callers decide to provision.

  The loser used to leave the conversation pointing at the sandbox it had just
  terminated (#717) — because the row was repointed *before* the server was
  started, and the losing branch cleaned up its row without undoing that. The
  conversation then read as `terminated` through the API and the UI while the
  winner served turns on a different sandbox, and prod accumulated orphan
  `ready` rows nothing referenced.

  These pin each branch: what the row points at, and what is left holding a
  quota slot.
  """
  use Fountain.DataCase, async: false

  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Wake

  setup :set_mimic_global

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    old_sandbox = insert_sandbox(user_id: user.id, status: "terminated")

    conv =
      insert_conversation(
        user_id: user.id,
        agent_id: agent.id,
        sandbox_id: old_sandbox.id,
        status: "idle"
      )

    {:ok, user: user, agent: agent, conv: conv, old_sandbox: old_sandbox}
  end

  defp sandbox_of(conv_id) do
    conv_id |> Conversations._unsafe_get_conversation!() |> Fountain.Repo.preload(:sandbox)
  end

  defp sandbox_ids do
    Fountain.Conversations.Sandbox |> Fountain.Repo.all() |> MapSet.new(& &1.id)
  end

  # Only the rows this wake created — the factory makes its own, and counting
  # those was how the first version of this test failed against a working fix.
  defp sandboxes_created_since(before) do
    Fountain.Conversations.Sandbox
    |> Fountain.Repo.all()
    |> Enum.reject(&MapSet.member?(before, &1.id))
  end

  describe "when the wake wins the race" do
    test "the conversation points at the new sandbox", %{conv: conv, old_sandbox: old} do
      stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      stub(ConversationServer, :queue_initial_prompt, fn _pid, _prompt, _images -> :ok end)

      {:ok, _} = Wake.wake_conversation(conv.id, "hello")

      woken = sandbox_of(conv.id)
      refute woken.sandbox_id == old.id, "the row still names the retired sandbox"
      assert woken.sandbox.status != "terminated", "the row names a terminated sandbox"
    end
  end

  describe "when the wake loses the race" do
    setup do
      winner = spawn(fn -> Process.sleep(:infinity) end)

      stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
        {:error, {:already_started, winner}}
      end)

      stub(ConversationServer, :queue_initial_prompt, fn _pid, _prompt, _images -> :ok end)

      {:ok, winner: winner}
    end

    # The regression. The winner owns the conversation; the loser must not
    # repoint the row at a sandbox it is about to terminate.
    test "the conversation is left pointing where it was", %{conv: conv, old_sandbox: old} do
      {:ok, _} = Wake.wake_conversation(conv.id, "hello")

      assert sandbox_of(conv.id).sandbox_id == old.id,
             "the loser repointed the conversation at its own sandbox"
    end

    test "the loser's own sandbox is retired rather than left holding a quota slot", %{
      conv: conv
    } do
      before = sandbox_ids()

      {:ok, _} = Wake.wake_conversation(conv.id, "hello")

      created = sandboxes_created_since(before)
      assert created != [], "expected the loser to have created a sandbox row"

      for sandbox <- created do
        assert sandbox.status == "terminated",
               "a losing wake left #{sandbox.machine_name} in #{sandbox.status}"
      end
    end

    test "the prompt is handed to the winner", %{conv: conv, winner: winner} do
      test_pid = self()

      stub(ConversationServer, :queue_initial_prompt, fn pid, prompt, _images ->
        send(test_pid, {:queued, pid, prompt})
        :ok
      end)

      {:ok, _} = Wake.wake_conversation(conv.id, "hello")

      assert_receive {:queued, ^winner, "hello"}
    end
  end

  describe "when the start fails outright" do
    test "the unused sandbox does not keep a quota slot", %{conv: conv} do
      stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec -> {:error, :boom} end)

      before = sandbox_ids()

      assert {:error, :boom} = Wake.wake_conversation(conv.id, "hello")

      for sandbox <- sandboxes_created_since(before) do
        assert sandbox.status == "terminated",
               "a failed wake left #{sandbox.machine_name} in #{sandbox.status}"
      end
    end
  end
end
