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

  import Fountain.ChatGPTFixtures, only: [access_token: 0, id_token: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.Accounts.User
  alias Fountain.ChatGPTAccounts
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformChatGPT.Account

  @model "openai/gpt-5.5-codex"
  @tenant_lock "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))"

  describe "linking a grant" do
    test "one user's link blocks that user's resolve and nobody else's" do
      with_users(2, fn [linker, bystander] ->
        writer = paused_after_tenant_lock(fn -> link(linker, "Work", "acct-work") end)

        try do
          assert_receive {:locked, writer_pid}, 5_000
          assert writer_pid == writer.pid

          assert {:ok, %Source{}, _credentials} =
                   Task.await(independent(fn -> resolve(bystander.id) end), 5_000)

          assert Task.yield(writer, 0) == nil

          own = independent(fn -> resolve(linker.id) end)
          own_pid = own.pid
          assert_receive {:backend, ^own_pid, backend}, 5_000
          await_blocked(backend)

          send(writer.pid, :continue)
          assert {:ok, %{name: "Work"}} = Task.await(writer, 5_000)
          assert {:ok, %Source{}, _credentials} = Task.await(own, 5_000)
        after
          Task.shutdown(writer, :brutal_kill)
        end
      end)
    end

    test "two links racing for the last slot: one is linked, one is refused at the ceiling" do
      previous = Application.fetch_env!(:fountain, :chatgpt_grant_ceiling)
      Application.put_env(:fountain, :chatgpt_grant_ceiling, 2)

      try do
        with_users(1, fn [user] ->
          assert {:ok, _} = link(user, "Personal", "acct-personal")
          first = paused_after_tenant_lock(fn -> link(user, "Work", "acct-work") end)

          try do
            assert_receive {:locked, first_pid}, 5_000
            assert first_pid == first.pid

            # The second count cannot run until the first insert has committed.
            second = independent(fn -> link(user, "Side project", "acct-side") end)
            second_pid = second.pid
            assert_receive {:backend, ^second_pid, backend}, 5_000
            await_blocked(backend)

            send(first.pid, :continue)
            assert {:ok, %{name: "Work"}} = Task.await(first, 5_000)

            assert {:error, {:grant_limit_reached, %{count: 2, limit: 2}}} =
                     Task.await(second, 5_000)

            assert [%{name: "Personal"}, %{name: "Work"}] =
                     ChatGPTAccounts.list_for_user(user.id)
          after
            Task.shutdown(first, :brutal_kill)
          end
        end)
      after
        Application.put_env(:fountain, :chatgpt_grant_ceiling, previous)
      end
    end
  end

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

  # The trigger builds its key from `uuid::text`, which is canonical. The
  # Elixir side builds it from a string it was handed; two spellings of one
  # id must not be two locks, or the mutual exclusion silently stops holding.
  describe "the Elixir key and the trigger's" do
    @held """
    SELECT count(*) FROM pg_locks l,
      (SELECT hashtextextended('inference:' || ($1::uuid)::text, 0) AS key) k
    WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid() AND l.objsubid = 1
      AND l.classid::bigint = ((k.key >> 32) & 4294967295)
      AND l.objid::bigint = (k.key & 4294967295)
    """

    test "another spelling of a user id takes the key the trigger takes for that user" do
      id = Ecto.UUID.generate()

      Repo.transaction(fn ->
        assert %{rows: [[0]]} = Repo.query!(@held, [Ecto.UUID.dump!(id)])
        assert :ok = InferenceCredentials.lock_tenant_source(String.upcase(id))
        assert %{rows: [[1]]} = Repo.query!(@held, [Ecto.UUID.dump!(id)])
      end)
    end

    test "what is not a user id takes no key" do
      assert_raise Ecto.CastError, fn -> InferenceCredentials.lock_tenant_source("platform") end
    end
  end

  defp resolve(user_id), do: InferenceCredentials.resolve(user_id, @model, "codex")

  defp link(user, name, account_id) do
    ChatGPTAccounts.connect_for_user(user.id, name, %{
      access_token: access_token(),
      refresh_token: "rt_" <> account_id,
      id_token: id_token(%{account_id: account_id})
    })
  end

  # Runs `fun` in a session of its own and parks it the moment its
  # transaction holds the tenant source lock, until `:continue`. The handler
  # runs in the querying process, after the lock is granted.
  defp paused_after_tenant_lock(fun) do
    handler_id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler_id, [:fountain, :repo, :query], &__MODULE__.pause/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    independent(fn ->
      Process.put(:pause_after_tenant_lock, true)
      fun.()
    end)
  end

  @doc false
  def pause(_event, _measurements, metadata, owner) do
    if Process.get(:pause_after_tenant_lock) && metadata.query == @tenant_lock do
      Process.delete(:pause_after_tenant_lock)
      send(owner, {:locked, self()})

      receive do
        :continue -> :ok
      after
        10_000 -> raise "the paused write was not released"
      end
    end
  end

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
      # Verified by hand: `verify_email/1` commits a starter agent, a ledger
      # entry and a mail job, none of which this test wants to clean up.
      users =
        for _ <- 1..count do
          insert_user() |> change(email_verified_at: ~U[2026-09-01 00:00:00Z]) |> Repo.update!()
        end

      try do
        fun.(users)
      after
        ids = Enum.map(users, & &1.id)
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id in ^ids)
        Repo.delete_all(from u in User, where: u.id in ^ids)
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
