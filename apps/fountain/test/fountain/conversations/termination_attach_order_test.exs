defmodule Fountain.Conversations.TerminationAttachOrderTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.{Audit, Conversations}
  alias Fountain.Conversations.Launch
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Machines.Machine

  # The attachment's locked insert runs in the machine's owner, which serves
  # each call on its caller's connection only in manual mode
  # (`Fountain.ServerStart`).
  setup :manual_pool

  for {first, barrier} <- [termination: :row, attachment: :row, termination: :machine] do
    test "#{first} wins the race between termination and a new co-tenant at #{barrier} lock" do
      assert_order(unquote(first), unquote(barrier))
    end
  end

  defp assert_order(first, barrier) do
    Sandbox.unboxed_run(Repo, fn ->
      user = insert_active_user()
      env = insert_env(user_id: user.id)
      agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

      sandbox =
        insert_sandbox(
          user_id: user.id,
          agent_id: agent.id,
          environment_id: env.id,
          mode: "ephemeral",
          status: "ready"
        )

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      operation = fn
        :termination ->
          Lifecycle.fence_sandbox_for_teardown(sandbox,
            terminating_conversation_id: conv.id,
            reason: "conversation_terminated"
          )

        :attachment ->
          Launch.start_conversation(%{
            "user_id" => user.id,
            "agent_id" => agent.id,
            "sandbox_id" => sandbox.id
          })
      end

      owner = self()
      winner = independent(first, fn -> operation.(first) end, owner, barrier)

      try do
        # An attachment pauses in the machine's owner, which runs its insert.
        assert_receive {:locked, winner_pid}, 5_000
        assert winner_pid in [winner.pid, Machine.whereis(sandbox.id)]
        second = if first == :termination, do: :attachment, else: :termination
        waiter = independent(second, fn -> operation.(second) end, owner, false)

        try do
          assert_receive {:backend, ^first, holder}, 5_000
          assert_receive {:backend, ^second, blocked}, 5_000
          refute holder == blocked
          await_blocked(blocked, holder, System.monotonic_time(:millisecond) + 5_000)
          assert conversation_count(user.id) == 1
          refute Repo.reload!(sandbox).transition == "destroying"
          send(winner_pid, :continue)

          if first == :termination do
            assert {:ok, fenced} = Task.await(winner, 5_000)
            assert fenced.transition == "destroying"
            assert {:error, :sandbox_reset_pending} = Task.await(waiter, 5_000)
            assert conversation_count(user.id) == 1
            assert [_] = Audit.list_for_user(user.id, action_prefix: "sandbox.teardown_requested")
          else
            assert {:ok, attached} = Task.await(winner, 5_000)
            assert attached.sandbox_id == sandbox.id
            assert {:error, :sandbox_kept} = Task.await(waiter, 5_000)
            assert conversation_count(user.id) == 2
            refute Repo.reload!(sandbox).transition == "destroying"
            assert Audit.list_for_user(user.id, action_prefix: "sandbox.teardown_requested") == []
          end

          assert Repo.reload!(sandbox).status == "ready"
          assert Repo.reload!(conv).status == "idle"

          assert Repo.aggregate(
                   from(t in Conversations.Turn, where: t.conversation_id == ^conv.id),
                   :count
                 ) == 0
        after
          stop(waiter)
        end
      after
        stop(winner)
        Repo.delete_all(from c in Conversations.Conversation, where: c.user_id == ^user.id)
        Repo.delete_all(from s in Conversations.Sandbox, where: s.id == ^sandbox.id)
        Repo.delete_all(from a in Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end
    end)
  end

  defp conversation_count(user_id) do
    Repo.aggregate(from(c in Conversations.Conversation, where: c.user_id == ^user_id), :count)
  end

  defp stop(task) do
    Task.shutdown(task, :brutal_kill)
    :telemetry.detach({__MODULE__, task.pid})
  end

  defp independent(role, fun, owner, pause?) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, role, backend})
        handler = {__MODULE__, self()}

        if pause? do
          :ok =
            :telemetry.attach(
              handler,
              [:fountain, :repo, :query],
              &__MODULE__.after_query/4,
              {self(), owner, handler, role, pause?}
            )
        end

        reject(Managoat.Sandbox, :destroy, 1)

        try do
          fun.()
        after
          :telemetry.detach(handler)
        end
      end)
    end)
  end

  def after_query(_, _, %{query: query}, {worker, owner, handler, role, barrier}) do
    # Pausing teardown before its row locks catches an attachment that takes
    # the sandbox row before the advisory lock used by inference reservation.
    target? =
      if barrier == :machine do
        query =~ "pg_advisory_xact_lock"
      else
        query =~ ~s(FROM "sandboxes") and (role == :termination or query =~ "FOR NO KEY UPDATE")
      end

    # The worker, or the machine owner serving it (`$callers`).
    if (self() == worker or worker in Process.get(:"$callers", [])) and target? do
      :telemetry.detach(handler)
      send(owner, {:locked, self()})

      receive do
        :continue -> :ok
      after
        10_000 -> send(owner, :lock_release_timed_out)
      end
    end
  end

  def after_query(_, _, _, _), do: :ok

  defp await_blocked(waiter, holder, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT $2 = ANY(pg_blocking_pids($1))", [waiter, holder])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "no wait on the winning PostgreSQL connection observed"

      Process.sleep(5)
      await_blocked(waiter, holder, deadline)
    end
  end
end
