defmodule Fountain.Conversations.TurnParentActorTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.{ExecutionGuard, Turn, TurnExecution}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    stub_happy_sprite(sandbox.machine_name)
    {pid, _monitor, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    turn = insert_turn(conv, status: "running")

    {:ok, execution} =
      ExecutionGuard._unsafe_register(
        turn.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

    {:ok, execution} =
      ExecutionGuard._unsafe_bind_identity(
        execution.id,
        execution.connection_id,
        "old-synthetic-command"
      )

    {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})
    ref = make_ref()

    :sys.replace_state(pid, fn state ->
      %{state | current_turn: turn, current_command_ref: ref, turn_execution: execution}
    end)

    %{pid: pid, turn: turn, execution: execution, conv: conv, ref: ref}
  end

  test "cancellation and successor admission after dispatch cannot let the old actor idle the parent",
       %{pid: pid, turn: turn, execution: execution, conv: conv, ref: ref} do
    test = self()

    # The barrier sits on the terminal writer the completion path actually
    # uses. `finish/4` routes its write through `Machine.end_turn/3` and so
    # `_unsafe_complete_turn/4` (#1999, ADR 0058 stage 8a), so stubbing
    # `_unsafe_update_turn/2` here would hold nothing open and the race this
    # test asserts on would never be arranged.
    stub(Conversations, :_unsafe_complete_turn, fn row, sandbox_id, status, opts ->
      if self() == pid and row.id == turn.id do
        send(test, :after_dispatch_before_write)

        receive do
          :continue -> :ok
        after
          5_000 -> flunk("callback barrier timed out")
        end
      end

      Mimic.call_original(Conversations, :_unsafe_complete_turn, [row, sandbox_id, status, opts])
    end)

    send(pid, {:acp, ref, {:done, "end_turn", nil}})
    assert_receive :after_dispatch_before_write, 2_000
    {:ok, _} = ExecutionGuard._unsafe_interrupt(conv.id)

    {:ok, %{permitted: true, execution: claimed}} =
      ExecutionGuard._unsafe_claim_termination(execution.id)

    # Synthetic provider acknowledgment permits a successor. This test performs
    # no remote termination and makes no claim about actual command deletion.
    {:ok, _} = ExecutionGuard._unsafe_record_termination(execution.id, claimed.attempt_id, :ok)
    next = insert_turn(conv, status: "running")

    {:ok, next_execution} =
      ExecutionGuard._unsafe_register(
        next.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    send(pid, :continue)
    assert %{current_turn: nil} = :sys.get_state(pid)
    # Two guards refuse this write independently — the turn is already
    # `interrupted`, and a successor holds the highest `turn_number` — so the
    # parent assertion below survives either one alone. Asserting the old
    # turn's own result too puts the turn-status guard on the hook by itself:
    # drop it and the late `completed` lands here even though the parent is
    # still correctly held `running` by `latest_turn?`.
    assert Repo.get!(Turn, turn.id).status == "interrupted"
    assert Conversations._unsafe_get_conversation!(conv.id).status == "running"
    assert Repo.get!(Turn, next.id).status == "running"
    assert Repo.get!(TurnExecution, next_execution.id).state == "active"
  end

  test "a session callback passed by dispatch cannot overwrite a successor after cancellation",
       c do
    test = self()
    :sys.replace_state(c.pid, &%{&1 | runtime_session_id: "original"})

    stub(Conversations, :_unsafe_set_turn_session, fn row, session ->
      if self() == c.pid and row.id == c.turn.id do
        send(test, :session_after_dispatch)

        receive do
          :continue -> :ok
        after
          5_000 -> flunk("session barrier timed out")
        end
      end

      Mimic.call_original(Conversations, :_unsafe_set_turn_session, [row, session])
    end)

    send(c.pid, {:acp, c.ref, {:session, "late"}})
    assert_receive :session_after_dispatch, 2_000
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    {:ok, %{execution: claimed}} = ExecutionGuard._unsafe_claim_termination(c.execution.id)
    {:ok, _} = ExecutionGuard._unsafe_record_termination(c.execution.id, claimed.attempt_id, :ok)
    next = insert_turn(c.conv, status: "running")

    {:ok, _} =
      ExecutionGuard._unsafe_register(
        next.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    {:ok, _} = Conversations.update_conversation(c.conv, %{runtime_session_id: "successor"})
    send(c.pid, :continue)
    assert %{runtime_session_id: "original"} = :sys.get_state(c.pid)
    assert Conversations._unsafe_get_conversation!(c.conv.id).runtime_session_id == "successor"
  end
end
