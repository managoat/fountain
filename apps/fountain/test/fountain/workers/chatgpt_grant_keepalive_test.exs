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

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  # Two owners nobody has heard of were refused just now. Its opening is an
  # `error` line, which the test that is about it reads for itself.
  defp open_breaker do
    capture_log(fn ->
      RefreshBreaker.observe(Ecto.UUID.generate(), Ecto.UUID.generate())
      :opened = RefreshBreaker.observe(Ecto.UUID.generate(), Ecto.UUID.generate())
    end)

    :ok
  end

  # A job that is a row, with `meta` as given: what the job writes to `meta`
  # goes to its own row, and is read back from it.
  defp enqueue!(account, meta) do
    job = enqueue!(account)
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [meta: meta])
    job
  end

  defp meta(job), do: Repo.get!(Oban.Job, job.id).meta

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

      log =
        capture_log([level: :error], fn -> assert {:snooze, _} = perform_job(Worker, args(b)) end)

      assert RefreshBreaker.open?()
      assert RefreshBreaker.remaining_seconds() == 900

      # Its opening is said once, at `error`, as a count and nobody's id.
      assert log =~ "[error]"
      assert log =~ "turned this address away for 2 owners"
      for grant <- [a, b], do: refute(log =~ grant.id or log =~ grant.user_id)
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

      capture_log(fn -> assert {:snooze, _} = perform_job(Worker, args(user_grant)) end)
      assert RefreshBreaker.open?()
    end

    test "the deployment's own renewal that succeeds closes it" do
      platform = connect!()
      platform |> change(last_refreshed_at: @long_ago) |> Repo.update!()
      stub_token(%{"rt_original" => renewed(platform, "rt_next")})
      open_breaker()
      watch_telemetry([[:refresh, :breaker_closed]])

      assert {:ok, :refreshed} = ChatGPTAccounts.platform_keepalive()
      assert_received {:token_call, "rt_original"}
      refute RefreshBreaker.open?()
      assert_received {:telemetry, [:refresh, :breaker_closed], %{count: 1}, %{}}
    end

    test "an owner or a grant id of another shape is ignored, not raised" do
      assert :ignored = RefreshBreaker.observe(Ecto.UUID.generate(), nil)
      assert :ignored = RefreshBreaker.observe(nil, Ecto.UUID.generate())
      assert :ignored = RefreshBreaker.observe(:somebody, 7)
      refute RefreshBreaker.open?()
    end

    test "a token response cut short keeps its status, and no part of it is logged" do
      platform = connect!()
      platform |> change(last_refreshed_at: @long_ago) |> Repo.update!()
      account = idle_grant(insert_verified_user(), "rt_a")
      cut_short = ~s({"access_token":"at_SECRET_cut","refresh_token":"rt_SECRET_cu)

      for {status, evidence?} <- [{200, false}, {429, true}] do
        RefreshBreaker.reset()
        stub_raw(status, "application/json", cut_short)

        log =
          capture_log(fn ->
            assert {:error, {:token, ^status, "unreadable"}} =
                     ChatGPTAccounts.platform_keepalive()

            assert :ok = perform_job(Fountain.Workers.PlatformChatGPTKeepalive, %{})
            perform_job(Worker, args(account))
          end)

        assert log =~ "refresh failed, keeping the current token: status #{status}"
        assert log =~ "keepalive could not refresh: status #{status}"
        refute log =~ "SECRET"
        refute log =~ "access_token"
        assert RefreshBreaker.heard?(platform.id) == evidence?
        assert RefreshBreaker.heard?(account.id) == evidence?
      end
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

      capture_log(fn ->
        assert :opened = RefreshBreaker.observe(Ecto.UUID.generate(), Ecto.UUID.generate())
      end)

      assert RefreshBreaker.remaining_seconds() == 900
    end

    test "with no table it is not standing, and nothing raises" do
      table = :fountain_chatgpt_refresh_breaker
      # Stopped through its supervisor, which does not start it again until
      # asked: killing it races the restart, and the table is usually back
      # before the first call.
      restart = fn -> Supervisor.restart_child(Fountain.Supervisor, RefreshBreaker.Table) end
      on_exit(restart)
      :ok = Supervisor.terminate_child(Fountain.Supervisor, RefreshBreaker.Table)
      assert :ets.whereis(table) == :undefined

      assert :ignored = RefreshBreaker.observe(Ecto.UUID.generate(), Ecto.UUID.generate())
      assert :ok = RefreshBreaker.succeeded()
      assert :closed = RefreshBreaker.claim_probe()
      assert :ok = RefreshBreaker.probe_refused()
      assert :ok = RefreshBreaker.release_probe()
      assert RefreshBreaker.probe_seconds() == 0
      assert RefreshBreaker.remaining_seconds() == 0
      refute RefreshBreaker.heard?(Ecto.UUID.generate())
      refute RefreshBreaker.open?()
      assert :ok = RefreshBreaker.reset()

      # A job runs as if it were down, which it is.
      account = idle_grant(insert_verified_user(), "rt_a")
      stub_token(%{"rt_a" => renewed(account, "rt_a2")})
      assert :ok = perform_job(Worker, args(account))

      assert {:ok, _pid} = restart.()
      assert :recorded = RefreshBreaker.observe(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "of many that ask at once, at the moment a claim runs out too, one is the probe" do
      clock(3_000_000)
      open_breaker()

      claims = fn ->
        1..50
        |> Enum.map(fn _ -> Task.async(&RefreshBreaker.claim_probe/0) end)
        |> Task.await_many()
        |> Enum.frequencies()
      end

      assert claims.() == %{claimed: 1, taken: 49}
      assert RefreshBreaker.probe_seconds() == 900

      # A pause length on the claim has run out and every caller sees a stale
      # one: each removes the tuple it read, never the one another just made.
      RefreshBreaker.probe_refused()
      clock(3_000_000 + 900_000)
      assert RefreshBreaker.probe_seconds() == 0
      assert claims.() == %{claimed: 1, taken: 49}
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

    test "one probe per node per pause: the first held job asks, a refused probe keeps it open by itself, and the rest do not ask" do
      clock(7_000_000)
      first = idle_grant(insert_verified_user(), "rt_a", recently_idle())
      second = idle_grant(insert_verified_user(), "rt_b", recently_idle())
      week_idle = idle_grant(insert_verified_user(), "rt_c", days_ago(8))
      stub_token(%{"rt_a" => throttled(), "rt_b" => throttled(), "rt_c" => throttled()})
      open_breaker()
      now = System.os_time(:second)
      held = %{"first_run_at" => now - 7_300, "breaker_deferred_at" => now - 7_300}

      # Ten minutes into the pause, and what opened it is ten minutes old:
      # nothing but the probe's own refusal can keep it open from here.
      clock(7_000_000 + 600_000)
      assert RefreshBreaker.remaining_seconds() == 300
      job = enqueue!(first, held)
      refute RefreshBreaker.heard?(first.id)

      assert %{snoozed: 1, failure: 0} = Oban.drain_queue(queue: :chatgpt_refresh)
      assert_received {:token_call, "rt_a"}

      # One owner's refusal, which opens nothing, and the probe's: it stands
      # for two pause lengths from the refusal, the next probe being one on.
      assert RefreshBreaker.heard?(first.id)
      assert RefreshBreaker.remaining_seconds() == 1_800
      assert RefreshBreaker.probe_seconds() == 900

      # The job has spent no attempt, its two hours start again, and it is
      # out of the probe's way for its back-off: its next wake is no request.
      waiting = Repo.get!(Oban.Job, job.id)
      assert waiting.state == "scheduled"
      assert waiting.max_attempts - waiting.attempt == 3
      assert_in_delta waiting.meta["breaker_deferred_at"], now, 5
      assert_in_delta waiting.meta["refused_at"], now, 5
      assert waiting.meta["refusals"] == 1
      assert DateTime.diff(waiting.scheduled_at, DateTime.utc_now()) >= 1_790

      assert %{snoozed: 1} = Oban.drain_queue(queue: :chatgpt_refresh, with_scheduled: true)
      refute_received {:token_call, _}

      # Held as long, and eight days idle: the pause's probe is spent. They
      # wake when the next can be claimed, which is before the pause ends.
      log =
        capture_log([level: :error], fn ->
          for {grant, meta} <- [{second, held}, {week_idle, %{}}], _ <- 1..10 do
            assert {:snooze, seconds} = perform_job(Worker, args(grant), meta: meta)
            assert seconds >= 900 + 1 and seconds <= 900 + 120
          end
        end)

      refute_received {:token_call, _}

      # A held grant known to be seven days unrenewed is said at `error`,
      # once a minute; one held two hours and six days idle is not.
      assert log =~ "grant #{week_idle.id} has gone 8 days unrenewed"
      assert length(String.split(log, "days unrenewed")) == 2
      refute log =~ second.id
      refute log =~ week_idle.user_id

      # A pause length after the claim there is one more probe, and one only,
      # with the breaker still standing on the first probe's refusal alone.
      clock(7_000_000 + 600_000 + 900_000)
      assert RefreshBreaker.remaining_seconds() == 900
      assert {:snooze, _} = perform_job(Worker, args(week_idle))
      assert_received {:token_call, "rt_c"}
      assert RefreshBreaker.remaining_seconds() == 1_800
      assert {:snooze, _} = perform_job(Worker, args(second), meta: held)
      refute_received {:token_call, _}
    end

    test "a probe refused after a success closed it does not stand it up again" do
      open_breaker()
      assert :claimed = RefreshBreaker.claim_probe()
      assert :closed = RefreshBreaker.succeeded()
      assert :ok = RefreshBreaker.probe_refused()
      refute RefreshBreaker.open?()
    end

    test "a refused grant is out of the probe's way for two hours, then four, up to a day, even seven days idle" do
      attacker = idle_grant(insert_verified_user(), "rt_x", days_ago(9))
      stub_token(%{"rt_x" => throttled()})
      open_breaker()
      now = System.os_time(:second)
      hour = 3_600

      refused = fn refusals, ago ->
        %{
          "first_run_at" => now - 8 * hour,
          "breaker_deferred_at" => now - 8 * hour,
          "refused_at" => now - ago,
          "refusals" => refusals
        }
      end

      # {refusals so far, seconds since the last, whether it may probe}
      for {refusals, ago, due?} <- [
            {1, 2 * hour - 60, false},
            {1, 2 * hour, true},
            {2, 4 * hour - 60, false},
            {2, 4 * hour, true},
            {3, 8 * hour - 60, false},
            {4, 16 * hour - 60, false},
            {4, 16 * hour, true},
            {5, 24 * hour - 60, false},
            {5, 24 * hour, true},
            {40, 24 * hour - 60, false},
            {40, 24 * hour, true}
          ] do
        RefreshBreaker.release_probe()

        result =
          capture_log_result(fn ->
            perform_job(Worker, args(attacker), meta: refused.(refusals, ago))
          end)

        if due? do
          assert {:snooze, _} = result
          assert_received {:token_call, "rt_x"}
        else
          # It sleeps to the end of its back-off, not a second past it and
          # not in a loop of half-minutes because its grant is long idle.
          assert {:snooze, seconds} = result
          assert seconds >= 60 and seconds <= 60 + 120
          refute_received {:token_call, _}
          assert RefreshBreaker.probe_seconds() == 0
        end
      end
    end

    test "a victim's job is the probe while the refused grants wait out their back-off, and the count is kept on the row" do
      clock(9_000_000)
      victim = idle_grant(insert_verified_user(), "rt_v", days_ago(7))
      attackers = for n <- 1..2, do: idle_grant(insert_verified_user(), "rt_x#{n}", days_ago(9))

      answers =
        Map.new(attackers, &{Cipher.decrypt_token(&1, :refresh_token) |> elem(1), throttled()})

      stub_token(Map.put(answers, "rt_v", renewed(victim, "rt_v2")))

      # The attackers' jobs run first, breaker down, and are refused: the
      # second owner's refusal stands it up. Real rows, so `meta` is theirs.
      jobs = Enum.map(attackers, &enqueue!/1)
      capture_log(fn -> assert %{snoozed: 2} = Oban.drain_queue(queue: :chatgpt_refresh) end)
      assert RefreshBreaker.open?()
      for _ <- attackers, do: assert_received({:token_call, "rt_x" <> _})

      for job <- jobs do
        assert %{"refusals" => 1, "refused_at" => at} = meta(job)
        assert is_integer(at)
      end

      # They wake, nine days idle every one, and none of them asks to probe.
      capture_log(fn ->
        assert %{snoozed: 2} = Oban.drain_queue(queue: :chatgpt_refresh, with_scheduled: true)
      end)

      refute_received {:token_call, _}
      assert RefreshBreaker.probe_seconds() == 0
      for job <- jobs, do: assert(%{"refusals" => 1} = meta(job))

      # The victim's, seven days idle, is the probe, and its success closes it.
      victim_job = enqueue!(victim)

      Repo.update_all(from(j in Oban.Job, where: j.id in ^Enum.map(jobs, & &1.id)),
        set: [scheduled_at: DateTime.add(DateTime.utc_now(), 3_600)]
      )

      assert %{success: 1} = Oban.drain_queue(queue: :chatgpt_refresh)
      assert state(victim_job) == "completed"
      assert_received {:token_call, "rt_v"}
      refute RefreshBreaker.open?()

      # A second refusal, breaker down, doubles the first job's back-off.
      [job | _] = jobs

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [scheduled_at: DateTime.utc_now(), state: "available"]
      )

      assert %{snoozed: 1} = Oban.drain_queue(queue: :chatgpt_refresh)
      assert %{"refusals" => 2} = meta(job)
    end

    test "a probe that asked the auth server nothing gives the turn back" do
      user = insert_verified_user()
      crowded = idle_grant(user, "rt_a", days_ago(7))

      renewed_already =
        user_grant!(insert_verified_user().id, %{
          refresh_token: "rt_b",
          access_token: access_token(7_200),
          last_refreshed_at: days_ago(0)
        })

      suspended = idle_grant(insert_verified_user(), "rt_c", days_ago(7))
      stub_token(%{})
      open_breaker()
      crowded_id = crowded.id

      stub(RefreshCoordinator, :run, fn
        ^crowded_id, _user_id, _generation ->
          {:error, :refresh_busy}

        id, user_id, generation ->
          call_original(RefreshCoordinator, :run, [id, user_id, generation])
      end)

      # Crowded out: it waits its minute, and the next due job may probe.
      assert {:snooze, seconds} = perform_job(Worker, args(crowded))
      assert seconds >= 61 and seconds <= 120
      assert RefreshBreaker.probe_seconds() == 0

      # An owner suspended since the sweep. The held job's first read is by
      # owner alone and sees an active grant; the renewal's own read joins
      # the eligible owner, asks nobody and ends the job, turn given back.
      mutate(:suspend, suspended)
      assert {:cancel, :not_connected} = perform_job(Worker, args(suspended))
      assert RefreshBreaker.probe_seconds() == 0

      # Held two hours, and renewed by somebody else meanwhile: `:ok` with
      # no request, so the breaker still stands and the turn goes back.
      now = System.os_time(:second)
      held = %{"first_run_at" => now - 7_300, "breaker_deferred_at" => now - 7_300}
      assert :ok = perform_job(Worker, args(renewed_already), meta: held)
      assert RefreshBreaker.open?()
      assert RefreshBreaker.probe_seconds() == 0

      refute_received {:token_call, _}
      assert :claimed = RefreshBreaker.claim_probe()
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

    test "a held job sleeps thirty seconds at least, however little of the pause is left" do
      clock(4_000_000)
      account = idle_grant(insert_verified_user(), "rt_a", recently_idle())
      stub_token(%{})
      open_breaker()
      clock(4_000_000 + 899_000)
      assert RefreshBreaker.remaining_seconds() == 1

      for _ <- 1..20 do
        assert {:snooze, seconds} = perform_job(Worker, args(account), meta: %{"window" => 1})
        assert seconds == 31
      end
    end

    test "a grant with no renewal on record is due to probe at once, and is not said to be seven days idle" do
      # The changeset requires it and the column does not.
      never = idle_grant(insert_verified_user(), "rt_a")
      other = idle_grant(insert_verified_user(), "rt_b")

      Repo.update_all(from(a in Account, where: a.id in ^[never.id, other.id]),
        set: [last_refreshed_at: nil]
      )

      stub_token(%{"rt_a" => throttled()})
      open_breaker()

      log =
        capture_log([level: :error], fn ->
          assert {:snooze, _} = perform_job(Worker, args(never))
          assert_received {:token_call, "rt_a"}
          assert {:snooze, _} = perform_job(Worker, args(other))
          refute_received {:token_call, _}
        end)

      refute log =~ "days unrenewed"
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
