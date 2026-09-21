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

  defp idle_grant(user, refresh),
    do: user_grant!(user.id, %{refresh_token: refresh, last_refreshed_at: @long_ago})

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
    test "a 429 stands it up, the next job snoozes without asking, and it clears" do
      user = insert_verified_user()
      a = idle_grant(user, "rt_a")
      b = idle_grant(insert_verified_user(), "rt_b")

      stub_token(%{
        "rt_a" => {429, %{"error" => "rate_limited", "error_description" => "rt_SECRET_echo"}},
        "rt_b" => renewed(b, "rt_b2")
      })

      refute RefreshBreaker.open?()
      watch_telemetry([[:keepalive, :grant], [:refresh, :rate_limited]])

      log =
        capture_log(fn -> assert {:error, :rate_limited} = perform_job(Worker, args(a)) end)

      assert_received {:token_call, "rt_a"}
      assert RefreshBreaker.open?()
      assert_received {:telemetry, [:refresh, :rate_limited], %{count: 1}, %{}}

      assert_received {:telemetry, [:keepalive, :grant], %{count: 1},
                       %{result: :rate_limited, reason: :rate_limited}}

      refute log =~ "rt_SECRET_echo"
      assert row(a) == a
      assert reconnect_events(user) == []

      # B is another user's, and is not asked about while the breaker stands.
      assert {:snooze, seconds} = perform_job(Worker, args(b))

      assert_received {:telemetry, [:keepalive, :grant], %{count: 1},
                       %{result: :snoozed, reason: :breaker_open}}

      assert seconds >= RefreshBreaker.remaining_seconds()
      assert seconds <= 15 * 60 + 120
      refute_received {:token_call, _}
      assert row(b) == b

      RefreshBreaker.reset()
      RefreshBreaker.trip(1)
      Process.sleep(5)
      refute RefreshBreaker.open?()

      assert :ok = perform_job(Worker, args(b))
      assert_received {:token_call, "rt_b"}
      assert row(b).lock_version == b.lock_version + 1
    end

    test "a 403 that names no terminal code is the same throttle, and revokes nothing" do
      account = idle_grant(insert_verified_user(), "rt_a")
      stub_token(%{"rt_a" => {403, %{"error" => "forbidden"}}})

      assert {:error, :rate_limited} = perform_job(Worker, args(account))
      assert RefreshBreaker.open?()
      assert row(account) == account
    end

    test "any other provider error is an ordinary retry and leaves it down" do
      account = idle_grant(insert_verified_user(), "rt_a")
      stub_token(%{"rt_a" => {503, %{"error" => "unavailable"}}})
      job = enqueue!(account)

      assert %{failure: 1} = Oban.drain_queue(queue: :chatgpt_refresh)
      refute RefreshBreaker.open?()
      retry = Repo.get!(Oban.Job, job.id)
      assert retry.state == "retryable"
      assert row(account) == account
    end

    test "a later trip extends it and never shortens it" do
      RefreshBreaker.trip(60_000)
      RefreshBreaker.trip(1_000)
      assert RefreshBreaker.remaining_seconds() in 59..60
    end
  end

  test "the backoff is bounded however many snoozes have raised the attempt" do
    for attempt <- [1, 2, 3, 10, 50, 5_000] do
      seconds = Worker.backoff(%Oban.Job{attempt: attempt})
      assert seconds >= 30 and seconds <= 930
    end

    assert Worker.backoff(%Oban.Job{attempt: 1}) <= 60
  end

  test "a job still snoozing a day's sweep later gives way without asking anybody" do
    account = idle_grant(insert_verified_user(), "rt_a")
    stub_token(%{})
    old = DateTime.add(DateTime.utc_now(), -21 * 60 * 60, :second)

    assert {:cancel, :gave_up} = perform_job(Worker, args(account), inserted_at: old)
    refute_received {:token_call, _}
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
