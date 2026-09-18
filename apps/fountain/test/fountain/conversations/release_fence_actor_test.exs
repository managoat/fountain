defmodule Fountain.Conversations.ReleaseFenceActorTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.ExecutionGuard

  for gate <- [false, true] do
    @tag gate: gate
    test "a stale actor cannot release its idle replacement with machine owner #{gate}", %{
      gate: gate
    } do
      previous = Application.fetch_env(:fountain, :machine_owner_enabled)
      Application.put_env(:fountain, :machine_owner_enabled, gate)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:fountain, :machine_owner_enabled, value)
          :error -> Application.delete_env(:fountain, :machine_owner_enabled)
        end
      end)

      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      replacement = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      stub_happy_sprite(sandbox.machine_name)
      {pid, _monitor, :alive} = start_server(conv)
      before = :sys.get_state(pid)
      assert before.sandbox_id == sandbox.id
      assert is_nil(before.current_turn)

      {:ok, _} =
        Conversations.update_conversation(conv, %{sandbox_id: replacement.id, status: "idle"})

      parent = Repo.reload!(conv)
      key = Repo.get!(Fountain.Accounts.ApiKey, parent.callback_api_key_id)
      events = Conversations._unsafe_list_log_events(conv.id)

      result = GenServer.call(pid, :release_conv)
      # Check durable replacement ownership before the reply: a stale actor
      # used to answer :ok and terminate this idle parent on another machine.
      assert Repo.reload!(conv).sandbox_id == replacement.id
      assert Repo.reload!(conv).status == "idle"
      assert result == {:error, :ownership_changed}
      assert :sys.get_state(pid) == before
      assert Repo.reload!(key) == key
      assert Conversations._unsafe_list_log_events(conv.id) == events
      assert Repo.reload!(sandbox).status == "ready"
      assert Repo.reload!(replacement) == replacement
    end
  end

  test "an idle actor refuses unresolved remote work before closing anything" do
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
    {:ok, _} = ExecutionGuard._unsafe_interrupt(conv.id)
    before = :sys.get_state(pid)
    assert is_nil(before.current_turn)
    parent = Conversations._unsafe_get_conversation!(conv.id)
    key = Repo.get!(Fountain.Accounts.ApiKey, parent.callback_api_key_id)
    events = Conversations._unsafe_list_log_events(conv.id)

    assert {:error, :execution_fenced} = GenServer.call(pid, :release_conv)
    assert :sys.get_state(pid) == before
    assert Conversations._unsafe_get_conversation!(conv.id) == parent
    assert Repo.reload!(key) == key
    assert Conversations._unsafe_list_log_events(conv.id) == events
    assert ExecutionGuard._unsafe_for_turn(turn.id).state == "awaiting_identity"
    assert Repo.reload!(sandbox).status == "ready"
  end
end
