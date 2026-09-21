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
    Fountain.LogThrottle.reset()
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

  # The breaker's clock, frozen at `ms` until the test says otherwise.
  defp clock(ms) do
    Application.put_env(:fountain, :chatgpt_refresh_breaker_now_ms, ms)
    on_exit(fn -> Application.delete_env(:fountain, :chatgpt_refresh_breaker_now_ms) end)
  end

  # The token endpoint answering every refresh with one raw response, for
  # bodies that are not JSON. `stub_auth/1` can only answer JSON.
  defp stub_raw(status, content_type, body) do
    test_pid = self()
    Req.Test.set_req_test_to_shared(%{})

    Req.Test.stub(Fountain.PlatformChatGPT.OAuth, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:token_call, Jason.decode!(raw)["refresh_token"]})

      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp capture_log_result(fun) do
    test_pid = self()
    capture_log(fn -> send(test_pid, {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("the condition never held")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

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
            # A wait, not a failed attempt: it does not ask again for a
            # quarter of an hour, and spends none of its three attempts.
            assert {:snooze, seconds} = perform_job(Worker, args(grant))
            assert seconds >= 900
          end
        end)

      refute RefreshBreaker.open?()
      assert RefreshBreaker.heard?(a.id) and RefreshBreaker.heard?(b.id)
      refute_received {:telemetry, [:refresh, :breaker_opened], _, _}
      assert_received {:telemetry, [:refresh, :rate_limited], %{count: 1}, %{}}

      assert_received {:telemetry, [:keepalive, :grant], %{count: 1},
                       %{result: :rate_limited, reason: :rate_limited}}

      refute log =~ "rt_SECRET_echo"
      assert row(a) == a
      assert reconnect_events(user) == []
    end

    test "two owners' refusals stand it up, another owner's job waits without asking, and it clears by time" do
      clock(1_000_000)
      a = idle_grant(insert_verified_user(), "rt_a")
      b = idle_grant(insert_verified_user(), "rt_b")
      c = idle_grant(insert_verified_user(), "rt_c", recently_idle())
      stub_token(%{"rt_a" => throttled(), "rt_b" => throttled(), "rt_c" => renewed(c, "rt_c2")})
      watch_telemetry([[:keepalive, :grant], [:refresh, :breaker_opened]])

      assert {:snooze, _} = perform_job(Worker, args(a))
      refute RefreshBreaker.open?()
      assert {:snooze, _} = perform_job(Worker, args(b))
      assert RefreshBreaker.open?()
      assert RefreshBreaker.remaining_seconds() == 900
      assert_received {:telemetry, [:refresh, :breaker_opened], %{count: 1}, %{}}
      assert_received {:token_call, "rt_a"}
      assert_received {:token_call, "rt_b"}

      assert {:snooze, seconds} = perform_job(Worker, args(c))
      assert seconds >= 900 and seconds <= 900 + 300
      refute_received {:token_call, _}
      assert row(c) == c

      assert_received {:telemetry, [:keepalive, :grant], %{count: 1},
                       %{result: :snoozed, reason: :breaker_open}}

      clock(1_000_000 + 900_000)
      refute RefreshBreaker.open?()
      assert :ok = perform_job(Worker, args(c))
      assert_received {:token_call, "rt_c"}
      assert row(c).lock_version == c.lock_version + 1
    end

    # What the auth server really answers a throttled address with is not
    # measured (ADR 0060); this is what is taken for it, and what is not.
    for {label, status, type, body, evidence?} <- [
          {"a bare 429", 429, "text/plain", "", true},
          {"a 429 with a JSON body", 429, "application/json", ~s({"error":"rate_limited"}), true},
          {"a 403 that is an HTML page", 403, "text/html",
           "<html><body>Access denied</body></html>", true},
          {"a 403 with no body", 403, "text/plain", "", true},
          # Labelled JSON and not JSON: the status still says what it was.
          {"a 429 labelled JSON with no body", 429, "application/json", "", true},
          {"a 429 whose JSON is cut short", 429, "application/json", ~s({"error":"rate_lim),
           true},
          {"a 403 labelled JSON with no body", 403, "application/json", "", true},
          {"a 403 whose JSON is cut short", 403, "application/json", ~s({"error":{"code":"acc),
           true},
          {"a 403 whose JSON object names a code", 403, "application/json",
           ~s({"error":{"code":"account_deactivated"}}), false},
          {"a 403 whose JSON object names none", 403, "application/json",
           ~s({"message":"blocked"}), false},
          {"a 403 whose JSON object is shaped another way", 403, "application/json",
           ~s({"detail":"Your workspace does not allow this."}), false}
        ] do
      test "#{label} is #{if evidence?, do: "evidence of a throttled address", else: "that account's own failure, and no evidence"}" do
        account = idle_grant(insert_verified_user(), "rt_a")
        stub_raw(unquote(status), unquote(type), unquote(body))

        result = capture_log_result(fn -> perform_job(Worker, args(account)) end)
        assert_received {:token_call, "rt_a"}

        if unquote(evidence?) do
          assert {:snooze, _} = result
          assert RefreshBreaker.heard?(account.id)
        else
          assert {:error, :refresh_failed} = result
          refute RefreshBreaker.heard?(account.id)
        end

        assert row(account) == account
      end
    end

    test "the deployment's own grant is an owner: its 429 and one user's stand it up" do
      platform = connect!()
      platform |> change(last_refreshed_at: @long_ago) |> Repo.update!()
      user_grant = idle_grant(insert_verified_user(), "rt_a")
      stub_token(%{"rt_original" => throttled(), "rt_a" => throttled()})

      capture_log(fn -> assert {:error, _} = ChatGPTAccounts.platform_keepalive() end)
      assert_received {:token_call, "rt_original"}
      refute RefreshBreaker.open?()

      assert {:snooze, _} = perform_job(Worker, args(user_grant))
      assert RefreshBreaker.open?()
    end

    test "a grant is heard once per window, and an owner counts once" do
      clock(5_000_000)
      owner = Ecto.UUID.generate()
      grant = Ecto.UUID.generate()

      assert :recorded = RefreshBreaker.observe(owner, grant)
      # A turn loop renewing the same grant again and again.
      for _ <- 1..50, do: assert(:ignored = RefreshBreaker.observe(owner, grant))
      assert :recorded = RefreshBreaker.observe(owner, Ecto.UUID.generate())
      refute RefreshBreaker.open?()

      # Ten minutes on, what was heard has lapsed: that owner alone again.
      clock(5_000_000 + 600_000)
      refute RefreshBreaker.heard?(grant)
      assert :recorded = RefreshBreaker.observe(owner, grant)
      refute RefreshBreaker.open?()

      assert :opened = RefreshBreaker.observe(Ecto.UUID.generate(), Ecto.UUID.generate())
      assert RefreshBreaker.remaining_seconds() == 900
    end

    test "with no table it is not standing, and nothing raises" do
      table = :fountain_chatgpt_refresh_breaker
      pid = Process.whereis(RefreshBreaker.Table)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      # Between the owner's death and its restart the table may be gone.
      if :ets.whereis(table) == :undefined do
        assert :ignored = RefreshBreaker.observe(Ecto.UUID.generate(), Ecto.UUID.generate())
        assert :ok = RefreshBreaker.succeeded()
        assert :closed = RefreshBreaker.claim_probe()
        refute RefreshBreaker.open?()
      end

      wait_until(fn -> :ets.whereis(table) != :undefined end)
      assert :recorded = RefreshBreaker.observe(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "a held job never sleeps past the moment it is due to probe, by the two hours or by the seven days" do
      stub_token(%{})
      open_breaker()
      now = System.os_time(:second)
      six_hours = %{"window" => 21_600}

      # Held for an hour and a half: due in thirty minutes.
      account = idle_grant(insert_verified_user(), "rt_a", recently_idle())

      held =
        Map.merge(six_hours, %{
          "first_run_at" => now - 5_400,
          "breaker_deferred_at" => now - 5_400
        })

      for _ <- 1..20 do
        assert {:snooze, seconds} = perform_job(Worker, args(account), meta: held)
        assert seconds >= 30 and seconds <= 1_800 + 121
      end

      # Just held, and its grant reaches seven days idle in ten minutes.
      almost = DateTime.add(days_ago(7), 600, :second)
      nearly_seven = idle_grant(insert_verified_user(), "rt_b", almost)

      for _ <- 1..20 do
        assert {:snooze, seconds} = perform_job(Worker, args(nearly_seven), meta: six_hours)
        assert seconds >= 30 and seconds <= 600 + 121
      end

      # Just held, nothing near: the two hours are still the ceiling.
      for _ <- 1..20 do
        assert {:snooze, seconds} = perform_job(Worker, args(account), meta: six_hours)
        assert seconds <= 7_200 + 121
      end

      refute_received {:token_call, _}
    end

    test "one probe per node per pause: the first held job asks, a refused probe waits again, and the rest do not ask" do
      first = idle_grant(insert_verified_user(), "rt_a", recently_idle())
      second = idle_grant(insert_verified_user(), "rt_b", recently_idle())
      week_idle = idle_grant(insert_verified_user(), "rt_c", days_ago(8))
      stub_token(%{"rt_a" => throttled(), "rt_b" => throttled(), "rt_c" => throttled()})
      open_breaker()
      now = System.os_time(:second)
      held = %{"first_run_at" => now - 7_300, "breaker_deferred_at" => now - 7_300}

      job = enqueue!(first)
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [meta: held])
      refute RefreshBreaker.heard?(first.id)

      assert %{snoozed: 1, failure: 0} = Oban.drain_queue(queue: :chatgpt_refresh)
      assert_received {:token_call, "rt_a"}

      # The refusal is on record for this grant, which the breaker being open
      # already would not show; the job has spent no attempt; and its two
      # hours start again, so its next wake is not another request.
      assert RefreshBreaker.heard?(first.id)
      waiting = Repo.get!(Oban.Job, job.id)
      assert waiting.state == "scheduled"
      assert waiting.max_attempts - waiting.attempt == 3
      assert_in_delta waiting.meta["breaker_deferred_at"], now, 5
      assert DateTime.diff(waiting.scheduled_at, DateTime.utc_now()) >= 890

      assert %{snoozed: 1} = Oban.drain_queue(queue: :chatgpt_refresh, with_scheduled: true)
      refute_received {:token_call, _}

      # Held as long, and eight days idle: the pause's probe is spent.
      assert {:snooze, seconds} = perform_job(Worker, args(second), meta: held)
      assert seconds <= 900 + 121
      assert {:snooze, seconds} = perform_job(Worker, args(week_idle))
      assert seconds <= 900 + 121
      refute_received {:token_call, _}

      # The refused probe was evidence and extended the pause; that is not a
      # new probe. A pause length after the claim there is one more, and one
      # only.
      clock(System.monotonic_time(:millisecond) + 900_000)
      open_breaker()
      assert {:snooze, _} = perform_job(Worker, args(week_idle))
      assert_received {:token_call, "rt_c"}
      assert {:snooze, _} = perform_job(Worker, args(second), meta: held)
      refute_received {:token_call, _}
    end

    test "a probe that succeeds closes it, and a held job runs at its next wake" do
      probe = idle_grant(insert_verified_user(), "rt_a", days_ago(7))
      held = idle_grant(insert_verified_user(), "rt_b", recently_idle())
      stub_token(%{"rt_a" => renewed(probe, "rt_a2"), "rt_b" => renewed(held, "rt_b2")})
      open_breaker()
      heard = Ecto.UUID.generate()
      RefreshBreaker.observe(Ecto.UUID.generate(), heard)
      watch_telemetry([[:refresh, :breaker_closed]])

      assert {:snooze, _} = perform_job(Worker, args(held))
      refute_received {:token_call, _}

      assert :ok = perform_job(Worker, args(probe))
      assert_received {:token_call, "rt_a"}
      refute RefreshBreaker.open?()
      assert_received {:telemetry, [:refresh, :breaker_closed], %{count: 1}, %{}}
      # The success refutes what was heard before it.
      refute RefreshBreaker.heard?(heard)

      assert :ok = perform_job(Worker, args(held))
      assert_received {:token_call, "rt_b"}
      assert row(held).lock_version == held.lock_version + 1
    end

    test "a turn's renewal that succeeds closes it too" do
      user = insert_verified_user()
      account = idle_grant(user, "rt_a")
      stub_token(%{"rt_a" => renewed(account, "rt_a2")})
      open_breaker()

      assert :ok = ChatGPTAccounts.ensure_fresh_for_user(account.id, user.id, account.generation)
      assert_received {:token_call, "rt_a"}
      refute RefreshBreaker.open?()
    end

    test "a job that runs with it down forgets it was held, so a later pause starts its two hours afresh" do
      account = idle_grant(insert_verified_user(), "rt_a", recently_idle())
      stub_token(%{})
      open_breaker()
      job = enqueue!(account)

      assert %{snoozed: 1} = Oban.drain_queue(queue: :chatgpt_refresh)
      held_at = Repo.get!(Oban.Job, job.id).meta["breaker_deferred_at"]
      assert is_integer(held_at)

      # Long ago, as far as the job knows. The breaker comes down and the job
      # runs, crowded out this once.
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [
          meta: %{"first_run_at" => held_at - 10_000, "breaker_deferred_at" => held_at - 10_000}
        ]
      )

      RefreshBreaker.reset()
      stub(RefreshCoordinator, :run, fn _, _, _ -> {:error, :refresh_busy} end)
      assert %{snoozed: 1} = Oban.drain_queue(queue: :chatgpt_refresh, with_scheduled: true)
      refute Map.has_key?(Repo.get!(Oban.Job, job.id).meta, "breaker_deferred_at")

      # It stands again: held from now, not from hours ago, so no probe.
      open_breaker()
      assert %{snoozed: 1} = Oban.drain_queue(queue: :chatgpt_refresh, with_scheduled: true)
      assert_in_delta Repo.get!(Oban.Job, job.id).meta["breaker_deferred_at"], held_at, 5
      refute_received {:token_call, _}
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

      # Never past the two hours at which it is due to probe.
      assert Enum.all?(waits, &(&1 >= 899 and &1 <= 7_200 + 121))
      # Six draws from 20,000 s all inside the old two minutes: one in 10^13.
      assert Enum.max(waits) > 900 + 120

      # A job with no window, one queued by hand, takes five minutes.
      assert {:snooze, seconds} = perform_job(Worker, args(account))
      assert seconds <= 900 + 300
      refute_received {:token_call, _}
    end

    test "a job it holds for a grant that is gone, or revoked under the same generation, ends at once" do
      user = insert_verified_user()
      revoked = idle_grant(user, "rt_r", recently_idle())
      revoked |> change(status: "revoked", revoked_reason: "invalid_grant") |> Repo.update!()
      account = idle_grant(user, "rt_a", recently_idle())
      stub_token(%{})
      open_breaker()

      assert {:cancel, :revoked} = perform_job(Worker, args(revoked))

      :ok = ChatGPTAccounts.disconnect_for_user(account.id, user.id)
      assert {:cancel, :stale_grant} = perform_job(Worker, args(account))
      :ok = ChatGPTAccounts.remove_for_user(account.id, user.id)
      assert {:cancel, :not_connected} = perform_job(Worker, args(account))
      refute_received {:token_call, _}
    end

    test "any other provider error is an ordinary retry and is no evidence" do
      account = idle_grant(insert_verified_user(), "rt_a")
      stub_token(%{"rt_a" => {503, %{"error" => "unavailable"}}})
      job = enqueue!(account)

      assert %{failure: 1} = Oban.drain_queue(queue: :chatgpt_refresh)
      assert Repo.get!(Oban.Job, job.id).state == "retryable"
      refute RefreshBreaker.heard?(account.id)
      assert row(account) == account
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
    test "says so at error when its last attempt fails, once a minute however many grants" do
      user = insert_verified_user()
      account = idle_grant(user, "rt_a")
      other = idle_grant(insert_verified_user(), "rt_b")
      failing = {503, %{"error" => "unavailable", "error_description" => "rt_SECRET_echo"}}
      stub_token(%{"rt_a" => failing, "rt_b" => failing})
      watch_telemetry([[:keepalive, :grant]])

      quiet =
        capture_log([level: :error], fn ->
          assert {:error, :refresh_failed} =
                   perform_job(Worker, args(account), attempt: 2, max_attempts: 3)
        end)

      refute quiet =~ "chatgpt keepalive"
      assert_received {:telemetry, [:keepalive, :grant], _, %{result: :error}}

      log =
        capture_log([level: :error], fn ->
          for grant <- [account, other] do
            assert {:error, :refresh_failed} =
                     perform_job(Worker, args(grant), attempt: 3, max_attempts: 3)
          end
        end)

      assert log =~ "[error]"

      assert log =~
               "grant #{account.id} was not renewed and the job is discarded (refresh_failed)"

      # An outage is one line a minute, and the counter says how many.
      refute log =~ other.id
      assert_received {:telemetry, [:keepalive, :grant], _, %{result: :discarded}}
      assert_received {:telemetry, [:keepalive, :grant], _, %{result: :discarded}}
      refute log =~ user.id
      refute log =~ "rt_SECRET_echo"
    end

    test "a run that raises on its last attempt says the same and still raises" do
      account = idle_grant(insert_verified_user(), "rt_a")
      stub(RefreshCoordinator, :run, fn _, _, _ -> raise "the coordinator is not what it was" end)
      job = %Oban.Job{args: stringify(args(account)), attempt: 3, max_attempts: 3, meta: %{}}

      log =
        capture_log([level: :error], fn ->
          assert_raise RuntimeError, fn -> Worker.perform(job) end
        end)

      assert log =~ "grant #{account.id} was not renewed and the job is discarded (raised)"
    end

    test "stops three days after its first run whatever it is waiting on, and not before" do
      account = idle_grant(insert_verified_user(), "rt_a")
      stub_token(%{"rt_a" => renewed(account, "rt_a2")})
      now = System.os_time(:second)

      log =
        capture_log([level: :error], fn ->
          assert {:cancel, :gave_up} =
                   perform_job(Worker, args(account), meta: %{"first_run_at" => now - 73 * 3_600})
        end)

      assert log =~ "grant #{account.id} was not renewed in three days of trying"
      refute_received {:token_call, _}

      # Two days in, still due: it is the grant's place in the queue, since
      # the next sweep's insert conflicts with it. It carries on.
      assert :ok = perform_job(Worker, args(account), meta: %{"first_run_at" => now - 48 * 3_600})
      assert_received {:token_call, "rt_a"}
    end

    test "the clock starts at its first run, not when it was queued" do
      account = idle_grant(insert_verified_user(), "rt_a")
      stub_token(%{"rt_a" => renewed(account, "rt_a2")})

      # Queued four days ago behind a paused queue and never run.
      old = DateTime.add(DateTime.utc_now(), -4 * 86_400, :second)
      assert :ok = perform_job(Worker, args(account), inserted_at: old)
      assert_received {:token_call, "rt_a"}
    end
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
