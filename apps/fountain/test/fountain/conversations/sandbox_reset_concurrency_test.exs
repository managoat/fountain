defmodule Fountain.Conversations.SandboxResetConcurrencyTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Ecto.Adapters.SQL.Sandbox, as: SQLSandbox
  alias Fountain.Conversations

  setup :set_mimic_global

  # Two callers, one machine, and only one completion published. That is what
  # this file has always been for; what changed with ADR 0058 stage 5c is *how*
  # the second one loses.
  #
  # Before the machine had an owner, both callers reached
  # `Managoat.Sandbox.destroy/1` and were separated afterwards, by
  # `pending_reset_matches/2` under `update_sandbox_if/3`'s row lock: two
  # provider deletes of one machine, and whichever committed the terminal write
  # first was the winner. The lease decides in front of the provider instead,
  # so the machine is deleted once and the loser never calls at all. These
  # tests pin that inversion — a provider call the loser does *not* make is the
  # assertion — and every invariant either side of it: one `sandbox.reset`, one
  # stage event, one quota slot released, and nothing sent to a holder that
  # rebound in the meantime.
  for first <- [:original, :retry] do
    test "#{first} holds the machine and a competing retry stands off" do
      SQLSandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        home = insert_sandbox(user_id: user.id, mode: "persistent", status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: home, status: "idle")
        owner = self()

        if unquote(first) == :retry do
          stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :timeout} end)
          assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(home)
        end

        stub(Managoat.Sandbox.Sprites, :destroy, fn _ ->
          refute Repo.in_transaction?()
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(owner, {:deleting, self(), backend})

          receive do
            :confirmed -> :ok
          after
            5_000 -> flunk("delete barrier timed out")
          end
        end)

        winner =
          independent(fn ->
            if unquote(first) == :original,
              do: Conversations.reset_sandbox(home),
              else: Conversations.retry_pending_sandbox_reset(home)
          end)

        try do
          assert_receive {:deleting, winner_pid, _backend}, 5_000
          assert winner_pid == winner.pid

          # The lease is live and the winner is inside the provider call. A
          # retry arriving now is refused as busy — a retryable condition, and
          # deliberately not `{:ok, :skipped}`, which would tell an operator
          # the fence had cleared — and makes no provider call of its own.
          assert {:error, :sandbox_unavailable} =
                   Conversations.retry_pending_sandbox_reset(home)

          refute_received {:deleting, _, _}
          assert Fountain.Quotas.active_sandbox_count(user.id) == 1
          assert Repo.reload!(home).transition == "destroying"

          send(winner.pid, :confirmed)
          assert {:ok, %{status: "terminated"}} = Task.await(winner, 5_000)
          assert Fountain.Quotas.active_sandbox_count(user.id) == 0

          # A holder can now move to a replacement. Register its new server
          # before the loser runs: it must send it nothing.
          replacement = insert_sandbox(user_id: user.id, status: "ready")
          {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: replacement.id})
          {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, conv.id, nil)

          assert {:ok, :skipped} = Conversations.retry_pending_sandbox_reset(home)
          refute_received {:deleting, _, _}
          refute_received {:"$gen_cast", _}

          assert Repo.aggregate(
                   from(a in Fountain.Audit.Event,
                     where: a.resource_id == ^home.id and a.action == "sandbox.reset"
                   ),
                   :count
                 ) == 1

          assert [_] =
                   Enum.filter(
                     Conversations._unsafe_list_log_events(conv.id),
                     &(&1.stage == "sandbox")
                   )
        after
          Horde.Registry.unregister(Fountain.ConversationRegistry, conv.id)
          Task.shutdown(winner, :brutal_kill)
          Repo.delete_all(from c in Conversations.Conversation, where: c.user_id == ^user.id)
          Repo.delete_all(from s in Conversations.Sandbox, where: s.user_id == ^user.id)
          Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
          Repo.delete_all(from a in Fountain.Agents.Agent, where: a.user_id == ^user.id)
          Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
        end
      end)
    end
  end

  test "a rebound holder wins while an old reset notification waits for its row" do
    SQLSandbox.unboxed_run(Repo, fn ->
      user = insert_verified_user()
      home = insert_sandbox(user_id: user.id, mode: "persistent", status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: home, status: "idle")
      replacement = insert_sandbox(user_id: user.id, status: "ready")
      stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> :ok end)
      assert {:ok, _} = Conversations.reset_sandbox(home)
      Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user.id}")
      owner = self()

      state = %{
        conversation_id: conv.id,
        user_id: user.id,
        sandbox_id: home.id,
        current_turn: nil,
        turn_execution: nil,
        handle: nil
      }

      moving =
        independent(fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from c in Conversations.Conversation, where: c.id == ^conv.id, lock: "FOR UPDATE"
            )

            send(owner, :holder_locked)

            receive do
              :move -> :ok
            after
              5_000 -> flunk("holder barrier timed out")
            end

            {:ok, moved} =
              Conversations.update_conversation(conv, %{
                sandbox_id: replacement.id,
                status: "running"
              })

            insert_turn(moved, status: "running")
          end)
        end)

      try do
        assert_receive :holder_locked, 5_000

        notification =
          independent(fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(owner, {:notification_backend, backend})

            Conversations.MachineEvents.reset(
              state,
              home.id,
              "reset_reconciled",
              "system",
              "late",
              fn _, _ ->
                flunk("old notification must not close the replacement's connection")
              end
            )
          end)

        try do
          assert_receive {:notification_backend, backend}, 5_000
          await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
          send(moving.pid, :move)
          assert {:ok, turn} = Task.await(moving, 5_000)
          assert {:noreply, ^state} = Task.await(notification, 5_000)
          assert Repo.reload!(conv).sandbox_id == replacement.id
          assert Repo.reload!(conv).status == "running"
          assert Repo.reload!(turn).status == "running"
          assert_receive {:sidebar_update, user_id}
          assert user_id == user.id
          refute_received {:sidebar_update, _}

          assert [_] =
                   Enum.filter(
                     Conversations._unsafe_list_log_events(conv.id),
                     &(&1.stage == "sandbox")
                   )
        after
          Task.shutdown(notification, :brutal_kill)
        end
      after
        Task.shutdown(moving, :brutal_kill)
        Repo.delete_all(from c in Conversations.Conversation, where: c.user_id == ^user.id)
        Repo.delete_all(from s in Conversations.Sandbox, where: s.user_id == ^user.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from a in Fountain.Agents.Agent, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await_blocked(backend, deadline)
    end
  end

  defp independent(fun) do
    Task.async(fn -> SQLSandbox.unboxed_run(Repo, fun) end)
  end
end
