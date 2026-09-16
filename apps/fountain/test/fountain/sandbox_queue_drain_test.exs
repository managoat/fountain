defmodule Fountain.SandboxQueueDrainTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.SandboxQueue
  alias Fountain.SandboxQueue.Request

  defp enqueue!(user, agent, extra \\ %{}) do
    {:ok, request} =
      SandboxQueue.enqueue(
        Map.merge(
          %{user_id: user.id, agent_id: agent.id, kind: "start", attrs: %{"prompt" => "hi"}},
          extra
        )
      )

    request
  end

  defp queue_events(user) do
    user.id
    |> Fountain.Audit.list_recent_for_user(50)
    |> Enum.filter(&String.starts_with?(&1.action, "sandbox_request."))
  end

  defp queue_actions(user), do: queue_events(user) |> Enum.map(& &1.action)

  defp fill_tenant_cap(user) do
    for _ <- 1..Fountain.Quotas.sandbox_limit(user.id),
        do: insert_sandbox(user_id: user.id, status: "ready")
  end

  defp fill_fleet do
    hog = insert_verified_user(sandbox_limit_override: 100)

    for _ <- 1..Fountain.Quotas.settings().fleet_ceiling,
        do: insert_sandbox(user_id: hog.id, status: "ready")
  end

  # A persistent agent whose home is still building: a start for it reads
  # `{:error, :provisioning}`, the transient shape the drain must not treat as
  # terminal.
  defp agent_mid_provision(user) do
    agent = insert_agent(user_id: user.id, sandbox_mode: "persistent")
    insert_sandbox(user_id: user.id, agent_id: agent.id, mode: "persistent", status: "pending")
    agent
  end

  # A persistent agent whose home is up but held: an owner is between its
  # intent and its finalize, so a start for it reads `{:error,
  # :sandbox_unavailable}` (ADR 0058 stage 6a) — the other transient shape.
  defp agent_mid_operation(user) do
    agent = insert_agent(user_id: user.id, sandbox_mode: "persistent")

    insert_sandbox(
      user_id: user.id,
      agent_id: agent.id,
      environment_id: agent.environment_id,
      mode: "persistent",
      status: "ready"
    )
    |> Ecto.Changeset.change(
      transition: "parking",
      lease_epoch: 1,
      lease_node: "fountain@other",
      lease_until: DateTime.add(DateTime.utc_now(), 30_000, :millisecond)
    )
    |> Repo.update!()

    agent
  end

  # The conversation row and the sandbox reservation are what this module is
  # about; the runtime behind them is not. Stubbing the supervisor keeps the
  # replay a database fact rather than a provisioning race.
  defp inert_start_child do
    stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)
  end

  describe "drain/1" do
    test "starts work, links the conversation and erases queued attributes" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)
      inert_start_child()

      assert %{started: 1, failed: 0, expired: 0} = SandboxQueue.drain(user.id)

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "started"
      assert reloaded.attrs == %{}
      assert Fountain.Conversations.get_conversation(reloaded.conversation_id, user.id)
    end

    test "an empty queue is a no-op" do
      user = insert_active_user()
      assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(user.id)
    end

    test "leaves a request waiting at the tenant cap" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      fill_tenant_cap(user)
      request = enqueue!(user, agent)

      assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, request.id).status == "queued"
    end

    test "leaves a request waiting at the fleet ceiling" do
      fill_fleet()
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, request.id).status == "queued"
    end

    test "a capacity refusal stops the pass instead of walking the whole queue" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      fill_tenant_cap(user)
      first = enqueue!(user, agent)
      second = enqueue!(user, agent)

      assert %{started: 0, failed: 0} = SandboxQueue.drain(user.id)

      # Both still waiting, and the one in front kept its place: every request
      # behind it would have met the same wall.
      assert Repo.get!(Request, first.id).status == "queued"
      assert Repo.get!(Request, second.id).status == "queued"
      assert SandboxQueue.position(Repo.get!(Request, first.id)) == 1
    end

    test "a request that lost its funding fails terminally and erases its prompt" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      {:ok, _} =
        Fountain.Credits.debit(
          user.id,
          Fountain.Credits.balance(user.id) + 1,
          "burn_turn",
          idempotency_key: "queue-#{request.id}"
        )

      assert %{started: 0, failed: 1, expired: 0} = SandboxQueue.drain(user.id)

      assert %{status: "failed", error: "insufficient_credits", attrs: %{}} =
               Repo.get!(Request, request.id)
    end

    test "fails broken work without head-of-line blocking the next request" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      inert_start_child()

      # A schedule id that names nothing: the replay reads :schedule_deleted,
      # which is terminal.
      {:ok, broken} =
        SandboxQueue.enqueue(%{
          user_id: user.id,
          agent_id: agent.id,
          kind: "schedule_run",
          schedule_id: Ecto.UUID.generate()
        })

      alive = enqueue!(user, agent)

      assert %{started: 1, failed: 1, expired: 0} = SandboxQueue.drain(user.id)
      assert %{status: "failed", error: "schedule_deleted"} = Repo.get!(Request, broken.id)
      assert Repo.get!(Request, alive.id).status == "started"
    end

    test "a transient failure goes back in line instead of burning the prompt" do
      user = insert_active_user()
      agent = agent_mid_provision(user)
      request = enqueue!(user, agent)

      assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(user.id)

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "queued"
      assert reloaded.error == nil
      assert reloaded.attrs["prompt"] == "hi"
    end

    test "a machine its owner is mid-operation on goes back in line too" do
      # ADR 0058 stage 6a: a start that lands on a home its owner is parking,
      # destroying or rebuilding answers `:sandbox_unavailable`, which clears by
      # itself in one provider round trip. Before 6a added it to
      # `@transient_errors` this burned the prompt on a condition that had
      # already passed.
      user = insert_active_user()
      request = enqueue!(user, agent_mid_operation(user))

      assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(user.id)

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "queued"
      assert reloaded.error == nil
      assert reloaded.attrs["prompt"] == "hi"
    end

    test "a transient failure does not block the request behind it" do
      user = insert_active_user()
      waiting = enqueue!(user, agent_mid_provision(user))
      alive = enqueue!(user, insert_agent(user_id: user.id))
      inert_start_child()

      assert %{started: 1, failed: 0, expired: 0} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, waiting.id).status == "queued"
      assert Repo.get!(Request, alive.id).status == "started"
    end

    test "records the outcome it wrote, attributed to the queue" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)
      inert_start_child()

      assert %{started: 1} = SandboxQueue.drain(user.id)

      assert event = Enum.find(queue_events(user), &(&1.action == "sandbox_request.started"))
      assert event.actor == "system:sandbox_queue"
      assert event.resource_type == "sandbox_request"
      assert event.resource_id == request.id
      assert event.metadata["conversation_id"] == Repo.get!(Request, request.id).conversation_id
      # Provenance and an outcome, never the prompt (ADR 0013).
      refute Map.has_key?(event.metadata, "prompt")
    end

    test "records a terminal failure with the reason, not the prompt" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      {:ok, _} =
        Fountain.Credits.debit(
          user.id,
          Fountain.Credits.balance(user.id) + 1,
          "burn_turn",
          idempotency_key: "queue-#{request.id}"
        )

      assert %{failed: 1} = SandboxQueue.drain(user.id)

      assert event = Enum.find(queue_events(user), &(&1.action == "sandbox_request.failed"))
      assert event.actor == "system:sandbox_queue"
      assert event.metadata["error"] == "insufficient_credits"
      refute Map.has_key?(event.metadata, "prompt")
    end

    test "a release records nothing, because the request is still waiting" do
      user = insert_active_user()
      request = enqueue!(user, agent_mid_provision(user))

      assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(user.id)

      # A transient release is an attempt, not a change. Only the enqueue
      # happened, so only the enqueue is on the trail (ADR 0013).
      assert queue_actions(user) == ["sandbox_request.enqueued"]
      assert Repo.get!(Request, request.id).status == "queued"
    end

    test "expires overdue work and erases its prompt" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      {1, _} =
        Repo.update_all(from(r in Request, where: r.id == ^request.id),
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -2, :hour)]
        )

      assert %{started: 0, failed: 0, expired: 1} = SandboxQueue.drain(user.id)
      assert %{status: "expired", attrs: %{}} = Repo.get!(Request, request.id)

      assert event = Enum.find(queue_events(user), &(&1.action == "sandbox_request.expired"))
      assert event.actor == "system:sandbox_queue"
      assert event.resource_id == request.id
    end
  end

  describe "what the door passed survives the replay" do
    test "keeps the provenance the API inferred instead of defaulting to api" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      inert_start_child()

      # A sandbox fan-out: `infer_provenance/1` reads the parent-conversation
      # header and records `agent`. The request stores it in its own column, so
      # the replay has to put it back — `start_conversation/2` defaults
      # `attrs["source"] || "api"` and would otherwise relabel the fan-out as a
      # plain API start.
      request = enqueue!(user, agent, %{source: "agent"})

      assert %{started: 1} = SandboxQueue.drain(user.id)

      conversation_id = Repo.get!(Request, request.id).conversation_id
      assert Fountain.Conversations.get_conversation(conversation_id, user.id).source == "agent"
    end

    test "holds a sprite token to the conversation it owns (ADR 0045)" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      inert_start_child()

      # The conversation this channel is bound to belongs to another sandbox's
      # token, and `labels` on a `channel_id` resume is a write to it. The door
      # refuses that with `sandbox_key_id` in hand; the replay has to refuse it
      # too, an hour later, or the queue is a way around the rule.
      {their_key, _} = insert_sprite_api_key(user)
      {our_key, _} = insert_sprite_api_key(user)

      theirs =
        insert_conversation(
          user_id: user.id,
          agent_id: agent.id,
          channel_id: "fountain:team",
          callback_api_key_id: their_key.id
        )

      request =
        enqueue!(user, agent, %{
          sandbox_key_id: our_key.id,
          attrs: %{"channel_id" => "fountain:team", "labels" => %{"owner" => "someone-else"}}
        })

      assert %{failed: 1} = SandboxQueue.drain(user.id)

      assert %{status: "failed", error: error} = Repo.get!(Request, request.id)
      assert error == "sprite_may_not_label_another_conversation"
      assert Fountain.Conversations.get_conversation(theirs.id, user.id).labels == %{}
    end

    test "a request with no sandbox restriction still resumes and labels" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      inert_start_child()

      {their_key, _} = insert_sprite_api_key(user)

      theirs =
        insert_conversation(
          user_id: user.id,
          agent_id: agent.id,
          channel_id: "fountain:team",
          callback_api_key_id: their_key.id
        )

      # The owner's own credential carries no restriction, and the guard reads
      # that as "may label any conversation it can already fetch". Pinned so
      # the fix above cannot quietly become a blanket refusal.
      request =
        enqueue!(user, agent, %{
          attrs: %{"channel_id" => "fountain:team", "labels" => %{"owner" => "me"}}
        })

      assert %{started: 1} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, request.id).conversation_id == theirs.id

      assert Fountain.Conversations.get_conversation(theirs.id, user.id).labels == %{
               "owner" => "me"
             }
    end
  end

  describe "the claim" do
    test "recovers a claim abandoned by a dead worker" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)
      inert_start_child()

      {1, _} =
        Repo.update_all(from(r in Request, where: r.id == ^request.id),
          set: [
            status: "starting",
            updated_at: DateTime.add(DateTime.utc_now(), -10, :minute)
          ]
        )

      assert %{started: 1, failed: 0, expired: 0} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, request.id).status == "started"
    end

    test "leaves a claim that is still within its timeout alone" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      {1, _} =
        Repo.update_all(from(r in Request, where: r.id == ^request.id),
          set: [status: "starting", updated_at: DateTime.utc_now()]
        )

      assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, request.id).status == "starting"
    end

    test "a claim recovered mid-replay does not have its outcome overwritten" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)
      inert_start_child()

      # A replay that outran its claim timeout loses the row to a recovering
      # drain, which may already have replayed and finished it. Injected at
      # the last gate before the start returns, and moved to a terminal status
      # so this pass cannot simply take it back.
      #
      # The blind `Repo.update/1` this fence replaced would write "started"
      # and the loser's conversation id over the winner's row, so one request
      # would read as one conversation while two were running.
      stub(Fountain.Billing, :check_spend, fn user_id ->
        Repo.update_all(from(r in Request, where: r.id == ^request.id),
          set: [status: "cancelled", updated_at: DateTime.utc_now()]
        )

        Fountain.Credits.gate(user_id)
      end)

      assert %{started: 1, failed: 0, expired: 0} = SandboxQueue.drain(user.id)

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "cancelled"
      assert reloaded.conversation_id == nil
    end

    test "a claim lost before release leaves the recovering drain's row alone" do
      user = insert_active_user()
      agent = agent_mid_provision(user)
      request = enqueue!(user, agent)

      stub(Fountain.Billing, :check_spend, fn user_id ->
        Repo.update_all(from(r in Request, where: r.id == ^request.id),
          set: [status: "cancelled", updated_at: DateTime.utc_now()]
        )

        Fountain.Credits.gate(user_id)
      end)

      assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, request.id).status == "cancelled"
    end
  end

  describe "the fan-out reads" do
    test "any_active_requests? sees waiting and claimed work only" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      refute SandboxQueue.any_active_requests?()

      request = enqueue!(user, agent)
      assert SandboxQueue.any_active_requests?()

      {:ok, _} = SandboxQueue.cancel_request(request)
      refute SandboxQueue.any_active_requests?()
    end

    test "user_ids_with_active_requests lists each tenant once" do
      user = insert_active_user()
      other = insert_active_user()
      agent = insert_agent(user_id: user.id)
      enqueue!(user, agent)
      enqueue!(user, agent)
      enqueue!(other, insert_agent(user_id: other.id))

      assert Enum.sort(SandboxQueue.user_ids_with_active_requests()) ==
               Enum.sort([user.id, other.id])
    end
  end
end
