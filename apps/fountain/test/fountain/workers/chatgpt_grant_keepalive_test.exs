defmodule Fountain.Workers.ChatGPTGrantKeepaliveTest do
  # ADR 0060 stage 5: one keepalive job per grant, run for real through the
  # application's refresh coordinator against a stubbed `auth.openai.com`.
  # `async: false`: the coordinator, the stub and the breaker are shared.
  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog
  import Fountain.ChatGPTFixtures

  alias Fountain.Audit.Event
  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.{Cipher, RefreshBreaker, RefreshCoordinator}
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.Workers.ChatGPTGrantKeepalive, as: Worker

  @long_ago ~U[2020-01-01 00:00:00Z]

  setup do
    RefreshBreaker.reset()
    on_exit(&RefreshBreaker.reset/0)
    :ok
  end

  # The token endpoint. `answers` maps a presented refresh token to a status
  # and body; every call reaches the test as `{:token_call, refresh_token}`,
  # which is how a test says the auth server was, or was not, asked.
  defp stub_token(answers) do
    test_pid = self()

    stub_auth(%{
      "/oauth/token" => fn body ->
        send(test_pid, {:token_call, body["refresh_token"]})
        Map.fetch!(answers, body["refresh_token"])
      end
    })
  end

  defp renewed(account, refresh) do
    {200,
     %{
       "access_token" => access_token(7_200, %{"for" => account.id}),
       "refresh_token" => refresh,
       "id_token" => id_token(%{account_id: account.account_id})
     }}
  end

  defp idle_grant(user, refresh, at \\ @long_ago),
    do: user_grant!(user.id, %{refresh_token: refresh, last_refreshed_at: at})

  defp days_ago(days),
    do: DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

  # Due for the keepalive, and not so idle that a job stops waiting for the
  # breaker (seven days).
  defp recently_idle, do: days_ago(6)

  # Two owners nobody has heard of were refused just now.
  defp open_breaker do
    RefreshBreaker.observe(Ecto.UUID.generate(), Ecto.UUID.generate())
    :opened = RefreshBreaker.observe(Ecto.UUID.generate(), Ecto.UUID.generate())
  end

  defp args(account),
    do: %{grant_id: account.id, user_id: account.user_id, generation: account.generation}

  defp enqueue!(account) do
    {:ok, job} = account |> args() |> Worker.new() |> Oban.insert()
    job
  end

  # `[:fountain, :chatgpt | suffix]` events reach the test whole, so it can
  # say what their metadata is and is not.
  defp watch_telemetry(suffixes) do
    test_pid = self()
    handler = "keepalive-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      Enum.map(suffixes, &([:fountain, :chatgpt] ++ &1)),
      fn [:fountain, :chatgpt | suffix], measurements, metadata, _ ->
        send(test_pid, {:telemetry, suffix, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp state(job), do: Repo.get!(Oban.Job, job.id).state
  defp row(account), do: Repo.get!(Account, account.id)

  defp reconnect_events(user) do
    Repo.all(
      from(e in Event,
        where: e.user_id == ^user.id and e.action == "chatgpt_grant.reconnect_required",
        select: e.resource_id
      )
    )
  end

  test "a job's args are the three ids, and it renews the idle grant" do
    user = insert_verified_user()
    account = idle_grant(user, "rt_SECRET_idle")
    stub_token(%{"rt_SECRET_idle" => renewed(account, "rt_SECRET_next")})

    job = enqueue!(account)
    stored = Repo.get!(Oban.Job, job.id)
    assert stored.args |> Map.keys() |> Enum.sort() == ~w(generation grant_id user_id)
    assert stored.queue == "chatgpt_refresh"
    refute inspect(stored) =~ "rt_SECRET"

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :chatgpt_refresh)
    assert_received {:token_call, "rt_SECRET_idle"}

    current = row(account)
    assert current.lock_version == account.lock_version + 1
    assert current.generation == account.generation
    assert DateTime.compare(current.last_refreshed_at, @long_ago) == :gt
    assert {:ok, "rt_SECRET_next"} = Cipher.decrypt_token(current, :refresh_token)
  end

  test "two grants of one user are each renewed by their own job" do
    user = insert_verified_user()
    a = idle_grant(user, "rt_a")
    b = idle_grant(user, "rt_b")
    stub_token(%{"rt_a" => renewed(a, "rt_a2"), "rt_b" => renewed(b, "rt_b2")})
    jobs = [enqueue!(a), enqueue!(b)]

    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :chatgpt_refresh)
    assert Enum.map(jobs, &state/1) == ["completed", "completed"]
    assert_received {:token_call, "rt_a"}
    assert_received {:token_call, "rt_b"}
    assert {:ok, "rt_a2"} = Cipher.decrypt_token(row(a), :refresh_token)
    assert {:ok, "rt_b2"} = Cipher.decrypt_token(row(b), :refresh_token)
  end

  test "a reused refresh token marks that grant reconnect-required, and the user's other grant is still renewed" do
    user = insert_verified_user()
    a = idle_grant(user, "rt_a")
    b = idle_grant(user, "rt_b")

    stub_token(%{
      "rt_a" => {400, %{"error" => %{"code" => "refresh_token_reused"}}},
      "rt_b" => renewed(b, "rt_b2")
    })

    job_a = enqueue!(a)
    job_b = enqueue!(b)

    assert %{cancelled: 1, success: 1, failure: 0} = Oban.drain_queue(queue: :chatgpt_refresh)
    assert state(job_a) == "cancelled"
    assert state(job_b) == "completed"

    assert %{status: "revoked", revoked_reason: "refresh_token_reused"} = row(a)
    assert reconnect_events(user) == [a.id]

    current_b = row(b)
    assert current_b.status == "active"
    assert current_b.revoked_reason == nil
    assert current_b.lock_version == b.lock_version + 1
    assert {:ok, "rt_b2"} = Cipher.decrypt_token(current_b, :refresh_token)
  end

  test "one grant's timed-out renewal snoozes its own job and the user's other grant is renewed in the same pass" do
    user = insert_verified_user()
    a = idle_grant(user, "rt_a")
    b = idle_grant(user, "rt_b")
    stub_token(%{"rt_b" => renewed(b, "rt_b2")})
    a_id = a.id

    # A's renewal times out in the coordinator; every other grant's is real.
    # What this proves is that the jobs are independent: A's outcome is A's
    # job's, and B's job renews B in the same pass. It does not prove the
    # slots are: `drain_queue` runs the two one after the other, and the
    # timeout is an answer handed back, not thirty seconds spent. A renewal
    # that really hangs holds one of the queue's two slots and one of the
    # coordinator's four until its deadline, and B waits only if every slot
    # is held that way.
    stub(RefreshCoordinator, :run, fn
      ^a_id, _user_id, _generation ->
        {:error, :refresh_timeout}

      grant_id, user_id, generation ->
        call_original(RefreshCoordinator, :run, [grant_id, user_id, generation])
    end)

    job_a = enqueue!(a)
    job_b = enqueue!(b)
    before = DateTime.utc_now()

    assert %{snoozed: 1, success: 1, failure: 0} = Oban.drain_queue(queue: :chatgpt_refresh)

    snoozed = Repo.get!(Oban.Job, job_a.id)
    assert snoozed.state == "scheduled"
    wait = DateTime.diff(snoozed.scheduled_at, before)
    assert wait >= 60 and wait <= 125
    assert row(a) == a

    assert state(job_b) == "completed"
    assert row(b).lock_version == b.lock_version + 1
    refute_received {:token_call, "rt_a"}
  end

  for {label, mutation} <- [
        {"a disconnect", :disconnect},
        {"a removal", :remove},
        {"a reconnect", :reconnect},
        {"the owner's suspension", :suspend}
      ] do
    test "#{label} between the sweep and the job cancels it, and the auth server is not asked" do
      user = insert_verified_user()
      account = idle_grant(user, "rt_a")
      stub_token(%{})
      job = enqueue!(account)
      mutate(unquote(mutation), account)

      assert %{cancelled: 1, success: 0, failure: 0} = Oban.drain_queue(queue: :chatgpt_refresh)
      assert state(job) == "cancelled"
      refute_received {:token_call, _}
    end
  end

  test "a grant somebody renewed before the job ran is not exchanged again" do
    user = insert_verified_user()
    account = idle_grant(user, "rt_a")
    stub_token(%{"rt_a" => renewed(account, "rt_a2")})

    assert :ok = ChatGPTAccounts.refresh_for_user(account.id, user.id, account.generation)
    assert_received {:token_call, "rt_a"}
    current = row(account)

    assert :ok = perform_job(Worker, args(account))
    refute_received {:token_call, _}
    assert row(account) == current
  end

  describe "the breaker" do
    defp throttled,
      do: {429, %{"error" => "rate_limited", "error_description" => "rt_SECRET_echo"}}

    test "one owner's refusals never stand it up, however many grants and however often" do
      user = insert_verified_user()
      a = idle_grant(user, "rt_a")
      b = idle_grant(user, "rt_b")
      stub_token(%{"rt_a" => throttled(), "rt_b" => throttled()})

      watch_telemetry([
        [:keepalive, :grant],
        [:refresh, :rate_limited],
        [:refresh, :breaker_opened]
      ])

      log =
        capture_log(fn ->
          for _ <- 1..3, grant <- [a, b] do
            assert {:error, :rate_limited} = perform_job(Worker, args(grant))
          end
        end)

      refute RefreshBreaker.open?()
      refute_received {:telemetry, [:refresh, :breaker_opened], _, _}
      assert_received {:telemetry, [:refresh, :rate_limited], %{count: 1}, %{}}

      assert_received {:telemetry, [:keepalive, :grant], %{count: 1},
                       %{result: :rate_limited, reason: :rate_limited}}

      refute log =~ "rt_SECRET_echo"
      assert row(a) == a
      assert reconnect_events(user) == []
    end

    test "two owners' refusals stand it up, another owner's job waits without asking, and it clears by time" do
      Application.put_env(:fountain, :chatgpt_refresh_breaker_ms, 1_500)
      on_exit(fn -> Application.delete_env(:fountain, :chatgpt_refresh_breaker_ms) end)

      a = idle_grant(insert_verified_user(), "rt_a")
      b = idle_grant(insert_verified_user(), "rt_b")
      c = idle_grant(insert_verified_user(), "rt_c", recently_idle())
      stub_token(%{"rt_a" => throttled(), "rt_b" => throttled(), "rt_c" => renewed(c, "rt_c2")})
      watch_telemetry([[:keepalive, :grant], [:refresh, :breaker_opened]])

      assert {:error, :rate_limited} = perform_job(Worker, args(a))
      refute RefreshBreaker.open?()
      assert {:error, :rate_limited} = perform_job(Worker, args(b))
      assert RefreshBreaker.open?()
      assert_received {:telemetry, [:refresh, :breaker_opened], %{count: 1}, %{}}
      assert_received {:token_call, "rt_a"}
      assert_received {:token_call, "rt_b"}

      assert {:snooze, seconds} = perform_job(Worker, args(c))
      assert seconds >= 1 and seconds <= 2 + 300
      refute_received {:token_call, _}
      assert row(c) == c

      assert_received {:telemetry, [:keepalive, :grant], %{count: 1},
                       %{result: :snoozed, reason: :breaker_open}}

      Process.sleep(1_600)
      refute RefreshBreaker.open?()
      assert :ok = perform_job(Worker, args(c))
      assert_received {:token_call, "rt_c"}
      assert row(c).lock_version == c.lock_version + 1
    end

    test "a 403 that names a code is that account's: a failed refresh, and no evidence of a throttle" do
      named = idle_grant(insert_verified_user(), "rt_a")
      other = idle_grant(insert_verified_user(), "rt_b")

      stub_token(%{
        "rt_a" => {403, %{"error" => %{"code" => "account_deactivated"}}},
        "rt_b" => throttled()
      })

      assert {:error, :refresh_failed} = perform_job(Worker, args(named))
      assert {:error, :rate_limited} = perform_job(Worker, args(other))
      # Had the 403 counted, that was the second owner.
      refute RefreshBreaker.open?()
      assert row(named) == named
    end

    test "a 403 whose body names no code is a proxy's, and counts" do
      a = idle_grant(insert_verified_user(), "rt_a")
      b = idle_grant(insert_verified_user(), "rt_b")
      stub_token(%{"rt_a" => {403, %{}}, "rt_b" => {403, %{"message" => "blocked"}}})

      assert {:error, :rate_limited} = perform_job(Worker, args(a))
      assert {:error, :rate_limited} = perform_job(Worker, args(b))
      assert RefreshBreaker.open?()
      assert row(a) == a
    end

    test "the deployment's own grant is an owner: its 429 and one user's stand it up" do
      platform = connect!()
      platform |> change(last_refreshed_at: @long_ago) |> Repo.update!()
      user_grant = idle_grant(insert_verified_user(), "rt_a")
      stub_token(%{"rt_original" => throttled(), "rt_a" => throttled()})

      capture_log(fn -> assert {:error, _} = ChatGPTAccounts.platform_keepalive() end)
      assert_received {:token_call, "rt_original"}
      refute RefreshBreaker.open?()

      assert {:error, :rate_limited} = perform_job(Worker, args(user_grant))
      assert RefreshBreaker.open?()
    end

    test "a grant is heard once per window, and an owner counts once" do
      owner = Ecto.UUID.generate()
      grant = Ecto.UUID.generate()

      assert :recorded = RefreshBreaker.observe(owner, grant)
      # A turn loop renewing the same grant again and again.
      for _ <- 1..50, do: assert(:ignored = RefreshBreaker.observe(owner, grant))
      assert :recorded = RefreshBreaker.observe(owner, Ecto.UUID.generate())
      refute RefreshBreaker.open?()

      assert :opened = RefreshBreaker.observe(Ecto.UUID.generate(), Ecto.UUID.generate())
      assert RefreshBreaker.remaining_seconds() in 899..900
    end

    test "a job it has held two hours goes ahead as a probe, and a refused probe is an ordinary failure" do
      account = idle_grant(insert_verified_user(), "rt_a", recently_idle())
      stub_token(%{"rt_a" => throttled()})
      open_breaker()
      now = System.os_time(:second)

      # Held for an hour: it still waits.
      held = %{"first_run_at" => now - 3_600, "breaker_deferred_at" => now - 3_600}
      assert {:snooze, _} = perform_job(Worker, args(account), meta: held)
      refute_received {:token_call, _}

      # Held past two: it asks, is refused, and the breaker still stands.
      held = %{"first_run_at" => now - 7_300, "breaker_deferred_at" => now - 7_300}

      capture_log(fn ->
        assert {:error, :rate_limited} = perform_job(Worker, args(account), meta: held)
      end)

      assert_received {:token_call, "rt_a"}
      assert RefreshBreaker.open?()
      assert row(account) == account
    end

    test "a grant seven days idle does not wait for it, and its probe can succeed" do
      account = idle_grant(insert_verified_user(), "rt_a", days_ago(7))
      stub_token(%{"rt_a" => renewed(account, "rt_a2")})
      open_breaker()

      assert :ok = perform_job(Worker, args(account))
      assert_received {:token_call, "rt_a"}
      assert row(account).lock_version == account.lock_version + 1
    end

    test "a held job's wake-up is spread over the sweep's window again, which rides in meta" do
      account = idle_grant(insert_verified_user(), "rt_a", recently_idle())
      stub_token(%{})
      open_breaker()

      waits =
        for _ <- 1..6 do
          assert {:snooze, seconds} =
                   perform_job(Worker, args(account), meta: %{"window" => 20_000})

          seconds
        end

      assert Enum.all?(waits, &(&1 >= 899 and &1 <= 900 + 20_000))
      # Six draws from 20,000 s all inside the old two minutes: one in 10^13.
      assert Enum.max(waits) > 900 + 120

      # A job with no window, one queued by hand, takes five minutes.
      assert {:snooze, seconds} = perform_job(Worker, args(account))
      assert seconds <= 900 + 300
      refute_received {:token_call, _}
    end

    test "when it first held the job is written on the row, once" do
      account = idle_grant(insert_verified_user(), "rt_a", recently_idle())
      stub_token(%{})
      open_breaker()
      job = enqueue!(account)

      assert %{snoozed: 1} = Oban.drain_queue(queue: :chatgpt_refresh)

      %{meta: %{"breaker_deferred_at" => first, "first_run_at" => ran}} =
        Repo.get!(Oban.Job, job.id)

      assert is_integer(first) and is_integer(ran)

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [meta: %{"breaker_deferred_at" => first - 50, "first_run_at" => ran - 50}]
      )

      assert %{snoozed: 1} = Oban.drain_queue(queue: :chatgpt_refresh, with_scheduled: true)
      assert %{"breaker_deferred_at" => kept} = Repo.get!(Oban.Job, job.id).meta
      assert kept == first - 50
    end

    test "a job it holds for a grant that is gone ends at once" do
      user = insert_verified_user()
      account = idle_grant(user, "rt_a", recently_idle())
      stub_token(%{})
      open_breaker()
      :ok = ChatGPTAccounts.disconnect_for_user(account.id, user.id)

      assert {:cancel, :stale_grant} = perform_job(Worker, args(account))
      :ok = ChatGPTAccounts.remove_for_user(account.id, user.id)
      assert {:cancel, :not_connected} = perform_job(Worker, args(account))
      refute_received {:token_call, _}
    end

    test "any other provider error is an ordinary retry and is no evidence" do
      account = idle_grant(insert_verified_user(), "rt_a")
      other = idle_grant(insert_verified_user(), "rt_b")
      stub_token(%{"rt_a" => {503, %{"error" => "unavailable"}}, "rt_b" => throttled()})
      job = enqueue!(account)

      assert %{failure: 1} = Oban.drain_queue(queue: :chatgpt_refresh)
      assert Repo.get!(Oban.Job, job.id).state == "retryable"
      assert row(account) == account

      assert {:error, :rate_limited} = perform_job(Worker, args(other))
      refute RefreshBreaker.open?()
    end
  end

  describe "forged args" do
    test "one owner's grant under another owner's id is cancelled, and nobody is asked" do
      victim = idle_grant(insert_verified_user(), "rt_victim")
      forger = insert_verified_user()
      stub_token(%{})

      forged = %{grant_id: victim.id, user_id: forger.id, generation: victim.generation}
      assert {:cancel, :not_connected} = perform_job(Worker, forged)
      refute_received {:token_call, _}
      assert row(victim) == victim
    end

    test "the deployment's grant under any owner's id is cancelled, and nobody is asked" do
      platform = connect!()
      platform = platform |> change(last_refreshed_at: @long_ago) |> Repo.update!()
      stub_token(%{})

      forged = %{
        grant_id: platform.id,
        user_id: insert_verified_user().id,
        generation: platform.generation
      }

      assert {:cancel, :not_connected} = perform_job(Worker, forged)
      refute_received {:token_call, _}
      assert row(platform) == platform
    end
  end

  describe "a job that cannot finish" do
    test "says so once, at error, when its last attempt fails: the grant's id and an atom" do
      user = insert_verified_user()
      account = idle_grant(user, "rt_a")

      stub_token(%{
        "rt_a" => {503, %{"error" => "unavailable", "error_description" => "rt_SECRET_echo"}}
      })

      quiet =
        capture_log([level: :error], fn ->
          assert {:error, :refresh_failed} =
                   perform_job(Worker, args(account), attempt: 2, max_attempts: 3)
        end)

      refute quiet =~ "chatgpt keepalive"

      log =
        capture_log([level: :error], fn ->
          assert {:error, :refresh_failed} =
                   perform_job(Worker, args(account), attempt: 3, max_attempts: 3)
        end)

      assert log =~ "[error]"

      assert log =~
               "grant #{account.id} was not renewed and the job is discarded (refresh_failed)"

      refute log =~ user.id
      refute log =~ "rt_SECRET_echo"
    end

    test "gives way twenty hours after its first run, not after it was queued" do
      account = idle_grant(insert_verified_user(), "rt_a")
      stub_token(%{"rt_a" => renewed(account, "rt_a2")})
      now = System.os_time(:second)

      ran_long_ago = %{"first_run_at" => now - 21 * 3_600}
      assert {:cancel, :gave_up} = perform_job(Worker, args(account), meta: ran_long_ago)
      refute_received {:token_call, _}

      # Queued two days ago behind a paused queue and never run: it has tried
      # nothing yet, so it renews the grant instead of giving up on sight.
      old = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
      assert :ok = perform_job(Worker, args(account), inserted_at: old)
      assert_received {:token_call, "rt_a"}
    end
  end

  test "the backoff is bounded however many snoozes have raised the attempt" do
    for attempt <- [1, 2, 3, 10, 50, 5_000] do
      seconds = Worker.backoff(%Oban.Job{attempt: attempt})
      assert seconds >= 30 and seconds <= 930
    end

    assert Worker.backoff(%Oban.Job{attempt: 1}) <= 60
  end

  test "its lines carry the grant's id and an atom, and nothing of the owner's" do
    user = insert_verified_user()
    account = idle_grant(user, "rt_a")
    stub_token(%{})
    :ok = ChatGPTAccounts.disconnect_for_user(account.id, user.id)

    # The suite logs warnings and up; these lines are `info`.
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log = capture_log([level: :info], fn -> perform_job(Worker, args(account)) end)
    # A disconnect changes the generation, so the pin the job holds is stale.
    assert log =~ "grant #{account.id} cancelled (stale_grant)"
    refute log =~ user.id
    refute log =~ user.email
    refute log =~ account.account_id
  end

  test "malformed or extra job arguments are refused" do
    assert {:cancel, :invalid_args} = perform_job(Worker, %{"grant_id" => "bad"})
    account = idle_grant(insert_verified_user(), "rt_a")

    assert {:cancel, :invalid_args} =
             perform_job(Worker, Map.put(args(account), :access_token, "unexpected"))
  end

  defp mutate(:disconnect, account),
    do: :ok = ChatGPTAccounts.disconnect_for_user(account.id, account.user_id)

  defp mutate(:remove, account) do
    mutate(:disconnect, account)
    :ok = ChatGPTAccounts.remove_for_user(account.id, account.user_id)
  end

  defp mutate(:reconnect, account) do
    {:ok, _} =
      ChatGPTAccounts.reconnect_for_user(
        account.id,
        account.user_id,
        user_tokens(account.account_id)
      )
  end

  defp mutate(:suspend, account) do
    Fountain.Accounts.User
    |> Repo.get!(account.user_id)
    |> change(suspended_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end
end
