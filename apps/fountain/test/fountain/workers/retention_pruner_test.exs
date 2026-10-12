defmodule Fountain.Workers.RetentionPrunerTest do
  @moduledoc """
  Retention pruning.

  `log_events` is 114MB of a 155MB production database and had no pruning at
  all — the only mechanism was a `DELETE` pasted in the runbook for a human to
  run. But it also holds the visible output of a conversation, so the risk here
  runs both ways: too little pruning fills the volume, too much silently deletes
  what a user sees when they open an old conversation.

  These lean on the boundaries rather than the happy path, because deleting the
  wrong row is not recoverable from inside the app.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Repo
  alias Fountain.Workers.RetentionPruner

  defp days_ago(n),
    do: DateTime.utc_now() |> DateTime.add(-n * 86_400, :second) |> DateTime.truncate(:second)

  defp with_windows(overrides, fun) do
    original = Application.get_env(:fountain, :retention_days, [])
    Application.put_env(:fountain, :retention_days, overrides)

    try do
      fun.()
    after
      Application.put_env(:fountain, :retention_days, original)
    end
  end

  defp log_at(conv, at), do: insert_log_event(conv, %{inserted_at: at})

  defp log_event_count(conv) do
    Repo.one(
      from e in "log_events",
        where: e.conversation_id == type(^conv.id, :binary_id),
        select: count(e.id)
    )
  end

  describe "sandbox_requests" do
    defp insert_request!(user, agent, status, at) do
      %Fountain.SandboxQueue.Request{}
      |> Fountain.SandboxQueue.Request.changeset(%{
        user_id: user.id,
        agent_id: agent.id,
        kind: "start",
        status: status
      })
      |> Repo.insert!()
      # `sandbox_requests` timestamps are :utc_datetime_usec, and days_ago/1
      # truncates to the second.
      |> Ecto.Changeset.change(inserted_at: DateTime.add(at, 0, :microsecond))
      |> Repo.update!()
    end

    test "prunes finished rows and never touches live work" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      old_started = insert_request!(user, agent, "started", days_ago(60))
      old_failed = insert_request!(user, agent, "failed", days_ago(60))
      recent = insert_request!(user, agent, "started", days_ago(1))
      # Only reachable by a window shorter than the wait bound, or a clock
      # that moved. Either way an unstarted request is not history.
      stale_queued = insert_request!(user, agent, "queued", days_ago(60))

      with_windows([sandbox_requests: 30], fn ->
        assert RetentionPruner.prune(:sandbox_requests) == 2
      end)

      assert Repo.get(Fountain.SandboxQueue.Request, old_started.id) == nil
      assert Repo.get(Fountain.SandboxQueue.Request, old_failed.id) == nil
      assert Repo.get(Fountain.SandboxQueue.Request, recent.id)
      assert Repo.get(Fountain.SandboxQueue.Request, stale_queued.id)
    end

    test "a claimed row is live work too" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      claimed = insert_request!(user, agent, "starting", days_ago(60))

      with_windows([sandbox_requests: 30], fn ->
        assert RetentionPruner.prune(:sandbox_requests) == 0
      end)

      assert Repo.get(Fountain.SandboxQueue.Request, claimed.id)
    end
  end

  describe "log_events" do
    test "prunes rows past the window and keeps the rest" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      log_at(conv, days_ago(200))
      log_at(conv, days_ago(120))
      log_at(conv, days_ago(10))

      with_windows([log_events: 90], fn ->
        assert RetentionPruner.prune(:log_events) == 2
      end)

      assert log_event_count(conv) == 1
    end

    test "the default window deletes nothing that exists today" do
      # The production database is three months old and has no log_events older
      # than 90 days, so shipping this default cannot delete a single row. That
      # is deliberate: it bounds growth from here and leaves room to choose a
      # different number before it ever removes anything.
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      log_at(conv, days_ago(80))

      assert RetentionPruner.window_days(:log_events) == 90
      assert RetentionPruner.prune(:log_events) == 0
      assert log_event_count(conv) == 1
    end

    test "a nil window disables pruning entirely" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      log_at(conv, days_ago(9999))

      with_windows([log_events: nil], fn ->
        assert RetentionPruner.prune(:log_events) == 0
      end)

      assert log_event_count(conv) == 1
    end

    test "batches through a backlog larger than one batch" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      for _ <- 1..40, do: log_at(conv, days_ago(200))

      with_windows([log_events: 90], fn ->
        assert RetentionPruner.prune(:log_events) == 40
      end)

      assert log_event_count(conv) == 0
    end
  end

  describe "api_keys" do
    test "prunes long-revoked keys" do
      user = insert_verified_user()
      {key, _raw} = insert_api_key(user, "old")

      {:ok, _} =
        key
        |> Ecto.Changeset.change(revoked_at: days_ago(60))
        |> Repo.update()

      with_windows([revoked_api_keys: 30], fn ->
        assert RetentionPruner.prune(:revoked_api_keys) == 1
      end)

      refute Repo.get(Fountain.Accounts.ApiKey, key.id)
    end

    test "never prunes an active key, however old" do
      # Deleting a live key silently breaks whoever holds it, so age alone must
      # not be enough.
      user = insert_verified_user()
      {key, _raw} = insert_api_key(user, "ancient-but-live")

      {:ok, _} =
        key
        |> Ecto.Changeset.change(inserted_at: days_ago(9999))
        |> Repo.update()

      with_windows([revoked_api_keys: 1], fn ->
        assert RetentionPruner.prune(:revoked_api_keys) == 0
      end)

      assert Repo.get(Fountain.Accounts.ApiKey, key.id)
    end

    test "keeps a recently revoked key" do
      user = insert_verified_user()
      {key, _raw} = insert_api_key(user, "just-revoked")
      {:ok, _} = Fountain.Accounts.revoke_api_key(user.id, key.id)

      with_windows([revoked_api_keys: 30], fn ->
        assert RetentionPruner.prune(:revoked_api_keys) == 0
      end)

      assert Repo.get(Fountain.Accounts.ApiKey, key.id)
    end

    test "prunes a long-expired key that nothing ever revoked" do
      # Every hard kill (SIGKILL on the pod, the provision watchdog) leaves
      # an un-revoked sprite callback key behind. It goes inert at
      # expires_at — auth enforces expiry — but its row used to stay
      # forever in the table every authenticated request looks up against.
      user = insert_verified_user()
      {key, _raw} = insert_api_key(user, "orphaned-sprite-key")

      {:ok, _} =
        key
        |> Ecto.Changeset.change(expires_at: days_ago(60))
        |> Repo.update()

      with_windows([revoked_api_keys: 30], fn ->
        assert RetentionPruner.prune(:revoked_api_keys) == 1
      end)

      refute Repo.get(Fountain.Accounts.ApiKey, key.id)
    end

    test "keeps an expired-but-recent key inside the window" do
      # The window is grace time: a just-expired key may still matter for
      # debugging ("why did the sprite 401?").
      user = insert_verified_user()
      {key, _raw} = insert_api_key(user, "freshly-expired")

      {:ok, _} =
        key
        |> Ecto.Changeset.change(expires_at: days_ago(2))
        |> Repo.update()

      with_windows([revoked_api_keys: 30], fn ->
        assert RetentionPruner.prune(:revoked_api_keys) == 0
      end)

      assert Repo.get(Fountain.Accounts.ApiKey, key.id)
    end
  end

  describe "usage_events" do
    test "gets the longest window, because it is billing input" do
      assert RetentionPruner.window_days(:usage_events) == 400
      assert RetentionPruner.window_days(:usage_events) > RetentionPruner.window_days(:log_events)
    end
  end

  describe "perform/1" do
    test "runs every configured table without raising" do
      assert :ok = perform_job(RetentionPruner, %{})
    end

    test "is scheduled after the nightly backup" do
      # Pruning must not race the 03:17 pg_dump, so a backup always captures the
      # pre-prune state.
      crontab =
        Application.fetch_env!(:fountain, Oban)
        |> Keyword.fetch!(:plugins)
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
          _ -> nil
        end)

      assert {"23 4 * * *", RetentionPruner} in crontab
    end
  end
end
