defmodule Fountain.Conversations.DeadlineEventsTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{ExecutionGuard, LogEvent, Turn, TurnExecution, TurnMachine}
  alias Fountain.Workers.TurnDeadlineNotification

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
    now = DateTime.utc_now()
    turn = insert_turn(conv, status: "running", started_at: DateTime.truncate(now, :second))
    deadline = DateTime.add(now, 60)

    {:ok, execution} =
      ExecutionGuard._unsafe_register(turn.id, Ecto.UUID.generate(), deadline, now: now)

    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")

    %{
      user: user,
      conv: conv,
      turn: turn,
      execution: execution,
      deadline: deadline
    }
  end

  defp expire(c), do: ExecutionGuard._unsafe_expire(c.execution.id, now: c.deadline)
  defp event(c), do: Repo.get_by!(LogEvent, turn_id: c.turn.id, stage: "turn")
  defp jobs(worker), do: all_enqueued(worker: worker)

  test "expiration commits its event and its notification without an actor", c do
    assert {:ok, _} = expire(c)
    event = event(c)
    assert event.state == "failed"
    assert Jason.decode!(event.data)["stop_reason"] == "wall_time_limit"
    assert Repo.get!(Turn, c.turn.id).limit_reason == "wall_time_limit"
    assert Repo.get!(TurnExecution, c.execution.id).deadline_event_id == event.id
    assert [notification] = jobs(TurnDeadlineNotification)
    assert notification.args["user_id"] == c.user.id
    refute_received {:log_event, _}

    assert :ok = perform_job(TurnDeadlineNotification, notification.args)
    assert_received {:log_event, ^event}
  end

  test "rollback cannot leave a failed turn without its event or notification", c do
    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} = expire(c)
               Repo.rollback(:abort)
             end)

    assert Repo.get!(Turn, c.turn.id).status == "running"
    assert Repo.get!(TurnExecution, c.execution.id).state == "active"
    assert Repo.get!(TurnExecution, c.execution.id).deadline_event_id == nil
    assert Repo.aggregate(LogEvent, :count) == 0
    assert jobs(TurnDeadlineNotification) == []
    refute_received {:log_event, _}
  end

  test "a retried notification reuses its id without adding events", c do
    expire(c)
    event = event(c)
    [job] = jobs(TurnDeadlineNotification)

    for _ <- 1..2 do
      assert :ok = perform_job(TurnDeadlineNotification, job.args)
      assert_received {:log_event, ^event}
    end

    assert Repo.aggregate(LogEvent, :count) == 1
  end

  test "a notification failure leaves the durable event available for a retry", c do
    expire(c)
    [job] = jobs(TurnDeadlineNotification)
    expect(Conversations, :_unsafe_notify_stage, fn _ -> raise "notification unavailable" end)

    assert_raise RuntimeError, "notification unavailable", fn ->
      perform_job(TurnDeadlineNotification, job.args)
    end

    assert event(c).state == "failed"
    assert [_] = jobs(TurnDeadlineNotification)

    expect(Conversations, :_unsafe_notify_stage, fn event ->
      Mimic.call_original(Conversations, :_unsafe_notify_stage, [event])
    end)

    assert :ok = perform_job(TurnDeadlineNotification, job.args)
    assert_received {:log_event, %{state: "failed"}}
  end

  test "late completion and interruption cannot replace or duplicate the deadline event", c do
    expire(c)
    original = event(c)

    machine = %TurnMachine{
      conversation_id: c.conv.id,
      sandbox_id: c.conv.sandbox_id,
      row: c.turn
    }

    TurnMachine.finish(machine, "completed", %{}, %{stop_reason: "end_turn"})
    TurnMachine.mark_interrupted(machine)
    expire(c)

    assert Conversations.publish_stage(c.conv.id, "turn", "done", %{"turn_id" => c.turn.id}) ==
             original

    assert event(c) == original
    assert Repo.aggregate(LogEvent, :count) == 1
    assert [_] = jobs(TurnDeadlineNotification)
    refute_received {:log_event, _}
  end

  test "retention cannot authorize a contradictory replacement event", c do
    expire(c)
    original = event(c)
    Repo.delete!(original)

    assert Conversations.publish_stage(c.conv.id, "turn", "done", %{turn_id: c.turn.id}) == nil
    assert Repo.aggregate(LogEvent, :count) == 0
    assert Repo.get!(TurnExecution, c.execution.id).deadline_event_id == original.id
    [job] = jobs(TurnDeadlineNotification)
    assert :ok = perform_job(TurnDeadlineNotification, job.args)
    refute_received {:log_event, _}
  end

  test "a notification cannot cross its recorded tenant boundary", c do
    expire(c)
    [job] = jobs(TurnDeadlineNotification)
    args = Map.put(job.args, "user_id", insert_verified_user().id)
    assert :ok = perform_job(TurnDeadlineNotification, args)
    refute_received {:log_event, _}
  end

  test "a deleted turn cannot acquire a late terminal event", c do
    Repo.delete!(c.turn)
    assert Conversations.publish_stage(c.conv.id, "turn", "done", %{turn_id: c.turn.id}) == nil
    assert Repo.aggregate(LogEvent, :count) == 0
    assert Repo.get!(TurnExecution, c.execution.id).state == "active"
  end

  test "malformed retained metadata does not lose the committed stage notification", c do
    expire(c)
    event = event(c)
    Repo.update_all(from(e in LogEvent, where: e.id == ^event.id), set: [data: "[REDACTED]"])
    [job] = jobs(TurnDeadlineNotification)
    assert :ok = perform_job(TurnDeadlineNotification, job.args)
    assert_received {:log_event, %{id: id, state: "failed", data: "[REDACTED]"}}
    assert id == event.id
  end

  test "the notification runs on its own queue with bounded retries", c do
    assert {:ok, _} = expire(c)
    assert [notification] = jobs(TurnDeadlineNotification)

    # Retries are bounded: the event is durable, so re-pushing it to live
    # subscribers twenty times buys nothing.
    assert notification.queue == "notifications"
    assert notification.max_attempts == 3
  end

  test "a conversation that changed hands is not published on, and says so", c do
    other = insert_verified_user()
    c.conv |> change(user_id: other.id) |> Repo.update!()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = expire(c)
      end)

    # Suppressing the outcome is right; doing it silently is not. Nothing else
    # in the system knows a persisted deadline reached nobody.
    assert log =~ "not recorded"
    assert log =~ c.turn.id
    assert Repo.get!(TurnExecution, c.execution.id).deadline_event_id == nil
    assert jobs(TurnDeadlineNotification) == []
  end

  test "a deleted transcript makes the notification a logged no-op, not a crash", c do
    assert {:ok, _} = expire(c)
    assert [notification] = jobs(TurnDeadlineNotification)
    Repo.delete_all(LogEvent)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = perform_job(TurnDeadlineNotification, notification.args)
      end)

    assert log =~ "skipped"
    refute_received {:log_event, _}
  end
end
