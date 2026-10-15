defmodule Managoat.Sandbox.FakeTerminationTest do
  use ExUnit.Case, async: false

  alias Managoat.Sandbox.Fake

  setup do
    Fake.reset()
    on_exit(fn -> Fake.reset() end)
    {:ok, worker} = Fake.create("worker", [])
    %{worker: worker}
  end

  defp start(worker, name) do
    {:ok, command} = Fake.spawn(worker, name, ["out:ready", "stay"], owner: self())
    ref = command.ref
    assert_receive {:stdout, %{ref: ^ref}, "ready"}
    {:ok, sessions} = Fake.list_sessions(worker)
    id = Enum.find(sessions, &(&1.command == "#{name} out:ready stay")).id
    {command, id}
  end

  test "local detach leaves the remote session alive; termination stops only that session", %{
    worker: worker
  } do
    {victim, id} = start(worker, "victim")
    {neighbor, _} = start(worker, "neighbor")
    assert :ok = Fake.stop_command(victim)
    assert :ok = Fake.stop_command(victim)
    assert Process.alive?(victim.private.pid)
    assert {:error, :command_exited} = Fake.write_stdin(victim, "after detach")
    assert {:error, :command_exited} = Fake.close_stdin(victim)
    {:ok, attached} = Fake.attach(worker, id, owner: self())
    ref = attached.ref
    assert_receive {:stdout, %{ref: ^ref}, "ready"}
    assert :ok = Fake.terminate_session(worker, id, [])
    assert_receive {:exit, %{ref: ^ref}, 137}
    refute Process.alive?(victim.private.pid)
    old_ref = victim.ref
    refute_receive {:exit, %{ref: ^old_ref}, _}
    neighbor_ref = neighbor.ref
    assert :ok = Fake.write_stdin(neighbor, "still here")
    assert_receive {:stdout, %{ref: ^neighbor_ref}, "echo:still here"}
  end

  test "an absent session on another sandbox cannot stop the owned session", %{worker: worker} do
    {command, id} = start(worker, "victim")
    {:ok, other} = Fake.create("other", [])
    assert :ok = Fake.terminate_session(other, id, [])
    assert Process.alive?(command.private.pid)
    assert :ok = Fake.terminate_session(worker, "absent", [])

    assert {:error, {:invalid, :termination_request}} =
             Fake.terminate_session(worker, "../id", [])
  end

  test "concurrent termination acknowledgments emit one terminal frame", %{worker: worker} do
    {command, id} = start(worker, "victim")
    tasks = for _ <- 1..2, do: Task.async(fn -> Fake.terminate_session(worker, id, []) end)
    assert Enum.map(tasks, &Task.await/1) == [:ok, :ok]
    ref = command.ref
    assert_receive {:exit, %{ref: ^ref}, 137}
    refute_receive {:exit, %{ref: ^ref}, _}
    assert :ok = Fake.terminate_session(worker, id, [])
  end

  test "force stop confirms a known process but leaves missing identity uncertain", %{
    worker: worker
  } do
    {command, id} = start(worker, "victim")
    assert :ok = Fake.terminate_session(worker, id, mode: :force)
    refute Process.alive?(command.private.pid)

    assert {:error, {:unavailable, :termination_unconfirmed}} =
             Fake.terminate_session(worker, "absent", mode: :force)
  end

  test "completed results are preserved and destroyed handles can still detach", %{worker: worker} do
    {command, id} = start(worker, "done")
    ref = command.ref
    assert :ok = Fake.close_stdin(command)
    assert_receive {:exit, %{ref: ^ref}, 0}
    assert :ok = Fake.terminate_session(worker, id, [])
    refute_receive {:exit, %{ref: ^ref}, _}
    {:ok, replay} = Fake.attach(worker, id, owner: self())
    replay_ref = replay.ref
    assert_receive {:exit, %{ref: ^replay_ref}, 0}
    assert :ok = Fake.destroy(worker)
    assert :ok = Fake.stop_command(command)
    assert :ok = Fake.terminate_session(worker, id, [])
  end
end
