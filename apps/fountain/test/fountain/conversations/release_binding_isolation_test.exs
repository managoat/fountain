defmodule Fountain.Conversations.ReleaseBindingIsolationTest do
  use Fountain.DataCase, async: false

  alias Fountain.Conversations
  alias Fountain.Conversations.Conversation

  @moduledoc """
  A release and reassignment serialize through the parent's PostgreSQL row
  lock. Independent connections exercise both orders and observe the actual
  wait, so a comparison performed only before the lock cannot pass.
  """

  for first <- [:reassignment, :release], caller <- [:actor, :recovery] do
    @tag first: first, caller: caller
    test "#{first} serializes #{caller} release with reassignment", %{
      first: first,
      caller: caller
    } do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        old = insert_sandbox(user_id: user.id, status: "ready")
        replacement = insert_sandbox(user_id: user.id, status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: old, status: "idle")
        owner = self()
        handler = {__MODULE__, make_ref()}

        # Pause the real release after its status write, while its own parent
        # lock is still held. Do not add an outer transaction around the call.
        :telemetry.attach(handler, [:fountain, :repo, :query], &__MODULE__.pause_release/4, owner)

        release = fn ->
          if caller == :actor do
            Fountain.Conversations.Termination._unsafe_release_binding(conv.id, old.id, [])
          else
            Fountain.Conversations.Termination.release_conversation(conv.id)
          end
        end

        reassign = fn ->
          Conversations.update_conversation(conv, %{sandbox_id: replacement.id})
        end

        leading =
          independent(fn ->
            if first == :release do
              Process.put(:pause_release_binding_test, true)
              release.()
            else
              Repo.transaction(fn ->
                from(c in Conversation, where: c.id == ^conv.id)
                |> Repo.update_all(set: [sandbox_id: replacement.id])

                hold(owner)
              end)
            end
          end)

        try do
          assert_receive :write_held, 5_000
          trailing = independent(if first == :release, do: reassign, else: release)

          try do
            trailing_pid = trailing.pid
            assert_receive {:backend, ^trailing_pid, backend}, 5_000
            await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
            send(leading.pid, :commit)
            leading_result = Task.await(leading)
            trailing_result = Task.await(trailing)

            if first == :release do
              assert :ok = leading_result
              assert {:ok, _} = trailing_result
            else
              assert {:ok, :ok} = leading_result

              assert trailing_result ==
                       if(caller == :actor, do: {:error, :ownership_changed}, else: :ok)
            end

            assert Repo.reload(conv).sandbox_id == replacement.id

            assert Repo.reload(conv).status ==
                     if(first == :release or caller == :recovery, do: "terminated", else: "idle")
          after
            Task.shutdown(trailing, :brutal_kill)
          end
        after
          Task.shutdown(leading, :brutal_kill)
          :telemetry.detach(handler)
          Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
          Repo.delete!(user)
          Repo.delete!(old)
          Repo.delete!(replacement)
        end
      end)
    end
  end

  def pause_release(_event, _measurements, metadata, owner) do
    if Process.get(:pause_release_binding_test) &&
         String.starts_with?(metadata.query, ~s(UPDATE "conversations")) do
      Process.delete(:pause_release_binding_test)
      hold(owner)
    end
  end

  defp hold(owner) do
    send(owner, :write_held)

    receive do
      :commit -> :ok
    after
      10_000 -> raise "binding write release timed out"
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
