defmodule Fountain.Broker.Native.ManagedGrantFenceTest do
  # ADR 0052 decision 5's two pause-and-resume cases, with sessions that
  # really contend: "pause node A after it selects G; disconnect G on node B;
  # resume A's session creation" and "pause a credential-rule update, replace
  # or disconnect G, then resume the update". The SQL sandbox's one
  # transaction cannot show either, so every actor here is an unboxed
  # connection of its own (the idiom is `chatgpt_grant_source_lock_test.exs`'s)
  # and what it commits is deleted in `after`. Both owners; the platform row
  # is one per deployment, so async: false.
  use Fountain.DataCase, async: false

  import Fountain.ChatGPTFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.Broker.Native.{Session, Sessions}
  alias Fountain.ChatGPTAccounts
  alias Fountain.PlatformChatGPT.Account
  alias Managoat.Broker.ProtectedCredential

  @protected %{
    protected: true,
    scheme: :https,
    host: "chatgpt.com",
    port: 443,
    method: "POST",
    target: "/backend-api/codex/responses"
  }

  for owner <- [:platform, :user] do
    describe "#{owner} grant" do
      @describetag owner: owner

      # The issuance holds the grant row; the disconnect has to wait for the
      # session to exist, and then revokes it in its own transaction.
      test "a disconnect that meets an issuance in flight revokes the session it minted",
           %{owner: owner} do
        with_conversation(owner, fn user, conv, account ->
          creator = paused(&(&1 =~ "FOR SHARE OF"), fn -> create(conv, user, account) end)

          try do
            assert_receive {:paused, creator_pid}, 5_000
            assert creator_pid == creator.pid

            ender = independent(fn -> end_generation(account) end)
            ender_pid = ender.pid
            assert_receive {:backend, ^ender_pid, backend}, 5_000
            await_blocked(backend)

            send(creator.pid, :continue)
            assert {:ok, %{token: _}} = Task.await(creator, 5_000)
            assert :ok = Task.await(ender, 5_000)

            assert [%Session{managed_revoked_at: %DateTime{}} = session] = sessions(conv)
            assert {:error, :denied} = Sessions.authorize({:managed, session.id}, @protected)
          after
            Task.shutdown(creator, :brutal_kill)
          end
        end)
      end

      # The other interleaving: the disconnect holds the row, the issuance
      # waits, and what it then reads is the fenced row.
      test "an issuance that meets a disconnect in flight mints nothing", %{owner: owner} do
        with_conversation(owner, fn user, conv, account ->
          ender =
            paused(
              &(&1 =~ "platform_chatgpt_account" and &1 =~ "FOR UPDATE"),
              fn -> end_generation(account) end
            )

          try do
            assert_receive {:paused, ender_pid}, 5_000
            assert ender_pid == ender.pid

            creator = independent(fn -> create(conv, user, account) end)
            creator_pid = creator.pid
            assert_receive {:backend, ^creator_pid, backend}, 5_000
            await_blocked(backend)

            send(ender.pid, :continue)
            assert :ok = Task.await(ender, 5_000)

            assert {:error, {:broker, :session, :managed_grant_inactive}} =
                     Task.await(creator, 5_000)

            assert sessions(conv) == []
          after
            Task.shutdown(ender, :brutal_kill)
          end
        end)
      end

      test "a rule rewrite resumed after a reconnect neither restores the old grant nor takes the new",
           %{owner: owner} do
        with_conversation(owner, fn user, conv, account ->
          assert {:ok, _} = create(conv, user, account)
          [before] = sessions(conv)

          # Paused after its first read, with the rules it will write in hand.
          rewrite =
            paused(&(&1 =~ "user_data_keys"), fn ->
              Sessions.update_rules(conv.id, user.id, [], %{"rewritten" => true})
            end)

          try do
            assert_receive {:paused, _pid}, 5_000
            replaced = reconnect(account)
            refute replaced.generation == account.generation

            send(rewrite.pid, :continue)
            assert {:ok, 1} = Task.await(rewrite, 5_000)

            assert [after_rewrite] = sessions(conv)
            assert after_rewrite.meta == %{"rewritten" => true}
            assert after_rewrite.managed_grant_generation == before.managed_grant_generation
            assert after_rewrite.managed_identity == before.managed_identity
            assert %DateTime{} = after_rewrite.managed_revoked_at
            assert {:error, :denied} = Sessions.authorize({:managed, before.id}, @protected)

            # The new generation is reached by a new session, and only by one.
            assert {:ok, _} = create(conv, user, replaced)
            fresh = Enum.find(sessions(conv), &(&1.id != before.id))

            assert {:ok, %ProtectedCredential{}} =
                     Sessions.authorize({:managed, fresh.id}, @protected)

            assert {:error, :denied} = Sessions.authorize({:managed, before.id}, @protected)
          after
            Task.shutdown(rewrite, :brutal_kill)
          end
        end)
      end
    end
  end

  defp create(conv, user, %Account{} = account) do
    Sessions.create(%{
      conversation_id: conv.id,
      user_id: user.id,
      rules: [],
      ttl_seconds: 600,
      managed: ref(account)
    })
  end

  defp ref(%Account{user_id: nil} = a),
    do: %{owner: :platform, grant_id: a.id, generation: a.generation}

  defp ref(%Account{user_id: user_id} = a),
    do: %{owner: {:user, user_id}, grant_id: a.id, generation: a.generation}

  defp sessions(conv),
    do: Repo.all(from s in Session, where: s.conversation_id == ^conv.id, order_by: s.inserted_at)

  defp end_generation(%Account{user_id: nil}), do: ChatGPTAccounts.platform_disconnect()

  defp end_generation(%Account{id: id, user_id: user_id}),
    do: ChatGPTAccounts.disconnect_for_user(id, user_id)

  defp reconnect(%Account{user_id: nil}), do: connect!(%{refresh_token: "rt_again"})

  defp reconnect(%Account{id: id, user_id: user_id, account_id: account_id}) do
    {:ok, _view} =
      ChatGPTAccounts.reconnect_for_user(id, user_id, %{
        access_token: access_token(),
        refresh_token: "rt_again",
        id_token: id_token(%{account_id: account_id})
      })

    Repo.get!(Account, id)
  end

  # A committed user, conversation and grant of the owner under test, all
  # gone again afterwards whatever the test did.
  defp with_conversation(owner, fun) do
    Sandbox.unboxed_run(Repo, fn ->
      # Verified by hand: `verify_email/1` commits a starter agent, a ledger
      # entry and a mail job, none of which this test wants to clean up.
      user =
        insert_user() |> change(email_verified_at: ~U[2026-09-01 00:00:00Z]) |> Repo.update!()

      conv = insert_conversation(user_id: user.id)

      try do
        account = if owner == :platform, do: connect!(), else: user_grant!(user.id)
        fun.(user, conv, account)
      after
        Repo.delete_all(from a in Account, where: is_nil(a.user_id))
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)

        Repo.delete_all(
          from e in Fountain.Audit.AdminEvent,
            where: like(e.event_type, "admin.platform_chatgpt.%")
        )

        Repo.delete!(user)
        Repo.delete_all(from s in Fountain.Conversations.Sandbox, where: s.id == ^conv.sandbox_id)
      end
    end)
  end

  # Runs `fun` in a session of its own and parks it right after the first
  # statement `match?` accepts, until `:continue`. The handler runs in the
  # querying process, once the statement has returned.
  defp paused(match?, fun) do
    handler_id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler_id, [:fountain, :repo, :query], &__MODULE__.pause/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    independent(fn ->
      Process.put(:pause_when, match?)
      fun.()
    end)
  end

  @doc false
  def pause(_event, _measurements, metadata, owner) do
    case Process.get(:pause_when) do
      match? when is_function(match?, 1) ->
        if match?.(metadata.query) do
          Process.delete(:pause_when)
          send(owner, {:paused, self()})

          receive do
            :continue -> :ok
          after
            10_000 -> raise "the paused statement was not released"
          end
        end

      _ ->
        :ok
    end
  end

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
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
             "the competing operation did not wait on the grant row"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
