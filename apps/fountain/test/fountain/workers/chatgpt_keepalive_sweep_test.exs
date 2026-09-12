defmodule Fountain.Workers.ChatGPTKeepaliveSweepTest do
  use Fountain.DataCase, async: true
  use Mimic

  import Fountain.ChatGPTFixtures

  alias Fountain.Accounts.{User, UserDataKey}
  alias Fountain.ChatGPTAccounts
  alias Fountain.Crypto
  alias Fountain.Workers.{ChatGPTGrantKeepalive, ChatGPTKeepaliveSweep}

  test "the scan returns only eligible idle user grant IDs without loading a key" do
    due = due_grant!()
    recent = due_grant!()
    recent |> change(last_refreshed_at: now()) |> Repo.update!()

    for attrs <- [
          %{status: "revoked"},
          %{status: "expired"},
          %{kind: "workspace_token"},
          %{refresh_token_ciphertext: nil},
          %{account_id: nil}
        ] do
      due_grant!() |> change(attrs) |> Repo.update!()
    end

    for attrs <- [%{principal: true}, %{email_verified_at: nil}, %{suspended_at: now()}] do
      account = due_grant!()
      User |> Repo.get!(account.user_id) |> change(attrs) |> Repo.update!()
    end

    platform = connect!()
    platform |> change(last_refreshed_at: ~U[2020-01-01 00:00:00Z]) |> Repo.update!()
    stub(Crypto, :load_tenant_key, fn _ -> flunk("sweep loaded a key") end)
    stub(Crypto, :decrypt_platform, fn _ -> flunk("sweep decrypted a token") end)

    assert ChatGPTAccounts._unsafe_due_user_grants() == [pin(due)]
    assert :ok = perform_job(ChatGPTKeepaliveSweep, %{})
    [job] = jobs(ChatGPTGrantKeepalive)
    assert job.args == stringify(pin(due))
    refute inspect(job.args) =~ "rt_user"
  end

  test "each page schedules at most 100 jobs and a continuation, with replay-safe jitter" do
    grants = for _ <- 1..101, do: due_grant!()
    ids = grants |> Enum.map(& &1.id) |> Enum.sort()
    before = DateTime.utc_now()
    assert :ok = perform_job(ChatGPTKeepaliveSweep, %{})
    first_jobs = jobs(ChatGPTGrantKeepalive)
    assert length(first_jobs) == 100
    assert Enum.sort(Enum.map(first_jobs, & &1.args["grant_id"])) == Enum.take(ids, 100)
    [continuation] = jobs(ChatGPTKeepaliveSweep)
    assert continuation.args == %{"after_id" => Enum.at(ids, 99)}
    latest = DateTime.add(DateTime.utc_now(), 300, :second)

    for job <- first_jobs do
      assert DateTime.compare(job.scheduled_at, before) == :gt
      assert DateTime.compare(job.scheduled_at, latest) != :gt
      assert Map.keys(job.args) |> Enum.sort() == ~w(generation grant_id user_id)
    end

    assert :ok = perform_job(ChatGPTKeepaliveSweep, %{})
    assert Enum.map(jobs(ChatGPTGrantKeepalive), & &1.id) == Enum.map(first_jobs, & &1.id)
    assert length(jobs(ChatGPTKeepaliveSweep)) == 1
    assert :ok = perform_job(ChatGPTKeepaliveSweep, continuation.args)
    assert length(jobs(ChatGPTGrantKeepalive)) == 101
    assert length(jobs(ChatGPTKeepaliveSweep)) == 1
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

    assert {:error, :enqueue_failed} = perform_job(ChatGPTKeepaliveSweep, %{})
    assert jobs(ChatGPTGrantKeepalive) == []
    assert jobs(ChatGPTKeepaliveSweep) == []
    stub(Oban, :insert, fn changeset -> Mimic.call_original(Oban, :insert, [changeset]) end)
    assert :ok = perform_job(ChatGPTKeepaliveSweep, %{})
    assert length(jobs(ChatGPTGrantKeepalive)) == 3
  end

  test "only incomplete work for the same owner and generation is deduplicated" do
    account = due_grant!()
    {:ok, first} = account |> pin() |> ChatGPTGrantKeepalive.new() |> Oban.insert()
    {:ok, same} = account |> pin() |> ChatGPTGrantKeepalive.new() |> Oban.insert()
    assert same.id == first.id

    {:ok, replacement} =
      account
      |> pin()
      |> Map.put(:generation, Ecto.UUID.generate())
      |> ChatGPTGrantKeepalive.new()
      |> Oban.insert()

    refute replacement.id == first.id
    first |> change(state: "completed") |> Repo.update!()
    {:ok, later} = account |> pin() |> ChatGPTGrantKeepalive.new() |> Oban.insert()
    refute later.id == first.id
  end

  test "an empty or invalid sweep schedules no work" do
    assert :ok = perform_job(ChatGPTKeepaliveSweep, %{})

    assert {:cancel, :invalid_args} =
             perform_job(ChatGPTKeepaliveSweep, %{"after_id" => "invalid"})

    assert {:cancel, :invalid_args} =
             perform_job(ChatGPTKeepaliveSweep, %{"access_token" => "unexpected"})

    assert jobs(ChatGPTGrantKeepalive) == []
    assert jobs(ChatGPTKeepaliveSweep) == []
  end

  test "the daily sweep and provider queue have separate scheduling capacity" do
    config = Application.fetch_env!(:fountain, Oban)
    assert config[:queues][:chatgpt_refresh] == 4
    assert config[:queues][:maintenance] == 1
    {Oban.Plugins.Cron, cron} = Enum.find(config[:plugins], &match?({Oban.Plugins.Cron, _}, &1))
    assert {"37 4 * * *", ChatGPTKeepaliveSweep} in cron[:crontab]
  end

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

    user_grant!(user.id, %{last_refreshed_at: ~U[2020-01-01 00:00:00Z]})
  end

  defp jobs(worker),
    do:
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == ^Oban.Worker.to_string(worker),
          order_by: [asc: j.id]
        )
      )

  defp pin(account),
    do: %{grant_id: account.id, user_id: account.user_id, generation: account.generation}

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
