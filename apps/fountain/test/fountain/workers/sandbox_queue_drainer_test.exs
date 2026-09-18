defmodule Fountain.Workers.SandboxQueueDrainerTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.SandboxQueue
  alias Fountain.SandboxQueue.Request
  alias Fountain.Workers.SandboxQueueDrainer

  defp enqueue!(user, agent) do
    {:ok, request} =
      SandboxQueue.enqueue(%{
        user_id: user.id,
        agent_id: agent.id,
        kind: "start",
        attrs: %{"prompt" => "hi"}
      })

    request
  end

  defp inert_start_child do
    stub_server_start(fn _supervisor, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)
  end

  describe "perform/1" do
    test "a tenant job drains that tenant's queue" do
      user = insert_active_user()
      request = enqueue!(user, insert_agent(user_id: user.id))
      inert_start_child()

      assert :ok = perform_job(SandboxQueueDrainer, %{"user_id" => user.id})
      assert Repo.get!(Request, request.id).status == "started"
    end

    test "the fan-out job pokes every tenant with live work" do
      user = insert_active_user()
      enqueue!(user, insert_agent(user_id: user.id))

      assert :ok = perform_job(SandboxQueueDrainer, %{"scope" => "all"})
      assert_enqueued(worker: SandboxQueueDrainer, args: %{user_id: user.id})
    end

    test "the cron backstop pokes every tenant with live work" do
      users = for _ <- 1..2, do: insert_active_user()
      for user <- users, do: enqueue!(user, insert_agent(user_id: user.id))

      assert :ok = perform_job(SandboxQueueDrainer, %{})

      for user <- users do
        assert_enqueued(worker: SandboxQueueDrainer, args: %{user_id: user.id})
      end
    end

    test "the fan-out skips a tenant whose only request already finished" do
      user = insert_active_user()
      request = enqueue!(user, insert_agent(user_id: user.id))
      {:ok, _} = SandboxQueue.cancel_request(request)

      assert :ok = perform_job(SandboxQueueDrainer, %{"scope" => "all"})
      refute_enqueued(worker: SandboxQueueDrainer, args: %{user_id: user.id})
    end
  end

  describe "the poke on a freed slot" do
    test "a slot-freeing transition schedules one fan-out, not one job per tenant" do
      owner = insert_verified_user()
      waiting = insert_verified_user()
      enqueue!(waiting, insert_agent(user_id: waiting.id))
      sandbox = insert_sandbox(user_id: owner.id, status: "ready")

      {:ok, _} = Fountain.Conversations.update_sandbox(sandbox, %{status: "terminated"})

      assert_enqueued(worker: SandboxQueueDrainer, args: %{scope: "all"})
      refute_enqueued(worker: SandboxQueueDrainer, args: %{user_id: waiting.id})

      # The tenant job is the fan-out job's work, not the caller's.
      assert :ok = perform_job(SandboxQueueDrainer, %{"scope" => "all"})
      assert_enqueued(worker: SandboxQueueDrainer, args: %{user_id: waiting.id})
    end

    test "a slot-freeing transition with an empty queue schedules nothing" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      {:ok, _} = Fountain.Conversations.update_sandbox(sandbox, %{status: "terminated"})

      refute_enqueued(worker: SandboxQueueDrainer)
    end

    test "a transition that frees nothing schedules nothing" do
      user = insert_verified_user()
      waiting = insert_verified_user()
      enqueue!(waiting, insert_agent(user_id: waiting.id))
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      # pending -> ready is still a cap-counting status on both sides.
      {:ok, _} = Fountain.Conversations.update_sandbox(sandbox, %{status: "ready"})

      refute_enqueued(worker: SandboxQueueDrainer)
    end

    test "parking a sandbox frees a slot and pokes" do
      user = insert_verified_user()
      waiting = insert_verified_user()
      enqueue!(waiting, insert_agent(user_id: waiting.id))
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      # `suspended` is deliberately outside `Quotas.active_statuses/0`, so a
      # park releases capacity exactly as a terminate does (ADR 0017).
      {:ok, _} = Fountain.Conversations.update_sandbox(sandbox, %{status: "suspended"})

      assert_enqueued(worker: SandboxQueueDrainer, args: %{scope: "all"})
    end

    test "a poke that raises never takes down the caller that freed the slot" do
      user = insert_verified_user()
      waiting = insert_verified_user()
      enqueue!(waiting, insert_agent(user_id: waiting.id))
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      stub(SandboxQueueDrainer, :poke_all_later, fn ->
        raise DBConnection.ConnectionError, "connection not available"
      end)

      assert {:ok, %{status: "terminated"}} =
               Fountain.Conversations.update_sandbox(sandbox, %{status: "terminated"})
    end
  end
end
