defmodule Fountain.Workers.ChatGPTLinkAttemptTest do
  # ADR 0060 stage 4: the job that drives a sign-in, against a stubbed
  # `auth.openai.com`. `async: false`: the stub is shared, and the broker and
  # the flag are application state.
  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog
  import Fountain.BrokerTestHelpers
  import Fountain.ChatGPTFixtures

  alias Fountain.Audit.Event
  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.{Grant, LinkAttempt}
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.Workers.ChatGPTLinkAttempt, as: Worker

  @user_code "WXYZ-9876"
  @device_auth_id "deviceauth_worker_1"
  @authorization_code "authcode_SECRET_1"
  @verifier "verifier_SECRET_1"
  @refresh_token "rt_SECRET_from_device"

  setup do
    enable_chatgpt_subscriptions()
    %{user: insert_verified_user()}
  end

  # The three legs. `poll` and `exchange` are functions of the decoded body.
  defp stub_legs(handlers) do
    test_pid = self()

    stub_auth(%{
      "/api/accounts/deviceauth/usercode" => fn _body ->
        {200, %{"user_code" => @user_code, "device_auth_id" => @device_auth_id, "interval" => 7}}
      end,
      "/api/accounts/deviceauth/token" => fn body ->
        send(test_pid, {:polled, body})
        Map.get(handlers, :poll, fn _ -> {403, %{}} end).(body)
      end,
      "/oauth/token" => fn body ->
        send(test_pid, {:exchanged, body})
        Map.fetch!(handlers, :exchange).(body)
      end
    })
  end

  defp approved(_body),
    do: {200, %{"authorization_code" => @authorization_code, "code_verifier" => @verifier}}

  defp tokens_for(account_id, access) do
    fn _body ->
      {200,
       %{
         "access_token" => access,
         "refresh_token" => @refresh_token,
         "id_token" => id_token(%{account_id: account_id, email: "owner@example.com"})
       }}
    end
  end

  defp start!(user, target) do
    {:ok, view} = ChatGPTAccounts.start_attempt_for_user(user.id, target)
    view
  end

  defp run(view, user),
    do: perform_job(Worker, %{"attempt_id" => view.id, "user_id" => user.id})

  defp grants(user), do: Repo.all(from(a in Account, where: a.user_id == ^user.id))

  defp actions(user) do
    Repo.all(
      from(e in Event,
        where: e.user_id == ^user.id and like(e.action, "chatgpt_%"),
        order_by: [asc: e.inserted_at, asc: e.id],
        select: {e.action, e.actor}
      )
    )
  end

  describe "a job that was lost" do
    defp jobs(attempt_id) do
      Repo.all(
        from(j in Oban.Job,
          where: fragment("?->>'attempt_id' = ?", j.args, ^attempt_id),
          order_by: [asc: j.id]
        )
      )
    end

    test "comes back when the attempt is read, once, and only while it is pending",
         %{user: user} do
      stub_legs(%{})
      {:ok, attempt} = ChatGPTAccounts.start_attempt_for_user(user.id, %{name: "Work"})
      assert [%Oban.Job{id: first}] = jobs(attempt.id)

      # A read of an attempt that is being polled inserts nothing.
      assert {:ok, _} = ChatGPTAccounts.get_attempt_for_user(attempt.id, user.id)
      assert [%Oban.Job{id: ^first}] = jobs(attempt.id)

      # Orphaned in `executing`, it is still incomplete: nothing replaces it.
      Repo.update_all(from(j in Oban.Job, where: j.id == ^first), set: [state: "executing"])
      assert {:ok, _} = ChatGPTAccounts.get_attempt_for_user(attempt.id, user.id)
      assert [%Oban.Job{id: ^first}] = jobs(attempt.id)

      Repo.update_all(from(j in Oban.Job, where: j.id == ^first), set: [state: "discarded"])
      assert {:ok, _} = ChatGPTAccounts.get_attempt_for_user(attempt.id, user.id)
      assert [_lost, %Oban.Job{state: "scheduled", args: args}] = jobs(attempt.id)
      assert args == %{"attempt_id" => attempt.id, "user_id" => user.id}

      assert [_] = ChatGPTAccounts.list_pending_attempts_for_user(user.id)
      assert [_lost, _one] = jobs(attempt.id)

      Repo.delete_all(Oban.Job)
      assert [_] = ChatGPTAccounts.list_pending_attempts_for_user(user.id)
      assert [%Oban.Job{state: "scheduled"}] = jobs(attempt.id)

      Repo.delete_all(Oban.Job)
      assert {:ok, _} = ChatGPTAccounts.cancel_attempt_for_user(attempt.id, user.id)

      assert {:ok, %{state: "cancelled"}} =
               ChatGPTAccounts.get_attempt_for_user(attempt.id, user.id)

      assert jobs(attempt.id) == []
    end
  end

  describe "a run that raised" do
    test "is retried in seconds however often the job has snoozed" do
      for attempt <- [1, 9, 60, 180] do
        job = %Oban.Job{attempt: attempt, max_attempts: attempt + 4}
        assert Worker.backoff(job) == 10
      end

      # Every retry the job has fits inside one attempt's time many times over.
      assert 10 * Worker.__opts__()[:max_attempts] <
               div(ChatGPTAccounts.LinkAttempts.ttl_seconds(), 4)
    end
  end

  describe "the job" do
    test "is inserted with the attempt, one interval out, and carries two ids and no secret",
         %{user: user} do
      stub_legs(%{})
      view = start!(user, %{name: "Work"})

      assert [job] = all_enqueued(worker: Worker)
      assert job.args == %{"attempt_id" => view.id, "user_id" => user.id}
      assert job.queue == "chatgpt"
      assert job.state == "scheduled"
      assert DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second) in 5..7

      printed = inspect(job, limit: :infinity, printable_limit: :infinity)
      refute printed =~ @user_code
      refute printed =~ @device_auth_id
    end

    test "a refused start enqueues nothing", %{user: user} do
      stub_legs(%{})
      chatgpt_subscriptions_flag(false)

      assert {:error, :subscriptions_not_enabled} =
               ChatGPTAccounts.start_attempt_for_user(user.id, %{name: "Work"})

      assert all_enqueued(worker: Worker) == []
    end

    test "a second insert for the same attempt is the same job", %{user: user} do
      stub_legs(%{})
      view = start!(user, %{name: "Work"})
      attempt = Repo.get!(LinkAttempt, view.id)

      assert {:ok, %Oban.Job{conflict?: true}} = Worker.enqueue(attempt)
      assert [_one] = all_enqueued(worker: Worker)
    end
  end

  describe "a run" do
    test "while the code is unapproved asks once with the stored secrets and snoozes for the " <>
           "server's interval",
         %{user: user} do
      stub_legs(%{})
      view = start!(user, %{name: "Work"})

      assert {:snooze, 7} = run(view, user)

      assert_received {:polled, %{"device_auth_id" => @device_auth_id, "user_code" => @user_code}}
      refute_received {:polled, _}
      refute_received {:exchanged, _}

      assert %LinkAttempt{state: "pending", poll_failures: 0} = Repo.get!(LinkAttempt, view.id)
      assert grants(user) == []
    end

    test "on approval exchanges the code and links the grant, as the system", %{user: user} do
      access = access_token(3_600, %{"label" => "from-device"})
      stub_legs(%{poll: &approved/1, exchange: tokens_for("acct-work", access)})
      view = start!(user, %{name: "Work"})

      assert :ok = run(view, user)

      assert_received {:exchanged,
                       %{
                         "grant_type" => "authorization_code",
                         "code" => @authorization_code,
                         "code_verifier" => @verifier
                       }}

      assert [%Account{name: "Work", account_id: "acct-work", status: "active"} = grant] =
               grants(user)

      assert {:ok, %Grant{access_token: ^access}} =
               ChatGPTAccounts.credential_for_user(grant.id, user.id, grant.generation)

      assert %LinkAttempt{state: "completed", result_grant_id: result} =
               Repo.get!(LinkAttempt, view.id)

      assert result == grant.id

      assert actions(user) == [
               {"chatgpt_link_attempt.started", "self"},
               {"chatgpt_grant.connected", "system:chatgpt_link_attempt"}
             ]

      # Nothing the auth server said is on the trail: not the email either.
      trail = inspect(Repo.all(from(e in Event, where: e.user_id == ^user.id)))

      for secret <- [@refresh_token, @authorization_code, @verifier, access, "owner@example.com"],
          do: refute(trail =~ secret)
    end

    test "again after it finished asks nobody and writes nothing", %{user: user} do
      stub_legs(%{poll: &approved/1, exchange: tokens_for("acct-work", access_token())})
      view = start!(user, %{name: "Work"})
      assert :ok = run(view, user)
      assert_received {:polled, _}
      assert_received {:exchanged, _}

      [grant] = grants(user)
      events = actions(user)

      assert :ok = run(view, user)

      refute_received {:polled, _}
      refute_received {:exchanged, _}
      assert grants(user) == [grant]
      assert actions(user) == events
    end

    test "for a cancelled attempt asks nobody", %{user: user} do
      stub_legs(%{poll: &approved/1, exchange: tokens_for("acct-work", access_token())})
      view = start!(user, %{name: "Work"})
      assert {:ok, _} = ChatGPTAccounts.cancel_attempt_for_user(view.id, user.id)

      assert :ok = run(view, user)

      refute_received {:polled, _}
      assert grants(user) == []
    end

    test "past the attempt's time asks nobody and writes it expired", %{user: user} do
      stub_legs(%{poll: &approved/1, exchange: tokens_for("acct-work", access_token())})
      view = start!(user, %{name: "Work"})

      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(a in LinkAttempt, where: a.id == ^view.id), set: [expires_at: past])

      assert :ok = run(view, user)

      refute_received {:polled, _}
      assert grants(user) == []
      assert %LinkAttempt{state: "expired"} = Repo.get!(LinkAttempt, view.id)

      assert {"chatgpt_link_attempt.expired", "system:chatgpt_link_attempt"} =
               List.last(actions(user))
    end

    test "for an attempt that is gone, or somebody else's, is :ok", %{user: user} do
      stub_legs(%{poll: &approved/1, exchange: tokens_for("acct-work", access_token())})
      view = start!(user, %{name: "Work"})
      other = insert_verified_user()

      assert :ok = perform_job(Worker, %{"attempt_id" => view.id, "user_id" => other.id})

      assert :ok =
               perform_job(Worker, %{
                 "attempt_id" => Ecto.UUID.generate(),
                 "user_id" => user.id
               })

      refute_received {:polled, _}
      assert grants(user) == [] and grants(other) == []
      assert %LinkAttempt{state: "pending"} = Repo.get!(LinkAttempt, view.id)
    end

    test "a reconnect that lands after a newer sign-in fails the attempt and leaves the " <>
           "newer credential",
         %{user: user} do
      {:ok, grant} = ChatGPTAccounts.connect_for_user(user.id, "Work", user_tokens("acct-work"))

      stub_legs(%{poll: &approved/1, exchange: tokens_for("acct-work", access_token())})
      view = start!(user, %{grant_id: grant.grant_id})

      {:ok, _newer} =
        ChatGPTAccounts.reconnect_for_user(grant.grant_id, user.id, user_tokens("acct-work"))

      row = Repo.get!(Account, grant.grant_id)

      assert :ok = run(view, user)

      assert Repo.get!(Account, grant.grant_id) == row

      assert %LinkAttempt{state: "failed", failure_reason: "stale_grant"} =
               Repo.get!(LinkAttempt, view.id)

      assert {"chatgpt_link_attempt.failed", "system:chatgpt_link_attempt"} =
               List.last(actions(user))
    end
  end

  describe "linking turned off while the code was out" do
    test "an approved new link is not exchanged, and fails as linking_disabled", %{user: user} do
      stub_legs(%{poll: &approved/1, exchange: tokens_for("acct-work", "unused")})
      view = start!(user, %{name: "Work"})
      chatgpt_subscriptions_flag(false)

      assert :ok = run(view, user)
      assert_received {:polled, _}
      refute_received {:exchanged, _}
      assert grants(user) == []

      assert %LinkAttempt{state: "failed", failure_reason: "linking_disabled"} =
               Repo.get!(LinkAttempt, view.id)
    end
  end

  describe "an auth server that does not answer" do
    test "is asked again later and less often, and the count clears when it answers",
         %{user: user} do
      stub_legs(%{poll: fn _ -> {503, %{"error" => "unavailable"}} end})
      view = start!(user, %{name: "Work"})

      log =
        capture_log(fn ->
          assert {:snooze, 14} = run(view, user)
          assert {:snooze, 28} = run(view, user)
          assert {:snooze, 56} = run(view, user)
          assert {:snooze, 60} = run(view, user)
        end)

      assert log =~ "status 503"
      assert %LinkAttempt{state: "pending", poll_failures: 4} = Repo.get!(LinkAttempt, view.id)

      stub_legs(%{})
      assert {:snooze, 7} = run(view, user)
      assert %LinkAttempt{poll_failures: 0} = Repo.get!(LinkAttempt, view.id)
    end

    test "is said to the page when it stops answering and when it answers again, and not between",
         %{user: user} do
      user_id = user.id
      stub_legs(%{poll: fn _ -> {503, %{}} end})
      view = start!(user, %{name: "Work"})
      refute view.auth_unreachable
      ChatGPTAccounts.subscribe(user.id)

      capture_log(fn -> run(view, user) end)
      assert_receive {:chatgpt_grants_changed, ^user_id}

      assert {:ok, %{state: "pending", auth_unreachable: true}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)

      capture_log(fn -> run(view, user) end)
      refute_receive {:chatgpt_grants_changed, _}, 50

      stub_legs(%{})
      run(view, user)
      assert_receive {:chatgpt_grants_changed, ^user_id}

      assert {:ok, %{auth_unreachable: false}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)

      # A poll that is answered "not yet" every time says nothing.
      run(view, user)
      refute_receive {:chatgpt_grants_changed, _}, 50
    end

    test "an attempt that has ended does not read unreachable", %{user: user} do
      stub_legs(%{poll: fn _ -> {503, %{}} end})
      view = start!(user, %{name: "Work"})
      capture_log(fn -> run(view, user) end)

      assert {:ok, %{state: "cancelled", auth_unreachable: false}} =
               ChatGPTAccounts.cancel_attempt_for_user(view.id, user.id)
    end

    test "a rate limit is patience, not a refusal", %{user: user} do
      stub_legs(%{poll: fn _ -> {429, %{"error" => "slow_down"}} end})
      view = start!(user, %{name: "Work"})

      capture_log(fn -> assert {:snooze, 14} = run(view, user) end)
      assert %LinkAttempt{state: "pending"} = Repo.get!(LinkAttempt, view.id)
    end
  end

  describe "an auth server that refuses" do
    test "the code: the attempt fails, with the server's words in neither the row nor the log",
         %{user: user} do
      stub_legs(%{
        poll: fn _ ->
          {400, %{"error" => "access_denied", "error_description" => "echo #{@user_code}"}}
        end
      })

      view = start!(user, %{name: "Work"})

      log = capture_log(fn -> assert :ok = run(view, user) end)

      assert log =~ "authorization_failed: status 400"
      refute log =~ @user_code
      refute log =~ @device_auth_id

      assert %LinkAttempt{
               state: "failed",
               failure_reason: "authorization_failed",
               user_code_ciphertext: nil
             } = Repo.get!(LinkAttempt, view.id)

      assert grants(user) == []
    end

    test "the exchange: the attempt fails and no grant is stored", %{user: user} do
      stub_legs(%{
        poll: &approved/1,
        exchange: fn _ -> {400, %{"error" => %{"code" => "invalid_grant"}}} end
      })

      view = start!(user, %{name: "Work"})

      log = capture_log(fn -> assert :ok = run(view, user) end)

      refute log =~ @authorization_code
      refute log =~ @verifier

      assert %LinkAttempt{state: "failed", failure_reason: "exchange_failed"} =
               Repo.get!(LinkAttempt, view.id)

      assert grants(user) == []
    end
  end

  describe "retention" do
    test "an attempt that ended a week ago is deleted; an open one and a recent one are not",
         %{user: user} do
      stub_legs(%{})
      old = start!(user, %{name: "Old"})
      recent = start!(user, %{name: "Recent"})
      open = start!(user, %{name: "Open"})

      for view <- [old, recent],
          do: {:ok, _} = ChatGPTAccounts.cancel_attempt_for_user(view.id, user.id)

      long_ago = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      Repo.update_all(from(a in LinkAttempt, where: a.id == ^old.id), set: [updated_at: long_ago])

      assert ChatGPTAccounts.purge_ended_attempts() == 1

      refute Repo.get(LinkAttempt, old.id)
      assert Repo.get(LinkAttempt, recent.id)
      assert Repo.get(LinkAttempt, open.id)
    end

    test "a pending row a week past its time, whose job was lost, is deleted too",
         %{user: user} do
      stub_legs(%{})
      lost = start!(user, %{name: "Lost"})

      long_ago = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)

      Repo.update_all(from(a in LinkAttempt, where: a.id == ^lost.id),
        set: [expires_at: long_ago]
      )

      assert :ok = perform_job(Fountain.Workers.RetentionPruner, %{})
      refute Repo.get(LinkAttempt, lost.id)
    end
  end
end
