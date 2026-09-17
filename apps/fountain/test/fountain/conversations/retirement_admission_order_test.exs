defmodule Fountain.Conversations.RetirementAdmissionOrderTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.Conversations

  for first <- [:retirement, :admission] do
    test "#{first} wins the retirement race" do
      assert_order(unquote(first))
    end
  end

  defp assert_order(first) do
    Sandbox.unboxed_run(Repo, fn ->
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      home =
        insert_sandbox(user_id: user.id, agent_id: agent.id, mode: "persistent", status: "ready")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          sandbox: home,
          status: "idle",
          runtime_session_id: "before-retirement"
        )

      owner = self()

      operation = fn
        :retirement ->
          Conversations.update_sandbox(home, %{status: "terminated"})

        :admission ->
          Conversations._unsafe_create_turn_on_sandbox(
            %{
              conversation_id: conv.id,
              turn_number: 1,
              status: "running",
              prompt: "race"
            },
            home.id
          )
      end

      winner = independent(first, fn -> operation.(first) end, owner, true)

      try do
        assert_receive {:locked, winner_pid}, 5_000
        assert winner_pid == winner.pid
        second = if first == :retirement, do: :admission, else: :retirement
        waiter = independent(second, fn -> operation.(second) end, owner, false)

        try do
          assert_receive {:backend, ^first, winner_backend}, 5_000
          assert_receive {:backend, ^second, waiter_backend}, 5_000
          refute winner_backend == waiter_backend

          await_blocked(
            waiter_backend,
            winner_backend,
            System.monotonic_time(:millisecond) + 5_000
          )

          assert Repo.aggregate(
                   from(t in Conversations.Turn, where: t.conversation_id == ^conv.id),
                   :count
                 ) == 0

          refute_received {:destroying, _, _}
          send(winner.pid, :continue)

          if first == :retirement do
            assert {:ok, %{status: "terminated"}} = Task.await(winner, 5_000)
            assert {:error, :sandbox_unavailable} = Task.await(waiter, 5_000)

            assert Repo.aggregate(
                     from(t in Conversations.Turn, where: t.conversation_id == ^conv.id),
                     :count
                   ) == 0
          else
            assert {:ok, turn} = Task.await(winner, 5_000)
            assert {:ok, %{status: "terminated"}} = Task.await(waiter, 5_000)
            assert Repo.get!(Conversations.Turn, turn.id).status == "running"
          end

          assert Repo.reload!(home).status == "terminated"
          refute_received {:destroying, _, _}
        after
          stop(waiter)
        end
      after
        stop(winner)
        Repo.delete_all(from c in Conversations.Conversation, where: c.user_id == ^user.id)
        Repo.delete_all(from s in Conversations.Sandbox, where: s.id == ^home.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end
    end)
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
              {self(), owner, handler, role}
            )
        end

        stub(Managoat.Sandbox.Sprites, :destroy, fn _ ->
          send(owner, {:destroying, self(), Repo.in_transaction?()})

          receive do
            :destroy -> :ok
          after
            10_000 -> raise "provider release timed out"
          end
        end)

        try do
          fun.()
        after
          :telemetry.detach(handler)
        end
      end)
    end)
  end

  # Pause after the actual row query, not after the advisory lock: a writer
  # that only locks the sandbox row must wait for the admission insert too.
  def after_query(_, _, %{query: query}, {worker, owner, handler, role}) do
    target? =
      case role do
        :retirement -> query =~ ~s(FROM "sandboxes") and query =~ "FOR UPDATE"
        :admission -> query =~ ~s(FROM "sandboxes") and query =~ "FOR SHARE"
      end

    if self() == worker and target? do
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
