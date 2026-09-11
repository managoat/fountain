defmodule Fountain.Conversations.InterruptionAdmissionIsolationTest do
  use Fountain.DataCase, async: false

  alias Fountain.Conversations

  for capacity <- [1, :unbounded] do
    @tag capacity: capacity
    test "a newer #{inspect(capacity)} turn keeps the interrupted conversation running", ctx do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        sandbox = insert_sandbox(user_id: user.id, status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
        turn = insert_turn(conv, status: "running")
        # Ownership: these fixtures are the actor's own conversation and machine.
        assert {:ok, _} = Conversations._unsafe_interrupt_turn(turn, sandbox.id)
        handler = {__MODULE__, make_ref()}

        :telemetry.attach(
          handler,
          [:fountain, :repo, :query],
          &__MODULE__.pause_admission/4,
          self()
        )

        admission =
          independent(fn ->
            Process.put(:pause_interrupt_admission_test, true)
            # Ownership: exercise real admission for this actor's fixture.
            Conversations._unsafe_create_turn_on_sandbox(
              %{conversation_id: conv.id, turn_number: 2, status: "running", prompt: "next"},
              sandbox.id,
              ctx.capacity
            )
          end)

        try do
          assert_receive :turn_inserted, 5_000

          ending =
            independent(fn ->
              # Ownership: finish the interrupt after its peer has stopped.
              Conversations._unsafe_idle_interrupted_turn(turn, sandbox.id)
            end)

          try do
            ending_pid = ending.pid
            assert_receive {:backend, ^ending_pid, backend}, 5_000
            await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
            send(admission.pid, :commit)
            assert {:ok, next_turn} = Task.await(admission)
            assert :noop = Task.await(ending)
            assert Repo.reload!(conv).status == "running"
            assert Repo.reload!(next_turn).status == "running"
            assert Repo.reload!(turn).status == "interrupted"
          after
            Task.shutdown(ending, :brutal_kill)
          end
        after
          Task.shutdown(admission, :brutal_kill)
          :telemetry.detach(handler)
          Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
          Repo.delete!(user)
          Repo.delete!(sandbox)
        end
      end)
    end
  end

  def pause_admission(_event, _measurements, metadata, owner) do
    if Process.get(:pause_interrupt_admission_test) &&
         String.starts_with?(metadata.query, ~s(INSERT INTO "turns")) do
      Process.delete(:pause_interrupt_admission_test)
      send(owner, :turn_inserted)

      receive do
        :commit -> :ok
      after
        10_000 -> raise "admission release timed out"
      end
    end
  end

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "no PostgreSQL row-lock wait observed"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
