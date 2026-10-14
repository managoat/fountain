defmodule Fountain.Conversations.InferenceAdmissionIsolationTest do
  use Fountain.DataCase, async: false
  alias Fountain.{Crypto, InferenceCredentials}
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Conversations.InferenceBinding

  test "concurrent incompatible Codex starts cannot both reserve an empty machine" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      user = insert_user()
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "first")
      # A vault's key is the second, incompatible source.
      vault = insert_vault(user_id: user.id)
      insert_vault_secret(vault, key: "OPENAI_API_KEY", value: "second")
      first = []
      second = [vault_id: vault.id]

      sandbox = insert_sandbox(user_id: user.id)
      owner = self()

      holder =
        independent(fn ->
          InferenceCredentials.with_source_lock(user.id, fn ->
            result = reserve(user, sandbox, first)
            send(owner, :first_reserved)

            receive do
              :commit -> result
            after
              5_000 -> raise "reservation barrier timed out"
            end
          end)
        end)

      try do
        assert_receive :first_reserved, 5_000

        waiting =
          independent(fn ->
            InferenceCredentials.with_source_lock(user.id, fn ->
              reserve(user, sandbox, second)
            end)
          end)

        try do
          assert_receive {:backend, waiting_pid, backend}, 5_000

          if waiting_pid != waiting.pid do
            assert_receive {:backend, waiting_pid, backend}, 5_000
            assert waiting_pid == waiting.pid
            await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
          else
            await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
          end

          send(holder.pid, :commit)
          assert :ok = Task.await(holder)
          assert {:error, :codex_inference_conflict} = Task.await(waiting)

          assert Repo.aggregate(
                   from(c in Fountain.Conversations.Conversation,
                     where: c.sandbox_id == ^sandbox.id
                   ),
                   :count
                 ) == 1
        after
          Task.shutdown(waiting, :brutal_kill)
        end
      after
        Task.shutdown(holder, :brutal_kill)
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
        Repo.delete!(user)
        Repo.delete!(sandbox)
      end
    end)
  end

  test "credential replacement waits for an admitted binding and invalidates its next use" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      user = insert_user()
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "first")
      owner = self()

      holder =
        independent(fn ->
          InferenceCredentials.with_source_lock(user.id, fn ->
            {:ok, source, _} = InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex")
            send(owner, {:resolved, source})

            receive do
              :commit -> :ok
            after
              5_000 -> raise "source barrier timed out"
            end
          end)
        end)

      try do
        assert_receive {:resolved, source}, 5_000
        assert_receive {:backend, holder_pid, _}, 5_000
        assert holder_pid == holder.pid

        writer =
          independent(fn ->
            InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "replacement")
          end)

        try do
          assert_receive {:backend, writer_pid, backend}, 5_000
          assert writer_pid == writer.pid
          await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
          send(holder.pid, :commit)
          assert :ok = Task.await(holder)
          assert {:ok, _} = Task.await(writer)

          assert {:error, :inference_source_changed} =
                   InferenceCredentials.validate_source(user.id, source)
        after
          Task.shutdown(writer, :brutal_kill)
        end
      after
        Task.shutdown(holder, :brutal_kill)
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
        Repo.delete!(user)
      end
    end)
  end

  defp reserve(user, sandbox, opts) do
    with {:ok, source, _} <- InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex", opts) do
      conv =
        insert_conversation(
          user_id: user.id,
          sandbox: sandbox,
          runtime: "codex",
          inference_source: Source.dump(source)
        )

      InferenceBinding.reserve(conv, source)
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
             "no PostgreSQL source-lock wait observed"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
