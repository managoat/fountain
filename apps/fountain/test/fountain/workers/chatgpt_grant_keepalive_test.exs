defmodule Fountain.Workers.ChatGPTGrantKeepaliveTest do
  # Real refresh through the shared coordinator and provider stub.
  use Fountain.DataCase, async: false

  import Fountain.ChatGPTFixtures

  alias Fountain.Audit.Event
  alias Fountain.ChatGPTAccounts
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.Workers.ChatGPTGrantKeepalive

  test "a persisted job renews an idle grant and stores only IDs" do
    account = idle_grant()

    stub_refresh(%{
      expect_refresh: "rt_user",
      id_token: id_token(%{account_id: account.account_id})
    })

    {:ok, job} = account |> args() |> ChatGPTGrantKeepalive.new() |> Oban.insert()

    assert Map.keys(Repo.get!(Oban.Job, job.id).args) |> Enum.sort() ==
             ~w(generation grant_id user_id)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :chatgpt_refresh)
    assert Repo.get!(Oban.Job, job.id).state == "completed"
    assert Repo.get!(Account, account.id).lock_version == account.lock_version + 1
  end

  for mutation <- [:disconnect, :reconnect, :suspend] do
    test "a queued job cannot undo #{mutation}" do
      account = idle_grant()
      {:ok, job} = account |> args() |> ChatGPTGrantKeepalive.new() |> Oban.insert()
      mutate(unquote(mutation), account)
      stub_auth(%{})
      assert %{cancelled: 1, failure: 0} = Oban.drain_queue(queue: :chatgpt_refresh)
      assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    end
  end

  test "a grant renewed before job execution does not exchange again" do
    account = idle_grant()

    stub_refresh(%{
      expect_refresh: "rt_user",
      id_token: id_token(%{account_id: account.account_id})
    })

    assert {:ok, _} =
             ChatGPTAccounts.credential_for_user(account.id, account.user_id, account.generation)

    current = Repo.get!(Account, account.id)
    stub_auth(%{})
    assert :ok = perform_job(ChatGPTGrantKeepalive, args(account))
    assert Repo.get!(Account, account.id).lock_version == current.lock_version
  end

  test "terminal provider rejection cancels the job and records tenant reconnect-required" do
    account = idle_grant()
    stub_refusal()
    {:ok, job} = account |> args() |> ChatGPTGrantKeepalive.new() |> Oban.insert()
    assert %{cancelled: 1, failure: 0} = Oban.drain_queue(queue: :chatgpt_refresh)
    assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    assert Repo.get!(Account, account.id).status == "revoked"

    assert Repo.exists?(
             from(e in Event,
               where: e.user_id == ^account.user_id and e.action == "chatgpt.reconnect_required"
             )
           )
  end

  test "transient errors retry with backoff and stop after five attempts without storing provider bodies" do
    account = idle_grant()
    secret = "synthetic-provider-echo"

    stub_auth(%{
      "/oauth/token" => fn _ ->
        {503, %{"error" => "unavailable", "error_description" => secret}}
      end
    })

    {:ok, job} = account |> args() |> ChatGPTGrantKeepalive.new() |> Oban.insert()
    assert %{failure: 1} = Oban.drain_queue(queue: :chatgpt_refresh)
    retry = Repo.get!(Oban.Job, job.id)
    assert retry.state == "retryable"
    assert retry.attempt == 1
    assert DateTime.compare(retry.scheduled_at, DateTime.utc_now()) == :gt
    refute inspect(retry.errors) =~ secret

    for _ <- 2..5 do
      Oban.drain_queue(queue: :chatgpt_refresh, with_scheduled: true)
    end

    exhausted = Repo.get!(Oban.Job, job.id)
    assert exhausted.state == "discarded"
    assert exhausted.attempt == 5
    refute inspect(exhausted.errors) =~ secret
    assert Repo.get!(Account, account.id) == account
  end

  test "malformed or extra job arguments are refused" do
    assert {:cancel, :invalid_args} = perform_job(ChatGPTGrantKeepalive, %{"grant_id" => "bad"})
    account = idle_grant()

    assert {:cancel, :invalid_args} =
             perform_job(
               ChatGPTGrantKeepalive,
               Map.put(args(account), :access_token, "unexpected")
             )
  end

  defp idle_grant,
    do: user_grant!(insert_verified_user().id, %{last_refreshed_at: ~U[2020-01-01 00:00:00Z]})

  defp args(account),
    do: %{grant_id: account.id, user_id: account.user_id, generation: account.generation}

  defp mutate(:disconnect, account), do: Repo.delete!(account)

  defp mutate(:reconnect, account),
    do: account |> Account.connect_changeset(%{}) |> Repo.update!()

  defp mutate(:suspend, account) do
    Fountain.Accounts.User
    |> Repo.get!(account.user_id)
    |> change(suspended_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end
end
