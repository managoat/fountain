defmodule Fountain.Accounts.DeletionSourceLockTest do
  use Fountain.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.Accounts.{Deletion, User}
  alias Fountain.InferenceCredentials
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.PlatformInference.Key

  for source <- [:none, :personal_chatgpt, :operator_attribution] do
    test "deleting an account with #{source} does not deadlock source admission" do
      Sandbox.unboxed_run(Repo, fn ->
        user = insert_user()
        source = seed_source(unquote(source), user)

        try do
          {deleted, admitted} =
            compete_with_deletion(user, fn ->
              InferenceCredentials.with_source_lock(user.id, fn -> :admitted end)
            end)

          assert {:ok, %{user_id: id, sprites_destroyed: 0}} = deleted
          assert id == user.id
          assert admitted == :admitted
          refute Repo.get(User, user.id)
          assert_source_deleted(source)
        after
          cleanup(user, source)
        end
      end)
    end
  end

  test "unrelated accounts with personal ChatGPT grants can both be deleted" do
    Sandbox.unboxed_run(Repo, fn ->
      first = insert_user()
      second = insert_user()
      first_source = seed_source(:personal_chatgpt, first)
      second_source = seed_source(:personal_chatgpt, second)

      try do
        {first_result, second_result} =
          compete_with_deletion(first, fn -> Deletion.delete_user(second) end)

        assert {:ok, _} = first_result
        assert {:ok, _} = second_result
        refute Repo.get(User, first.id)
        refute Repo.get(User, second.id)
        assert_source_deleted(first_source)
        assert_source_deleted(second_source)
      after
        cleanup(first, first_source)
        cleanup(second, second_source)
      end
    end)
  end

  # Pause after the real deletion transaction takes its tenant lock. With the
  # old shared-first order the competitor acquires shared platform and then
  # waits on tenant (or upgrades platform for its own cascade). With exclusive
  # platform first it waits there instead. Releasing deletion must let both
  # finish: neither a trigger's lock upgrade nor a lock timeout is acceptable.
  defp compete_with_deletion(user, competitor) do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:fountain, :repo, :query],
        &pause_after_tenant_lock/4,
        self()
      )

    deletion =
      independent(fn ->
        Process.put(:pause_account_deletion, true)
        Deletion.delete_user(user)
      end)

    try do
      assert_receive {:deletion_locked, deletion_pid}, 5_000
      assert deletion_pid == deletion.pid
      contender = independent(competitor)

      try do
        contender_pid = contender.pid
        assert_receive {:backend, ^contender_pid, backend}, 5_000
        await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
        send(deletion.pid, :continue_deletion)
        {Task.await(deletion, 10_000), Task.await(contender, 10_000)}
      after
        Task.shutdown(contender, :brutal_kill)
      end
    after
      Task.shutdown(deletion, :brutal_kill)
      :telemetry.detach(handler_id)
    end
  end

  defp pause_after_tenant_lock(_event, _measurements, metadata, owner) do
    if Process.get(:pause_account_deletion) &&
         metadata.query == "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))" do
      Process.delete(:pause_account_deletion)
      send(owner, {:deletion_locked, self()})

      receive do
        :continue_deletion -> :ok
      after
        5_000 -> raise "account deletion was not released"
      end
    end
  end

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})

        try do
          fun.()
        rescue
          error in Postgrex.Error -> {:postgres_error, error.postgres.code}
        end
      end)
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "competing operation did not wait on deletion's source lock"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end

  defp seed_source(:none, _user), do: nil

  defp seed_source(:personal_chatgpt, user) do
    Repo.insert!(%Account{
      user_id: user.id,
      name: "deletion-lock-test",
      kind: "chatgpt",
      access_token_ciphertext: "deletion-lock-test"
    })
  end

  defp seed_source(:operator_attribution, user) do
    Repo.insert!(%Key{
      provider: "anthropic",
      ciphertext: "deletion-lock-test",
      updated_by_user_id: user.id
    })
  end

  defp assert_source_deleted(nil), do: :ok
  defp assert_source_deleted(%Account{id: id}), do: refute(Repo.get(Account, id))

  defp assert_source_deleted(%Key{} = key) do
    current = Repo.reload!(key)
    assert current.updated_by_user_id == nil
    assert current.ciphertext == key.ciphertext
  end

  defp cleanup(user, source) do
    if match?(%Key{}, source),
      do: Repo.delete_all(from k in Key, where: k.provider == ^source.provider)

    if current = Repo.get(User, user.id), do: Repo.delete!(current)
    Repo.delete_all(from e in Fountain.Audit.Event, where: e.resource_id == ^user.id)
  end
end
