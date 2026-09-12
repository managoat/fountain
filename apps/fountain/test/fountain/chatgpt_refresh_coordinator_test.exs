defmodule Fountain.ChatGPTRefreshCoordinatorTest do
  use ExUnit.Case, async: true

  alias Fountain.ChatGPTAccounts.RefreshCoordinator

  defmodule Worker do
    def refresh_serialized_for_user(grant_id, user_id, generation) do
      [owner, _] = String.split(grant_id, "/", parts: 2)
      owner = owner |> String.to_charlist() |> :erlang.list_to_pid()
      send(owner, {:started, self(), user_id, generation})

      receive do
        {:finish, result} -> result
        :crash -> raise "synthetic refresh worker failure"
      after
        5_000 -> raise "test worker barrier timed out"
      end
    end
  end

  setup tags do
    tasks = start_supervised!({Task.Supervisor, max_children: 2})

    server =
      start_supervised!(
        {RefreshCoordinator,
         name: nil,
         task_supervisor: tasks,
         worker: Worker,
         max_concurrency: 2,
         max_waiters: Map.get(tags, :max_waiters, 128),
         worker_timeout: Map.get(tags, :worker_timeout, 2_000)}
      )

    %{
      server: server,
      tasks: tasks,
      grant: "#{:erlang.pid_to_list(self())}/#{Ecto.UUID.generate()}"
    }
  end

  test "same-grant callers share a worker; the queue never stores its credential", ctx do
    callers = for _ <- 1..8, do: call(ctx)
    assert_receive {:started, worker, "owner", "generation"}
    await_waiters(ctx.server, 8)
    refute_received {:started, _, _, _}
    send(worker, {:finish, :ok})
    for caller <- callers, do: assert(:ok = Task.await(caller))
    assert :sys.get_state(ctx.server).jobs == %{}
    assert :sys.get_state(ctx.server).callers == %{}
  end

  test "another owner or generation cannot join an existing grant's worker", ctx do
    first = call(ctx)
    assert_receive {:started, first_worker, "owner", "generation"}
    second = call(ctx, "other-owner", "generation")
    assert_receive {:started, second_worker, "other-owner", "generation"}
    refute first_worker == second_worker
    send(second_worker, {:finish, :ok})
    assert :ok = Task.await(second)
    replacement = call(ctx, "owner", "new-generation")
    assert_receive {:started, replacement_worker, "owner", "new-generation"}
    send(first_worker, {:finish, {:error, :stale_grant}})
    send(replacement_worker, {:finish, :ok})
    assert {:error, :stale_grant} = Task.await(first)
    assert :ok = Task.await(replacement)
  end

  test "the concurrency cap refuses excess grants and frees capacity on completion", ctx do
    first = call(ctx)
    assert_receive {:started, first_worker, _, _}
    second_ctx = %{ctx | grant: ctx.grant <> "-second"}
    second = call(second_ctx)
    assert_receive {:started, second_worker, _, _}
    third_ctx = %{ctx | grant: ctx.grant <> "-third"}
    assert {:error, :refresh_busy} = Task.await(call(third_ctx))
    refute_received {:started, _, _, _}
    send(first_worker, {:finish, :ok})
    assert :ok = Task.await(first)
    third = call(third_ctx)
    assert_receive {:started, third_worker, _, _}
    send(second_worker, {:finish, :ok})
    send(third_worker, {:finish, :ok})
    assert :ok = Task.await(second)
    assert :ok = Task.await(third)
  end

  test "the task supervisor cap also refuses admission without crashing the coordinator", ctx do
    blockers =
      for _ <- 1..2 do
        {:ok, pid} = Task.Supervisor.start_child(ctx.tasks, fn -> Process.sleep(:infinity) end)
        pid
      end

    assert {:error, :refresh_busy} = Task.await(call(ctx))
    assert Process.alive?(ctx.server)
    assert :sys.get_state(ctx.server).jobs == %{}
    for pid <- blockers, do: Task.Supervisor.terminate_child(ctx.tasks, pid)
    caller = call(ctx)
    assert_receive {:started, worker, _, _}
    send(worker, {:finish, :ok})
    assert :ok = Task.await(caller)
  end

  @tag max_waiters: 2
  test "waiting callers are capped, and departed callers release their slots", ctx do
    first = call(ctx)
    assert_receive {:started, worker, _, _}
    second = call(ctx)
    await_waiters(ctx.server, 2)
    assert {:error, :refresh_busy} = Task.await(call(ctx))
    Task.shutdown(second, :brutal_kill)
    await_waiters(ctx.server, 1)
    third = call(ctx)
    await_waiters(ctx.server, 2)
    send(worker, {:finish, :ok})
    assert :ok = Task.await(first)
    assert :ok = Task.await(third)
  end

  test "an exchange survives its last caller leaving and a later caller joins it", ctx do
    first = call(ctx)
    assert_receive {:started, worker, _, _}
    Task.shutdown(first, :brutal_kill)
    await_waiters(ctx.server, 0)
    assert Process.alive?(worker)
    second = call(ctx)
    await_waiters(ctx.server, 1)
    refute_received {:started, _, _, _}
    send(worker, {:finish, :ok})
    assert :ok = Task.await(second)
  end

  @tag capture_log: true
  test "a worker crash releases callers and permits a fresh attempt", ctx do
    first = call(ctx)
    assert_receive {:started, worker, _, _}
    second = call(ctx)
    await_waiters(ctx.server, 2)
    send(worker, :crash)
    assert {:error, :refresh_unavailable} = Task.await(first)
    assert {:error, :refresh_unavailable} = Task.await(second)
    assert Process.alive?(ctx.server)
    third = call(ctx)
    assert_receive {:started, replacement, _, _}
    send(replacement, {:finish, :ok})
    assert :ok = Task.await(third)
  end

  @tag worker_timeout: 100
  test "the deadline kills a stuck worker and releases its callers", ctx do
    first = call(ctx)
    assert_receive {:started, worker, _, _}
    monitor = Process.monitor(worker)
    assert {:error, :refresh_timeout} = Task.await(first)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert :sys.get_state(ctx.server).jobs == %{}
    second = call(ctx)
    assert_receive {:started, replacement, _, _}
    send(replacement, {:finish, :ok})
    assert :ok = Task.await(second)
  end

  test "unexpected worker values cannot be returned as credentials or provider bodies", ctx do
    for result <- [{:ok, "synthetic-bearer"}, {:error, %{"echo" => "synthetic-refresh"}}] do
      caller = call(ctx)
      assert_receive {:started, worker, _, _}
      send(worker, {:finish, result})
      assert {:error, :refresh_unavailable} = Task.await(caller)
      refute inspect(:sys.get_state(ctx.server)) =~ "synthetic"
    end
  end

  defp call(ctx, user_id \\ "owner", generation \\ "generation") do
    Task.async(fn -> RefreshCoordinator.run(ctx.grant, user_id, generation, ctx.server) end)
  end

  defp await_waiters(server, count, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    if map_size(:sys.get_state(server).callers) != count do
      assert System.monotonic_time(:millisecond) < deadline, "waiter count did not reach #{count}"
      Process.sleep(5)
      await_waiters(server, count, deadline)
    end
  end
end
