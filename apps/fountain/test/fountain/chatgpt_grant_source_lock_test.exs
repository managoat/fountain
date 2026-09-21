defmodule Fountain.ChatGPTGrantSourceLockTest do
  # ADR 0060 decision 5: a grant row's source lock is keyed by its owner. The
  # platform row keeps `'inference:platform'`; a user's grant takes that
  # user's `'inference:<user_id>'`, so one user's grant write never parks
  # another user's credential resolution.
  #
  # Two sessions have to contend, which the SQL sandbox's one transaction
  # cannot show. The idiom is `accounts/deletion_source_lock_test.exs`'s:
  # every actor is an unboxed connection of its own, so users are really
  # committed and are deleted in `after`.
  use Fountain.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.Accounts.User
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformChatGPT.Account

  @model "openai/gpt-5.5-codex"

  describe "the trigger, whatever the writer" do
    test "a write to one user's grant row blocks that user's resolve and nobody else's" do
      with_users(2, fn [writer_user, bystander] ->
        writer =
          independent(fn ->
            hold_insert(%Account{user_id: writer_user.id, name: "raw", kind: "chatgpt"})
          end)

        try do
          assert_receive {:holding, writer_pid}, 5_000
          assert writer_pid == writer.pid

          assert {:ok, %Source{}, _credentials} =
                   Task.await(independent(fn -> resolve(bystander.id) end), 5_000)

          # The overlap is a fact, not a timing guess: the writer still holds.
          assert Task.yield(writer, 0) == nil

          # The control. The lock still does its job for the row's owner.
          own = independent(fn -> resolve(writer_user.id) end)
          own_pid = own.pid
          assert_receive {:backend, ^own_pid, backend}, 5_000
          await_blocked(backend)

          send(writer.pid, :release)
          assert {:error, :held} = Task.await(writer, 5_000)
          assert {:ok, %Source{}, _credentials} = Task.await(own, 5_000)
        after
          Task.shutdown(writer, :brutal_kill)
        end
      end)
    end

    test "a write to the platform row still blocks every user's resolve" do
      with_users(1, fn [bystander] ->
        writer = independent(fn -> hold_insert(%Account{kind: "workspace_token"}) end)

        try do
          assert_receive {:holding, writer_pid}, 5_000
          assert writer_pid == writer.pid

          resolver = independent(fn -> resolve(bystander.id) end)
          resolver_pid = resolver.pid
          assert_receive {:backend, ^resolver_pid, backend}, 5_000
          await_blocked(backend)

          send(writer.pid, :release)
          assert {:error, :held} = Task.await(writer, 5_000)
          assert {:ok, %Source{}, _credentials} = Task.await(resolver, 5_000)
        after
          Task.shutdown(writer, :brutal_kill)
        end
      end)
    end
  end

  defp resolve(user_id), do: InferenceCredentials.resolve(user_id, @model, "codex")

  # Insert through the schema alone, so the only lock taken is the trigger's,
  # hold it until released, then roll back: nothing is left behind.
  defp hold_insert(row) do
    owner = Process.get(:lock_test_owner)

    Repo.transaction(fn ->
      Repo.insert!(%{row | access_token_ciphertext: "source-lock-test"})
      send(owner, {:holding, self()})

      receive do
        :release -> Repo.rollback(:held)
      after
        10_000 -> raise "the held write was not released"
      end
    end)
  end

  defp with_users(count, fun) do
    Sandbox.unboxed_run(Repo, fn ->
      users = for _ <- 1..count, do: insert_user()

      try do
        fun.(users)
      after
        ids = Enum.map(users, & &1.id)
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id in ^ids)
        Repo.delete_all(from u in User, where: u.id in ^ids)
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.resource_id in ^ids)
      end
    end)
  end

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Process.put(:lock_test_owner, owner)

      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(backend, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "the competing operation did not wait on the source lock"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
