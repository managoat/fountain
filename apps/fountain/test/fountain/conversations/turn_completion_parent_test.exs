defmodule Fountain.Conversations.TurnCompletionParentTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.TurnMachine

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
    turn = insert_turn(conv, status: "running", started_at: DateTime.utc_now())
    %{conv: conv, turn: turn, sandbox: sandbox}
  end

  defp finish(c),
    do:
      TurnMachine.finish(
        %TurnMachine{conversation_id: c.conv.id, sandbox_id: c.sandbox.id, row: c.turn},
        "completed",
        %{},
        %{}
      )

  defp stages(c),
    do: Conversations._unsafe_list_log_events(c.conv.id) |> Enum.filter(&(&1.stage == "turn"))

  test "success commits the turn, its reply and the idle parent together", c do
    insert_log_event(c.conv,
      turn_id: c.turn.id,
      stream: "acp",
      data:
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"reply"}}}})
    )

    assert {:ok, ended} =
             Conversations._unsafe_complete_turn(c.turn, c.sandbox.id, "completed", exit_code: 0)

    assert ended.status == "completed"
    assert ended.reply_text == "reply"
    assert ended.exit_code == 0
    assert Repo.reload!(c.conv).status == "idle"
  end

  test "successful waiting completion preserves its detached request metadata", c do
    pending = %{"request_id" => "approval-2054", "tool" => "Bash"}
    c.turn |> Ecto.Changeset.change(waiting: true, pending_permission: pending) |> Repo.update!()

    finish(c)

    assert %{status: "completed", waiting: true, pending_permission: ^pending} =
             Repo.reload!(c.turn)

    assert Repo.reload!(c.conv).status == "idle"
    assert [%{state: "done", data: data}] = stages(c)
    assert %{"waiting" => true, "waiting_request_id" => "approval-2054"} = Jason.decode!(data)
  end

  test "an already-ended latest turn releases its parent without announcing again", c do
    c.turn
    |> Ecto.Changeset.change(
      status: "interrupted",
      ended_at: DateTime.truncate(DateTime.utc_now(), :second)
    )
    |> Repo.update!()

    ended = Repo.reload!(c.turn)
    assert :noop = Conversations._unsafe_complete_turn(c.turn, c.sandbox.id, "completed")
    assert Repo.reload!(c.turn) == ended
    assert Repo.reload!(c.conv).status == "idle"
    assert stages(c) == []
  end

  test "a rebound actor cannot end the turn or write its reply", c do
    replacement = insert_sandbox(user_id: c.conv.user_id, status: "ready")
    c.conv |> Ecto.Changeset.change(sandbox_id: replacement.id) |> Repo.update!()
    assert :noop = Conversations._unsafe_complete_turn(c.turn, c.sandbox.id, "completed")
    assert Repo.reload!(c.turn).status == "running"
    assert Repo.reload!(c.conv).status == "running"
  end
end
