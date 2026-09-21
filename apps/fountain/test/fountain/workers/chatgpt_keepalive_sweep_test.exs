defmodule Fountain.Workers.ChatGPTKeepaliveSweepTest do
  # ADR 0060 stage 5: the daily sweep reads ids and writes jobs, and nothing
  # else. No provider stub here on purpose: nothing in this file may call one.
  # `async: false` for the one platform row and the spacing in application env.
  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog
  import Fountain.ChatGPTFixtures

  alias Fountain.Accounts.{User, UserDataKey}
  alias Fountain.ChatGPTAccounts
  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.Workers.ChatGPTGrantKeepalive
  alias Fountain.Workers.ChatGPTKeepaliveSweep, as: Sweep

  @long_ago ~U[2020-01-01 00:00:00Z]

  describe "what is due" do
    test "an idle grant of an eligible owner, as three ids, without a key being loaded" do
      user = insert_verified_user()
      due = user_grant!(user.id, %{last_refreshed_at: @long_ago, refresh_token: "rt_SECRET_due"})
      never = user_grant!(user.id, %{last_refreshed_at: @long_ago})
      never |> change(last_refreshed_at: nil) |> Repo.update!()

      # Renewed inside the six days, by the same owner: not due.
      recent = user_grant!(user.id)
      edge = DateTime.add(now(), -6 * 86_400 + 60, :second)
      recent |> change(last_refreshed_at: edge) |> Repo.update!()

      stub(Crypto, :load_tenant_key, fn _ -> flunk("the sweep loaded a key") end)
      stub(Crypto, :decrypt_platform, fn _ -> flunk("the sweep decrypted a token") end)

      expected = [due, never] |> Enum.map(&pin/1) |> Enum.sort_by(& &1.grant_id)
      assert ChatGPTAccounts._unsafe_due_user_grants() == expected
      assert ChatGPTAccounts._unsafe_due_user_grant_count() == 2

      assert :ok = perform_job(Sweep, %{})
      jobs = jobs(ChatGPTGrantKeepalive)

      assert Enum.map(jobs, & &1.args) |> Enum.sort() ==
               expected |> Enum.map(&stringify/1) |> Enum.sort()

      for job <- jobs do
        assert job.args |> Map.keys() |> Enum.sort() == ~w(generation grant_id user_id)
        assert job.queue == "chatgpt_refresh"
        refute inspect(job) =~ "rt_SECRET"
      end
    end

    test "never a tombstone, a revoked or expired grant, a suspended or ineligible owner's, or the platform row" do
      user = insert_verified_user()

      tombstone = user_grant!(user.id, %{last_refreshed_at: @long_ago})
      :ok = ChatGPTAccounts.disconnect_for_user(tombstone.id, user.id)
      assert %{status: "disconnected"} = Repo.get!(Account, tombstone.id)

      for status <- ["revoked", "expired"] do
        user.id
        |> user_grant!(%{last_refreshed_at: @long_ago})
        |> change(status: status)
        |> Repo.update!()
      end

      for attrs <- [%{suspended_at: now()}, %{email_verified_at: nil}, %{principal: true}] do
        owner = insert_verified_user()
        user_grant!(owner.id, %{last_refreshed_at: @long_ago})
        User |> Repo.get!(owner.id) |> change(attrs) |> Repo.update!()
      end

      platform = connect!()
      platform |> change(last_refreshed_at: @long_ago) |> Repo.update!()

      assert ChatGPTAccounts._unsafe_due_user_grants() == []
      assert ChatGPTAccounts._unsafe_due_user_grant_count() == 0
      assert :ok = perform_job(Sweep, %{})
      assert jobs(ChatGPTGrantKeepalive) == []
      assert jobs(Sweep) == []
    end
  end

  describe "paging" do
    test "a page is at most 100 jobs and a continuation, and a replay queues nothing twice" do
      grants = for _ <- 1..101, do: due_grant!()
      ids = grants |> Enum.map(& &1.id) |> Enum.sort()

      assert :ok = perform_job(Sweep, %{})
      first_jobs = jobs(ChatGPTGrantKeepalive)
      assert length(first_jobs) == 100
      assert Enum.sort(Enum.map(first_jobs, & &1.args["grant_id"])) == Enum.take(ids, 100)

      [continuation] = jobs(Sweep)
      assert continuation.args == %{"after_id" => Enum.at(ids, 99), "due" => 101}

      # The same page again: the same hundred jobs and the same continuation.
      assert :ok = perform_job(Sweep, %{})
      assert Enum.map(jobs(ChatGPTGrantKeepalive), & &1.id) == Enum.map(first_jobs, & &1.id)
      assert length(jobs(Sweep)) == 1

      assert :ok = perform_job(Sweep, continuation.args)
      all = jobs(ChatGPTGrantKeepalive)
      assert Enum.sort(Enum.map(all, & &1.args["grant_id"])) == ids
      assert length(jobs(Sweep)) == 1
      assert ChatGPTAccounts._unsafe_due_user_grants(List.last(ids), 100) == []
    end

    test "an undurable unique insert rolls back the page and can be retried" do
      for _ <- 1..3, do: due_grant!()
      Process.put(:keepalive_insert_count, 0)

      stub(Oban, :insert, fn changeset ->
        count = Process.get(:keepalive_insert_count)
        Process.put(:keepalive_insert_count, count + 1)

        if count == 2 do
          # Basic.insert_unique/3 returns this when another transaction holds
          # its uniqueness lock. That transaction may still roll back.
          {:ok, %{apply_changes(changeset) | id: nil, conflict?: true}}
        else
          Mimic.call_original(Oban, :insert, [changeset])
        end
      end)

      assert {:error, :enqueue_failed} = perform_job(Sweep, %{})
      assert jobs(ChatGPTGrantKeepalive) == []

      stub(Oban, :insert, fn changeset -> Mimic.call_original(Oban, :insert, [changeset]) end)
      assert :ok = perform_job(Sweep, %{})
      assert length(jobs(ChatGPTGrantKeepalive)) == 3
    end
  end

  describe "a page that fails its last attempt" do
    test "says at error where the sweep stopped, and only then" do
      for _ <- 1..2, do: due_grant!()
      stub(Oban, :insert, fn changeset -> {:ok, %{apply_changes(changeset) | id: nil}} end)
      cursor = "00000000-0000-0000-0000-000000000000"
      args = %{"after_id" => cursor, "due" => 2}

      quiet =
        capture_log(fn ->
          assert {:error, :enqueue_failed} = perform_job(Sweep, args, attempt: 1, max_attempts: 3)
        end)

      refute quiet =~ "the sweep stopped"

      log =
        capture_log(fn ->
          assert {:error, :enqueue_failed} = perform_job(Sweep, args, attempt: 3, max_attempts: 3)
        end)

      assert log =~ "[error]"
      assert log =~ "the sweep stopped after \"#{cursor}\""
    end

    test "a page that raises says the same and still raises" do
      due_grant!()
      stub(Oban, :insert, fn _changeset -> raise "the database went away" end)

      log =
        capture_log(fn ->
          assert_raise RuntimeError, fn ->
            Sweep.perform(%Oban.Job{args: %{}, attempt: 3, max_attempts: 3})
          end
        end)

      assert log =~ "the sweep stopped after nil"
    end
  end

  describe "the jitter" do
    test "the window is five seconds a grant, no shorter than five minutes, no longer than six hours" do
      assert Sweep.window_seconds(0) == 300
      assert Sweep.window_seconds(60) == 300
      assert Sweep.window_seconds(61) == 305
      assert Sweep.window_seconds(1_000) == 5_000
      assert Sweep.window_seconds(4_320) == 21_600
      assert Sweep.window_seconds(1_000_000) == 21_600
    end

    test "the spacing is configuration" do
      Application.put_env(:fountain, :chatgpt_keepalive_spacing_ms, 500)
      on_exit(fn -> Application.delete_env(:fountain, :chatgpt_keepalive_spacing_ms) end)
      assert Sweep.window_seconds(1_000) == 500
    end

    test "a few grants are spread over five minutes" do
      for _ <- 1..3, do: due_grant!()
      before = DateTime.utc_now()
      assert :ok = perform_job(Sweep, %{})

      for job <- jobs(ChatGPTGrantKeepalive) do
        wait = DateTime.diff(job.scheduled_at, before)
        assert wait >= 0 and wait <= 301
        # The window rides in meta, for a job the breaker holds; the args
        # are still the three ids.
        assert job.meta == %{"window" => 300}
        assert job.args |> Map.keys() |> Enum.sort() == ~w(generation grant_id user_id)
      end
    end

    test "a page's jobs are spread over the window of the whole count, not of the page" do
      for _ <- 1..3, do: due_grant!()
      [first | _] = ChatGPTAccounts._unsafe_due_user_grants()
      before = DateTime.utc_now()

      # A continuation of a sweep that counted 4,000 due: a 20,000 s window.
      # The cursor is below every id, so all three are on this page.
      cursor = "00000000-0000-0000-0000-000000000000"
      assert first.grant_id > cursor
      assert :ok = perform_job(Sweep, %{"after_id" => cursor, "due" => 4_000})

      waits = for job <- jobs(ChatGPTGrantKeepalive), do: DateTime.diff(job.scheduled_at, before)
      assert length(waits) == 3
      assert Enum.all?(waits, &(&1 >= 0 and &1 <= 20_001))
      # Three uniform draws from 20,000 s all landing inside the first five
      # minutes is a chance of about three in a million.
      assert Enum.max(waits) > 300
    end
  end

  test "only incomplete work for the same owner, grant and generation is deduplicated" do
    account = due_grant!()
    {:ok, first} = account |> pin() |> ChatGPTGrantKeepalive.new() |> Oban.insert()
    {:ok, same} = account |> pin() |> ChatGPTGrantKeepalive.new() |> Oban.insert()
    assert same.id == first.id

    {:ok, reconnected} =
      account
      |> pin()
      |> Map.put(:generation, Ecto.UUID.generate())
      |> ChatGPTGrantKeepalive.new()
      |> Oban.insert()

    refute reconnected.id == first.id

    first |> change(state: "completed") |> Repo.update!()
    {:ok, next_day} = account |> pin() |> ChatGPTGrantKeepalive.new() |> Oban.insert()
    refute next_day.id == first.id
  end

  test "an empty sweep, or one with args it does not know, queues nothing" do
    assert :ok = perform_job(Sweep, %{})
    assert {:cancel, :invalid_args} = perform_job(Sweep, %{"after_id" => "invalid", "due" => 1})
    assert {:cancel, :invalid_args} = perform_job(Sweep, %{"after_id" => Ecto.UUID.generate()})
    assert {:cancel, :invalid_args} = perform_job(Sweep, %{"access_token" => "unexpected"})
    assert jobs(ChatGPTGrantKeepalive) == []
    assert jobs(Sweep) == []
  end

  test "the sweep says how many were due, once, from the first page" do
    for _ <- 1..2, do: due_grant!()
    test_pid = self()
    handler = "keepalive-sweep-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:fountain, :chatgpt, :keepalive, :sweep],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:sweep, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = perform_job(Sweep, %{})
    assert_received {:sweep, %{due: 2}, metadata}
    assert metadata == %{}
  end

  test "the queue is smaller than the coordinator's room, and the sweep is on the daily cron" do
    config = Application.fetch_env!(:fountain, Oban)
    assert config[:queues][:chatgpt_refresh] == 2

    assert config[:queues][:chatgpt_refresh] <
             :sys.get_state(ChatGPTAccounts.RefreshCoordinator).max_concurrency

    {Oban.Plugins.Cron, cron} = Enum.find(config[:plugins], &match?({Oban.Plugins.Cron, _}, &1))
    assert {"37 4 * * *", Sweep} in cron[:crontab]
  end

  # An owner made without `insert_verified_user/1`'s opening credit and
  # welcome work: 101 of them is the paging test's whole cost.
  defp due_grant! do
    user =
      Repo.insert!(%User{
        email: "keepalive-#{Ecto.UUID.generate()}@example.test",
        email_verified_at: now()
      })

    Repo.insert!(%UserDataKey{
      user_id: user.id,
      wrapped_key: Crypto.wrap_dek(Crypto.generate_dek())
    })

    user_grant!(user.id, %{last_refreshed_at: @long_ago})
  end

  defp jobs(worker) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^Oban.Worker.to_string(worker),
        order_by: [asc: j.id]
      )
    )
  end

  defp pin(account),
    do: %{grant_id: account.id, user_id: account.user_id, generation: account.generation}

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
