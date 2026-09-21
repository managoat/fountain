defmodule Fountain.ChatGPTLinkAttemptCompletionTest do
  # ADR 0060 stage 4: what a sign-in's tokens may and may not do when they
  # arrive (0052 decision 2, "completion rechecks owner eligibility,
  # cancellation, expiry, and grant generation before storing anything").
  # Every refusal asserts the rows, not only the answer. `async: false`: the
  # broker, the flag and the ceiling are application state, and the last
  # describe commits.
  use Fountain.DataCase, async: false

  import Fountain.BrokerTestHelpers
  import Fountain.ChatGPTFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.Audit.Event
  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.{AttemptView, Grant, LinkAttempt}
  alias Fountain.PlatformChatGPT.Account

  setup do
    enable_chatgpt_subscriptions()
    :ok
  end

  defp start!(user, target) do
    {:ok, view} =
      ChatGPTAccounts.start_attempt_for_user(user.id, target, device_start: device_start(self()))

    view
  end

  defp complete(view, user, tokens, opts \\ []),
    do: ChatGPTAccounts.complete_attempt_for_user(view.id, user.id, tokens, opts)

  defp link!(user, name, account_id, token_opts \\ []) do
    {:ok, grant} =
      ChatGPTAccounts.connect_for_user(user.id, name, user_tokens(account_id, token_opts))

    grant
  end

  defp bearer(label), do: jwt(%{"exp" => 4_102_444_800, "label" => label})

  defp grants(user),
    do: Repo.all(from(a in Account, where: a.user_id == ^user.id, order_by: a.name))

  defp actions(user) do
    Repo.all(
      from(e in Event,
        where: e.user_id == ^user.id and like(e.action, "chatgpt_%"),
        order_by: [asc: e.inserted_at, asc: e.id],
        select: e.action
      )
    )
  end

  defp failed_event(user) do
    Repo.one!(
      from(e in Event,
        where: e.user_id == ^user.id and e.action == "chatgpt_link_attempt.failed"
      )
    )
  end

  defp overdue!(attempt_id) do
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(a in LinkAttempt, where: a.id == ^attempt_id), set: [expires_at: past])
  end

  describe "a link" do
    setup do
      %{user: insert_verified_user(), other: insert_verified_user()}
    end

    test "stores the grant and ends the attempt in one write", %{user: user} do
      ChatGPTAccounts.subscribe(user.id)
      view = start!(user, %{name: "Work"})
      assert_receive {:chatgpt_grants_changed, _}

      tokens = user_tokens("acct-work", access: bearer("work"))

      assert {:ok, %AttemptView{state: "completed", user_code: nil, failure: nil} = done} =
               complete(view, user, tokens, actor: "system:chatgpt_link_attempt")

      assert [%Account{name: "Work", status: "active", account_id: "acct-work"} = grant] =
               grants(user)

      assert done.result_grant_id == grant.id

      assert %LinkAttempt{
               state: "completed",
               user_code_ciphertext: nil,
               device_auth_ciphertext: nil
             } = Repo.get!(LinkAttempt, view.id)

      assert {:ok, %Grant{access_token: access}} =
               ChatGPTAccounts.credential_for_user(grant.id, user.id, grant.generation)

      assert access == bearer("work")

      assert actions(user) == ["chatgpt_link_attempt.started", "chatgpt_grant.connected"]

      # The job has no address and the system's name: the attempt's id is what
      # ties this event to the `started` that says who began it.
      assert %{actor: "system:chatgpt_link_attempt", metadata: metadata} =
               Repo.get_by!(Event, user_id: user.id, action: "chatgpt_grant.connected")

      assert metadata == %{
               "name" => "Work",
               "method" => "device_code",
               "plan" => "pro",
               "attempt_id" => view.id
             }

      user_id = user.id
      assert_receive {:chatgpt_grants_changed, ^user_id}
    end

    test "a replay writes nothing: one grant, one event, the same ciphertext", %{user: user} do
      view = start!(user, %{name: "Work"})
      assert {:ok, done} = complete(view, user, user_tokens("acct-work"))

      [grant] = grants(user)
      attempt = Repo.get!(LinkAttempt, view.id)
      events = actions(user)

      # The same tokens again, and another account's: neither is looked at.
      assert {:ok, ^done} = complete(view, user, user_tokens("acct-work"))
      assert {:ok, ^done} = complete(view, user, user_tokens("acct-other", access: bearer("x")))

      assert grants(user) == [grant]
      assert Repo.get!(LinkAttempt, view.id) == attempt
      assert actions(user) == events
    end

    test "after a cancel it stores no grant", %{user: user} do
      view = start!(user, %{name: "Work"})
      assert {:ok, _} = ChatGPTAccounts.cancel_attempt_for_user(view.id, user.id)
      cancelled = Repo.get!(LinkAttempt, view.id)

      assert {:error, {:link_attempt_not_pending, %{state: "cancelled"}}} =
               complete(view, user, user_tokens("acct-work"))

      assert grants(user) == []
      assert Repo.get!(LinkAttempt, view.id) == cancelled
      assert actions(user) == ["chatgpt_link_attempt.started", "chatgpt_link_attempt.cancelled"]
    end

    test "after its time it stores no grant, and the row says expired", %{user: user} do
      view = start!(user, %{name: "Work"})
      overdue!(view.id)

      assert {:error, {:link_attempt_not_pending, %{state: "expired"}}} =
               complete(view, user, user_tokens("acct-work"))

      assert grants(user) == []
      assert %LinkAttempt{state: "expired"} = Repo.get!(LinkAttempt, view.id)
      assert actions(user) == ["chatgpt_link_attempt.started", "chatgpt_link_attempt.expired"]
    end

    test "another account cannot complete it", %{user: user, other: other} do
      view = start!(user, %{name: "Work"})
      before = Repo.get!(LinkAttempt, view.id)

      assert {:error, :not_found} = complete(view, other, user_tokens("acct-work"))

      assert grants(user) == [] and grants(other) == []
      assert Repo.get!(LinkAttempt, view.id) == before
    end

    test "an upstream account the user already holds is refused by the grant's name, " <>
           "and that grant is untouched",
         %{user: user} do
      link!(user, "Work", "acct-work", access: bearer("first"))
      [work] = grants(user)
      view = start!(user, %{name: "Personal"})

      assert {:error, {:account_already_linked, %{grant_id: held, name: "Work"}}} =
               complete(view, user, user_tokens("acct-work", access: bearer("second")))

      assert held == work.id
      assert grants(user) == [work]

      assert {:ok,
              %AttemptView{
                state: "failed",
                user_code: nil,
                result_grant_id: nil,
                failure: %{reason: "account_already_linked", grant_id: ^held, grant: "Work"}
              }} = ChatGPTAccounts.get_attempt_for_user(view.id, user.id)

      assert %{metadata: metadata, actor: "self"} = failed_event(user)

      assert metadata == %{
               "kind" => "link",
               "name" => "Personal",
               "reason" => "account_already_linked"
             }
    end

    test "the ceiling is asked again when the tokens arrive", %{user: user} do
      previous = Application.fetch_env!(:fountain, :chatgpt_grant_ceiling)
      Application.put_env(:fountain, :chatgpt_grant_ceiling, 2)
      on_exit(fn -> Application.put_env(:fountain, :chatgpt_grant_ceiling, previous) end)

      link!(user, "Work", "acct-work")
      first = start!(user, %{name: "Personal"})
      second = start!(user, %{name: "Side"})

      assert {:ok, %{state: "completed"}} = complete(first, user, user_tokens("acct-personal"))

      assert {:error, {:grant_limit_reached, %{count: 2, limit: 2}}} =
               complete(second, user, user_tokens("acct-side"))

      assert [%{name: "Personal"}, %{name: "Work"}] = grants(user)

      assert {:ok, %{state: "failed", failure: %{reason: "grant_limit_reached"}}} =
               ChatGPTAccounts.get_attempt_for_user(second.id, user.id)
    end

    test "a name taken since the attempt began fails it", %{user: user} do
      view = start!(user, %{name: "Work"})
      link!(user, "Work", "acct-first")
      [first] = grants(user)

      assert {:error, %Ecto.Changeset{}} = complete(view, user, user_tokens("acct-second"))

      assert grants(user) == [first]

      assert {:ok, %{state: "failed", failure: %{reason: "name_taken"}}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)
    end

    test "an owner who may no longer link gets no grant", %{user: user} do
      view = start!(user, %{name: "Work"})
      user |> change(%{suspended_at: ~U[2026-09-01 00:00:00Z]}) |> Repo.update!()

      assert {:error, :ineligible_owner} = complete(view, user, user_tokens("acct-work"))

      assert grants(user) == []

      assert {:ok, %{state: "failed", failure: %{reason: "owner_ineligible"}}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)
    end

    test "a sign-in with no refresh token is not a grant", %{user: user} do
      view = start!(user, %{name: "Work"})
      tokens = %{user_tokens("acct-work") | refresh_token: nil}

      assert {:error, :no_refresh_token} = complete(view, user, tokens)
      assert grants(user) == []

      assert {:ok, %{state: "failed", failure: %{reason: "invalid_sign_in"}}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)
    end
  end

  describe "a reconnect" do
    setup do
      user = insert_verified_user()
      grant = link!(user, "Work", "acct-work", access: bearer("old"))
      %{user: user, grant: grant}
    end

    test "keeps the old credential serving until it commits, then replaces it under the " <>
           "same id and name",
         %{user: user, grant: grant} do
      {:ok, set} = Fountain.InferenceCredentials.create_set(user.id, "codex")
      {:ok, set} = Fountain.InferenceCredentials.set_grant(set, grant.grant_id)

      view = start!(user, %{grant_id: grant.grant_id})

      assert {:ok, %Grant{access_token: old}} =
               ChatGPTAccounts.credential_for_user(grant.grant_id, user.id, grant.generation)

      assert old == bearer("old")

      assert {:ok, %AttemptView{state: "completed"} = done} =
               complete(view, user, user_tokens("acct-work", access: bearer("new")))

      assert done.result_grant_id == grant.grant_id

      assert {:ok, %{name: "Work", status: "active"} = replaced} =
               ChatGPTAccounts.get_for_user(grant.grant_id, user.id)

      refute replaced.generation == grant.generation
      assert Repo.reload!(set).chatgpt_grant_id == grant.grant_id

      # The old pin reads nothing; the new one reads the new bearer.
      assert {:error, _} =
               ChatGPTAccounts.credential_for_user(grant.grant_id, user.id, grant.generation)

      assert {:ok, %Grant{access_token: new}} =
               ChatGPTAccounts.credential_for_user(grant.grant_id, user.id, replaced.generation)

      assert new == bearer("new")

      attempt_id = view.id

      assert %{metadata: %{"reconnect" => true, "attempt_id" => ^attempt_id}} =
               Repo.one!(
                 from(e in Event,
                   where: e.user_id == ^user.id and e.action == "chatgpt_grant.connected",
                   order_by: [desc: e.inserted_at, desc: e.id],
                   limit: 1
                 )
               )
    end

    test "a late completion does not replace a newer credential", %{user: user, grant: grant} do
      late = start!(user, %{grant_id: grant.grant_id})

      # A newer sign-in commits while this one is still waiting for its code.
      assert {:ok, newer} =
               ChatGPTAccounts.reconnect_for_user(
                 grant.grant_id,
                 user.id,
                 user_tokens("acct-work", access: bearer("newer"))
               )

      row = Repo.get!(Account, grant.grant_id)

      assert {:error, :stale_grant} =
               complete(late, user, user_tokens("acct-work", access: bearer("late")))

      # Not one column of the newer credential moved.
      assert Repo.get!(Account, grant.grant_id) == row

      assert {:ok, %Grant{access_token: access}} =
               ChatGPTAccounts.credential_for_user(grant.grant_id, user.id, newer.generation)

      assert access == bearer("newer")

      assert {:ok, %{state: "failed", failure: %{reason: "stale_grant", grant_id: nil}}} =
               ChatGPTAccounts.get_attempt_for_user(late.id, user.id)

      assert %{metadata: metadata} = failed_event(user)

      assert metadata == %{
               "kind" => "reconnect",
               "grant_id" => grant.grant_id,
               "reason" => "stale_grant"
             }
    end

    test "a disconnect ends the open sign-in with it, and the next one is not in its way",
         %{user: user, grant: grant} do
      view = start!(user, %{grant_id: grant.grant_id})

      assert :ok =
               ChatGPTAccounts.disconnect_for_user(grant.grant_id, user.id,
                 actor: "api",
                 request_ip: "203.0.113.9"
               )

      tombstone = Repo.get!(Account, grant.grant_id)

      assert {:ok, %{state: "failed", user_code: nil, failure: %{reason: "stale_grant"}}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)

      assert %{actor: "api", request_ip: "203.0.113.9", metadata: %{"reason" => "stale_grant"}} =
               failed_event(user)

      # A completion that arrives afterwards does not undo the disconnect.
      assert {:error, {:link_attempt_not_pending, %{state: "failed"}}} =
               complete(view, user, user_tokens("acct-work"))

      assert Repo.get!(Account, grant.grant_id) == tombstone

      # A sign-in begun after the disconnect is how it comes back, and nothing
      # has to be cancelled first. Disconnecting again leaves that one alone.
      again = start!(user, %{grant_id: grant.grant_id})
      assert :ok = ChatGPTAccounts.disconnect_for_user(grant.grant_id, user.id)
      assert {:ok, %{state: "completed"}} = complete(again, user, user_tokens("acct-work"))
      assert {:ok, %{status: "active"}} = ChatGPTAccounts.get_for_user(grant.grant_id, user.id)
    end

    test "the fence alone holds against a disconnect that left the attempt open",
         %{user: user, grant: grant} do
      view = start!(user, %{grant_id: grant.grant_id})

      # A writer that is not the context's: the tombstone, and nothing else.
      tombstone =
        Account |> Repo.get!(grant.grant_id) |> Account.disconnect_changeset() |> Repo.update!()

      assert {:error, :stale_grant} = complete(view, user, user_tokens("acct-work"))
      assert Repo.get!(Account, grant.grant_id) == tombstone

      assert {:ok, %{state: "failed", failure: %{reason: "stale_grant"}}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)
    end

    test "a removal ends the sign-in open on the tombstone", %{user: user, grant: grant} do
      assert :ok = ChatGPTAccounts.disconnect_for_user(grant.grant_id, user.id)
      view = start!(user, %{grant_id: grant.grant_id})
      assert :ok = ChatGPTAccounts.remove_for_user(grant.grant_id, user.id)

      assert {:ok, %{state: "failed", failure: %{reason: "grant_not_found"}}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)

      assert {:error, {:link_attempt_not_pending, %{state: "failed"}}} =
               complete(view, user, user_tokens("acct-work"))

      assert grants(user) == []
    end

    test "a grant that is gone under an open attempt fails it by name",
         %{user: user, grant: grant} do
      view = start!(user, %{grant_id: grant.grant_id})
      Account |> Repo.get!(grant.grant_id) |> Repo.delete!()

      assert {:error, :not_found} = complete(view, user, user_tokens("acct-work"))
      assert grants(user) == []

      assert {:ok, %{state: "failed", failure: %{reason: "grant_not_found"}}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)
    end

    test "onto an account another of the user's grants holds is refused, naming that grant",
         %{user: user, grant: grant} do
      personal = link!(user, "Personal", "acct-personal")
      before = grants(user)
      view = start!(user, %{grant_id: grant.grant_id})

      assert {:error, {:account_already_linked, %{name: "Personal"}}} =
               complete(view, user, user_tokens("acct-personal"))

      assert grants(user) == before

      assert {:ok, %{failure: %{reason: "account_already_linked", grant: "Personal"} = failure}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)

      assert failure.grant_id == personal.grant_id
    end
  end

  # A cancel and a completion that really contend, each on a connection of
  # its own: the SQL sandbox's one transaction cannot show either. The idiom
  # is `broker/managed_grant_fence_test.exs`'s, and what is committed here is
  # deleted in `after`.
  describe "a cancel racing a completion" do
    test "a completion holding the attempt's row wins: the grant is linked and the cancel " <>
           "is told so" do
      with_attempt(fn user, view ->
        completer =
          paused(&locks_attempt?/1, fn -> complete(view, user, user_tokens("acct-race")) end)

        try do
          assert_receive {:paused, _pid}, 5_000

          canceller =
            independent(fn -> ChatGPTAccounts.cancel_attempt_for_user(view.id, user.id) end)

          canceller_pid = canceller.pid
          assert_receive {:backend, ^canceller_pid, backend}, 5_000
          await_blocked(backend)

          send(completer.pid, :continue)
          assert {:ok, %AttemptView{state: "completed"}} = Task.await(completer, 5_000)

          assert {:error, {:link_attempt_not_pending, %{state: "completed"}}} =
                   Task.await(canceller, 5_000)

          assert [%Account{name: "Race", status: "active"} = grant] = grants(user)

          assert %LinkAttempt{state: "completed", result_grant_id: result} =
                   Repo.get!(LinkAttempt, view.id)

          assert result == grant.id
          assert actions(user) == ["chatgpt_link_attempt.started", "chatgpt_grant.connected"]
        after
          Task.shutdown(completer, :brutal_kill)
        end
      end)
    end

    test "a cancel holding the attempt's row wins: the completion stores no grant" do
      with_attempt(fn user, view ->
        canceller =
          paused(&locks_attempt?/1, fn ->
            ChatGPTAccounts.cancel_attempt_for_user(view.id, user.id)
          end)

        try do
          assert_receive {:paused, _pid}, 5_000

          completer = independent(fn -> complete(view, user, user_tokens("acct-race")) end)
          completer_pid = completer.pid
          assert_receive {:backend, ^completer_pid, backend}, 5_000
          await_blocked(backend)

          send(canceller.pid, :continue)
          assert {:ok, %AttemptView{state: "cancelled"}} = Task.await(canceller, 5_000)

          assert {:error, {:link_attempt_not_pending, %{state: "cancelled"}}} =
                   Task.await(completer, 5_000)

          assert grants(user) == []
          assert %LinkAttempt{state: "cancelled"} = Repo.get!(LinkAttempt, view.id)

          assert actions(user) == [
                   "chatgpt_link_attempt.started",
                   "chatgpt_link_attempt.cancelled"
                 ]
        after
          Task.shutdown(canceller, :brutal_kill)
        end
      end)
    end
  end

  defp locks_attempt?(query), do: query =~ "chatgpt_link_attempts" and query =~ "FOR UPDATE"

  # A committed user with one open attempt, gone again afterwards whatever
  # the test did. Verified by hand: `verify_email/1` commits a starter agent,
  # a ledger entry and a mail job, none of which this test wants to clean up.
  defp with_attempt(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      user =
        insert_user() |> change(email_verified_at: ~U[2026-09-01 00:00:00Z]) |> Repo.update!()

      try do
        fun.(user, start!(user, %{name: "Race"}))
      after
        Repo.delete_all(from(e in Event, where: e.user_id == ^user.id))
        # The attempt's poller, committed with it.
        Repo.delete_all(from(j in Oban.Job, where: j.args["user_id"] == ^user.id))
        Repo.delete!(user)
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
             "the competing operation did not wait for the attempt"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
