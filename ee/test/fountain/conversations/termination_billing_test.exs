defmodule Fountain.Conversations.TerminationBillingTest do
  use Fountain.ConversationServerCase

  alias Fountain.Billing.SandboxUsage
  alias Fountain.Conversations.ExecutionGuard
  alias Fountain.Credits
  alias Fountain.Workers.CreditPricer

  for machine <- [:destroyed, :shared, :home], bounded <- [false, true] do
    @tag machine: machine, bounded: bounded
    test "terminating a running turn on a #{machine} machine (bounded: #{bounded}) retains its billable interval",
         %{
           machine: machine,
           bounded: bounded
         } do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "claude")
      started_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600)

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          inserted_at: started_at,
          mode: if(machine == :home, do: "persistent", else: "ephemeral")
        )

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      if machine == :shared do
        insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
      end

      stub_happy_sprite(sandbox.machine_name)
      command_ref = make_ref()
      owner = self()

      stub(Managoat.Sandbox.Sprites, :spawn, fn _, _, _, _ ->
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: command_ref}}
      end)

      stub(Managoat.Sandbox.Sprites, :write_stdin, fn _, _ -> :ok end)
      stub(Managoat.Sandbox.Sprites, :close_stdin, fn _ -> :ok end)
      stub(Managoat.Sandbox.Sprites, :stop_command, fn _ -> :ok end)

      stub(Managoat.Sandbox.Sprites, :destroy, fn _ ->
        send(owner, :destroyed)
        :ok
      end)

      {pid, monitor, :alive} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert :ok = GenServer.call(pid, {:send_prompt, "work", []})
      assert [%{status: "running"} = turn] = Conversations._unsafe_list_turns(conv.id)
      turn |> Ecto.Changeset.change(started_at: started_at) |> Repo.update!()

      if bounded do
        # Synthetic binding exercises journal retirement without claiming a
        # provider acknowledged termination of the remote command.
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
            "synthetic-command"
          )

        :sys.replace_state(pid, &%{&1 | turn_execution: execution})
      end

      assert :ok = GenServer.call(pid, {:terminate_conv, []})
      assert :normal = assert_stopped(monitor)
      ended = Repo.reload!(turn)
      assert ended.status == "interrupted"
      assert ended.orphaned_at == nil
      assert %DateTime{} = ended.ended_at
      assert Repo.reload!(conv).status == "terminated"

      if bounded do
        assert %{state: "ready", confirmed_at: nil, provider_session_id: "synthetic-command"} =
                 ExecutionGuard._unsafe_for_turn(turn.id)

        assert ExecutionGuard._unsafe_open_execution?(conv.id)
      end

      if machine == :destroyed do
        assert_received :destroyed
        assert Repo.reload!(sandbox).status == "terminated"
      else
        refute_received :destroyed
        assert Repo.reload!(sandbox).status == "ready"
      end

      seconds = DateTime.diff(ended.ended_at, started_at, :second)
      period_end = DateTime.add(ended.ended_at, 1)

      assert %{"sprites" => ^seconds} =
               SandboxUsage.turn_seconds_for_user(user.id, started_at, period_end)

      assert %{turns: 1} = CreditPricer.run(since: started_at, now: period_end)
      assert [burn] = Enum.filter(Credits.list_entries(user.id), &(&1.reason == "burn_turn"))
      assert burn.resource_id == turn.id
      assert burn.metadata["turn_seconds"] == seconds
      assert burn.idempotency_key == "burn_turn:#{turn.id}"
      assert %{turns: 0} = CreditPricer.run(since: started_at, now: period_end)
    end
  end

  test "reassignment during mid-turn teardown preserves the successor and old turn outcome" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    replacement = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    stub_happy_sprite(sandbox.machine_name)
    owner = self()

    stub(Managoat.Sandbox.Sprites, :spawn, fn _, _, _, _ ->
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: make_ref()}}
    end)

    stub(Managoat.Sandbox.Sprites, :write_stdin, fn _, _ -> :ok end)
    stub(Managoat.Sandbox.Sprites, :stop_command, fn _ -> :ok end)
    stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> :ok end)
    {pid, monitor, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert :ok = GenServer.call(pid, {:send_prompt, "work", []})
    assert [turn] = Conversations._unsafe_list_turns(conv.id)
    turn = Repo.reload!(turn)

    stub(Managoat.Sandbox.Sprites, :close_stdin, fn _ ->
      assert Repo.reload!(sandbox).transition == "destroying"

      {:ok, _} =
        Conversations.update_conversation(conv, %{sandbox_id: replacement.id, status: "running"})

      successor = insert_turn(conv, status: "running")
      send(owner, {:successor, successor})
      :ok
    end)

    assert {:error, :sandbox_unavailable} = GenServer.call(pid, {:terminate_conv, []})
    assert :normal = assert_stopped(monitor)
    assert_received {:successor, successor}
    assert Repo.reload!(turn) == turn
    assert Repo.reload!(successor) == successor
    assert %{sandbox_id: replacement_id, status: "running"} = Repo.reload!(conv)
    assert replacement_id == replacement.id
    assert Repo.reload!(replacement).status == "ready"
    refute Repo.reload!(replacement).transition == "destroying"
    assert Repo.reload!(sandbox).status == "terminated"
    assert %{turns: 0} = CreditPricer.run()
  end
end
