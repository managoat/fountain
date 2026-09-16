defmodule Fountain.Machines.MachineTest do
  @moduledoc """
  The read-only owner (ADR 0058 stage 4).

  `async: false`: the gate is application environment, and the process reads
  the repo from outside the test process, which needs the shared sandbox.
  """

  use Fountain.DataCase, async: false

  alias Fountain.Machines
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Occupancy

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "opencode")
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    a = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    b = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, agent: agent, sandbox: sandbox, a: a, b: b}
  end

  # An owner outliving its test would hold a checked-in sandbox connection and
  # stay registered under an id the next test may reuse. Its idle timer is a
  # minute by default, which is far longer than the suite.
  defp stop_machine(sandbox_id) do
    case Machine.whereis(sandbox_id) do
      nil -> :ok
      pid -> stop_and_await(pid)
    end
  end

  defp stop_and_await(pid) do
    ref = Process.monitor(pid)
    Horde.DynamicSupervisor.terminate_child(Fountain.MachineSupervisor, pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      2_000 -> Process.demonitor(ref, [:flush])
    end
  end

  defp with_gate(value, fun) do
    previous = Application.fetch_env(:fountain, :machine_owner_enabled)
    Application.put_env(:fountain, :machine_owner_enabled, value)

    try do
      fun.()
    after
      case previous do
        {:ok, was} -> Application.put_env(:fountain, :machine_owner_enabled, was)
        :error -> Application.delete_env(:fountain, :machine_owner_enabled)
      end
    end
  end

  describe "ensure_started/2 and whereis/1" do
    test "starts one owner and finds it again", ctx do
      assert Machine.whereis(ctx.sandbox.id) == nil

      assert {:ok, pid} = Machine.ensure_started(ctx.sandbox.id)
      assert Process.alive?(pid)
      assert Machine.whereis(ctx.sandbox.id) == pid
    end

    test "a second call returns the same pid rather than a second owner", ctx do
      assert {:ok, pid} = Machine.ensure_started(ctx.sandbox.id)
      assert {:ok, ^pid} = Machine.ensure_started(ctx.sandbox.id)
    end

    test "a concurrent start that loses the registry race still gets the winner", ctx do
      # `whereis/1` can miss a winner that is registered but not yet
      # propagated, so the start is attempted and comes back
      # `{:error, {:already_started, pid}}`. That is a success, not a failure.
      {:ok, winner} = Machine.ensure_started(ctx.sandbox.id)

      raced =
        Horde.DynamicSupervisor.start_child(
          Fountain.MachineSupervisor,
          {Machine, sandbox_id: ctx.sandbox.id}
        )

      assert {:error, {:already_started, ^winner}} = raced

      # And the shape ensure_started/2 turns that into.
      assert {:ok, ^winner} = Machine.ensure_started(ctx.sandbox.id)
    end

    test "different sandboxes get different owners", ctx do
      other = insert_sandbox(user_id: ctx.user.id, status: "ready")
      on_exit(fn -> stop_machine(other.id) end)

      {:ok, first} = Machine.ensure_started(ctx.sandbox.id)
      {:ok, second} = Machine.ensure_started(other.id)

      refute first == second
    end
  end

  describe "who_is_here/1" do
    test "answers exactly what Occupancy answers", ctx do
      insert_turn(ctx.b, %{
        status: "running",
        prompt: "go",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      with_gate(true, fn ->
        occupancy = Machine.who_is_here(ctx.sandbox.id)

        assert %Occupancy{} = occupancy
        assert Enum.sort(occupancy.bound) == Enum.sort([ctx.a.id, ctx.b.id])
        assert occupancy.running_turns == %{ctx.b.id => "opencode"}
        assert occupancy.live == []
        assert occupancy.last_activity_at

        direct = Occupancy.load(ctx.sandbox.id)
        assert occupancy.bound |> Enum.sort() == direct.bound |> Enum.sort()
        assert occupancy.running_turns == direct.running_turns
        assert occupancy.activity == direct.activity
      end)
    end

    test "with the gate on it is served by the owner", ctx do
      with_gate(true, fn ->
        assert Machine.whereis(ctx.sandbox.id) == nil
        assert %Occupancy{} = Machine.who_is_here(ctx.sandbox.id)
        assert is_pid(Machine.whereis(ctx.sandbox.id))
      end)
    end

    test "with the gate off it starts no process at all", ctx do
      with_gate(false, fn ->
        assert %Occupancy{} = occupancy = Machine.who_is_here(ctx.sandbox.id)
        assert Enum.sort(occupancy.bound) == Enum.sort([ctx.a.id, ctx.b.id])
        assert Machine.whereis(ctx.sandbox.id) == nil
      end)
    end

    test "the gate defaults to off", _ctx do
      refute Machines.enabled?()
    end
  end

  describe "idle-stop" do
    test "the owner stops itself after its idle window and comes back", ctx do
      {:ok, pid} = Machine.ensure_started(ctx.sandbox.id, idle_ms: 50)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert Machine.whereis(ctx.sandbox.id) == nil

      assert {:ok, revived} = Machine.ensure_started(ctx.sandbox.id)
      refute revived == pid
    end

    test "a question re-arms the window rather than letting it fire", ctx do
      {:ok, pid} = Machine.ensure_started(ctx.sandbox.id, idle_ms: 300)
      ref = Process.monitor(pid)

      # Four calls across more than one idle window. A timer that was not
      # re-armed — or a stale one that was not ignored — stops the process
      # somewhere in here.
      for _ <- 1..4 do
        Process.sleep(100)
        assert %Occupancy{} = GenServer.call(pid, :who_is_here)
      end

      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert Process.alive?(pid)
    end
  end
end
