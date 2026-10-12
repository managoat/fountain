defmodule Fountain.ChatGPTDeletionTest do
  # ADR 0060 stage 5: what an account deletion does with the ChatGPT
  # subscriptions an account linked. One account holds two grants, one linked through a real sign-in so
  # its audit events are the real ones, and an open and an ended sign-in.
  # `async: false`: the broker, the flag and the auth stub are shared.
  use Fountain.DataCase, async: false

  import Fountain.BrokerTestHelpers
  import Fountain.ChatGPTFixtures
  import Swoosh.TestAssertions

  alias Fountain.Accounts.Deletion
  alias Fountain.Audit.Event
  alias Fountain.Broker
  alias Fountain.Broker.Native.Session
  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.LinkAttempt
  alias Fountain.InferenceCredentials
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.PlatformChatGPT.OAuth
  alias Fountain.Workers.{AccountEmail, ChatGPTGrantKeepalive}

  # Distinctive on purpose, so a substring assertion cannot pass by accident.
  @account_a "acct-EXPORT-CANARY-a"
  @account_b "acct-EXPORT-CANARY-b"
  @refresh_a "rt_EXPORT_CANARY_a"
  @refresh_b "rt_EXPORT_CANARY_b"
  @user_code "CNRY-4242"
  @device_auth_id "deviceauth_EXPORT_CANARY"
  @long_ago ~U[2020-01-01 00:00:00Z]

  setup do
    enable_chatgpt_subscriptions()
    %{user: insert_verified_user(), other: insert_verified_user()}
  end

  # Two grants, a set naming one, a completed sign-in, a cancelled one and an
  # open one, whose poller is queued.
  defp link_everything(user) do
    access_a = access_token(3_600, %{"canary" => "export-a"})
    access_b = access_token(3_600, %{"canary" => "export-b"})

    start = device_start(self(), %{user_code: @user_code, device_auth_id: @device_auth_id})

    start! = fn target ->
      {:ok, view} = ChatGPTAccounts.start_attempt_for_user(user.id, target, device_start: start)
      view
    end

    completed = start!.(%{name: "Work"})

    {:ok, _} =
      ChatGPTAccounts.complete_attempt_for_user(
        completed.id,
        user.id,
        user_tokens(@account_a, access: access_a, refresh: @refresh_a)
      )

    [%{grant_id: a_id}] = ChatGPTAccounts.list_for_user(user.id)
    a = Repo.get!(Account, a_id)

    b =
      user_grant!(user.id, %{
        name: "Personal",
        account_id: @account_b,
        access_token: access_b,
        refresh_token: @refresh_b,
        last_refreshed_at: @long_ago
      })

    {:ok, set} = InferenceCredentials.create_set(user.id, "Codex on work")
    {:ok, _} = InferenceCredentials.set_grant(set, a.id)

    cancelled = start!.(%{grant_id: b.id})
    {:ok, _} = ChatGPTAccounts.cancel_attempt_for_user(cancelled.id, user.id)
    open = start!.(%{name: "Side project"})

    %{
      a: a,
      b: b,
      access: [access_a, access_b],
      attempts: %{completed: completed, cancelled: cancelled, open: open}
    }
  end

  describe "deleting the account" do
    setup do
      keys = [:broker_listen_port, :broker_proxy_url]
      previous = for key <- keys, do: {key, Application.get_env(:fountain, key)}

      on_exit(fn ->
        for {key, value} <- previous do
          if is_nil(value),
            do: Application.delete_env(:fountain, key),
            else: Application.put_env(:fountain, key, value)
        end
      end)

      Application.put_env(:fountain, :broker_listen_port, 0)
      Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
      :ok
    end

    # Any request at all to the auth server reaches the test as a message.
    defp watch_auth_server do
      test_pid = self()
      Req.Test.set_req_test_to_shared(%{})

      Req.Test.stub(OAuth, fn conn ->
        send(test_pid, {:auth_call, conn.request_path})
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end)
    end

    defp managed_session!(user, grant) do
      conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
      managed = %{owner: {:user, user.id}, grant_id: grant.id, generation: grant.generation}

      {:ok, _} =
        Broker.prepare(conv.id, %{"GITHUB_TOKEN" => "ghp_x"}, %{},
          user_id: user.id,
          managed: managed
        )

      Repo.one!(from(s in Session, where: s.conversation_id == ^conv.id))
    end

    defp keepalive_job!(grant) do
      {:ok, job} =
        %{grant_id: grant.id, user_id: grant.user_id, generation: grant.generation}
        |> ChatGPTGrantKeepalive.new()
        |> Oban.insert()

      job
    end

    test "removes both grants, their sign-ins and their broker sessions, counts them, and leaves another account's alone",
         %{user: user, other: other} do
      %{a: a, b: b, attempts: attempts} = link_everything(user)
      sessions = [managed_session!(user, a), managed_session!(user, b)]
      assert Enum.map(sessions, & &1.managed_grant_id) == [a.id, b.id]

      theirs = user_grant!(other.id, %{name: "Theirs"})
      their_session = managed_session!(other, theirs)

      {:ok, their_attempt} =
        ChatGPTAccounts.start_attempt_for_user(other.id, %{name: "Theirs too"},
          device_start: device_start(self())
        )

      assert {:ok, _} = Deletion.delete_user(user)

      # The set's key on the grant is deferred to COMMIT, which a sandboxed
      # test never reaches. This is the check COMMIT would have made, for
      # every deferred constraint at once (stage 2's idiom).
      Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

      assert Repo.all(from(g in Account, where: g.id in ^[a.id, b.id])) == []
      assert Repo.all(from(g in Account, where: g.user_id == ^user.id)) == []
      assert Repo.all(from(l in LinkAttempt, where: l.user_id == ^user.id)) == []
      for {_, view} <- attempts, do: refute(Repo.get(LinkAttempt, view.id))
      for session <- sessions, do: refute(Repo.get(Session, session.id))
      assert InferenceCredentials.list_sets(user.id) == []

      event = Repo.one!(from(e in Event, where: e.action == "account.deleted"))
      assert event.metadata["chatgpt_grants_removed"] == 2
      assert event.metadata["user_id"] == user.id

      assert Repo.get!(Account, theirs.id) == theirs
      assert Repo.get!(Session, their_session.id).managed_grant_id == theirs.id
      assert Repo.get(LinkAttempt, their_attempt.id)
      assert [%{name: "Theirs"}] = ChatGPTAccounts.list_for_user(other.id)
    end

    test "a tombstone is counted: its sign-in was never revoked at OpenAI either", %{user: user} do
      grant = user_grant!(user.id)
      :ok = ChatGPTAccounts.disconnect_for_user(grant.id, user.id)

      assert {:ok, _} = Deletion.delete_user(user)
      Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

      event = Repo.one!(from(e in Event, where: e.action == "account.deleted"))
      assert event.metadata["chatgpt_grants_removed"] == 1
    end

    test "an account that linked nothing counts zero and its email says nothing of ChatGPT", %{
      user: user
    } do
      assert {:ok, _} = Deletion.delete_user(user)
      event = Repo.one!(from(e in Event, where: e.action == "account.deleted"))
      assert event.metadata["chatgpt_grants_removed"] == 0

      assert [job] = all_enqueued(worker: AccountEmail)
      assert job.args == %{"kind" => "deleted", "email" => user.email}
      assert :ok = perform_job(AccountEmail, job.args)

      assert_email_sent(fn email ->
        refute email.text_body =~ "ChatGPT"
        refute email.html_body =~ "ChatGPT"
        assert email.text_body =~ "permanently deleted"
      end)
    end

    test "the queued keepalive and sign-in jobs end quietly, and the auth server is not asked", %{
      user: user
    } do
      %{a: a, b: b} = link_everything(user)
      keepalives = [keepalive_job!(a), keepalive_job!(b)]
      # One poller per sign-in begun; an ended attempt's is still queued.
      assert length(all_enqueued(queue: :chatgpt)) == 3

      watch_auth_server()
      assert {:ok, _} = Deletion.delete_user(user)

      assert %{cancelled: 2, success: 0, failure: 0, snoozed: 0} =
               Oban.drain_queue(queue: :chatgpt_refresh, with_scheduled: true)

      for job <- keepalives do
        assert %{state: "cancelled"} = Repo.get!(Oban.Job, job.id)
      end

      assert %{success: 3, failure: 0, snoozed: 0, cancelled: 0, discard: 0} =
               Oban.drain_queue(queue: :chatgpt, with_scheduled: true)

      refute_received {:auth_call, _}
    end

    test "the email says the sign-ins were not revoked at OpenAI, and what to do", %{user: user} do
      link_everything(user)
      assert {:ok, _} = Deletion.delete_user(user)

      assert [job] = all_enqueued(worker: AccountEmail)
      assert job.args["chatgpt_subscriptions"] == 2
      assert Map.keys(job.args) |> Enum.sort() == ~w(chatgpt_subscriptions email kind)
      assert :ok = perform_job(AccountEmail, job.args)

      assert_email_sent(fn email ->
        for body <- [email.text_body, email.html_body] do
          assert body =~ "the 2 ChatGPT subscriptions you linked"
          assert body =~ "cannot revoke a sign-in at OpenAI"
          assert body =~ "sign the device out in your ChatGPT account"
          refute body =~ @account_a
          refute body =~ "Work"
        end

        assert email.text_body =~ "permanently deleted"
      end)
    end

    test "one subscription reads in the singular" do
      assert {:ok, _} =
               Fountain.Emails.UserEmails.deliver_account_deleted_email("gone@example.com",
                 chatgpt_subscriptions: 1
               )

      assert_email_sent(fn email ->
        assert email.text_body =~ "for the ChatGPT subscription you linked, but"
      end)
    end
  end
end
