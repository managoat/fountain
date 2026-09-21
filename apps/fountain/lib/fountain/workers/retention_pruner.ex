defmodule Fountain.Workers.RetentionPruner do
  @moduledoc """
  Deletes rows past their retention window.

  Several tables grew without any bound: `log_events` is one row per stdout or
  stderr chunk from every sprite and is currently 114MB of a 155MB database, and
  the only pruning mechanism the project had was a `DELETE` statement pasted in
  the runbook for a human to run.

  ## Choosing the windows

  `log_events` is the one that matters for size and the one to be careful with,
  because it holds the visible output of a conversation — pruning it removes
  what a user sees when they open an old conversation, not just internal
  bookkeeping. The 90 day default deletes **nothing** today (no row is older
  than 90 days) while bounding growth from here, which leaves time to pick a
  different number before it ever removes anything.

  The rest are operational and safe to expire sooner: a revoked API key can
  never be used again, and `stripe_events` only has to outlive Stripe's
  three-day redelivery window to do its job.

  `webhook_deliveries` is one row per HTTP attempt at one event, and every
  attempt of a failing endpoint writes another. It is a debugging aid, not an
  event store, so it gets the shortest window of the lot.

  `sandbox_requests` is the same shape of bookkeeping (ADR 0042): a finished
  request holds no prompt, because every terminal transition erases `attrs`.
  What is left is provenance and an outcome that the audit trail already
  carries at its own, longer window. Waiting and claimed rows are never pruned
  whatever the window says: the cutoff must not be what decides that a row is
  live. A waiting row is bounded by `SANDBOX_QUEUE_MAX_WAIT_SECONDS`, and a
  claimed one by the drain reclaiming an abandoned claim rather than by any
  expiry, so neither is the pruner's to reason about.

  `usage_events` gets the longest window because it is the input to billing
  history, and `turn_images` is deliberately absent — those rows are owned by
  their turn and go when the conversation does.

  `agent_versions` is absent on purpose too: a version shares its agent's
  lifetime (FK cascade) rather than aging out — a version older than every
  conversation that ran it is still the only record of what the config was,
  and the table only grows by one row per config edit.

  `admin_audit_events` is also absent, **on purpose** (#452): it is the
  privilege trail — who suspended, comped, deleted or looked at whose account
  — and it only gains a row per manual admin action, so it stays small for
  years. Unbounded retention is the decision, not an oversight; do not "fix"
  it by adding a window here without revisiting that decision.

  Every window is configurable, and setting one to `nil` disables pruning for
  that table entirely.

  Two tables are swept here on their own, fixed terms rather than a window:
  expired account exports, and `chatgpt_link_attempts` (ADR 0060 stage 4),
  whose ended rows hold no secret and are deleted a week after they ended.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Fountain.Repo

  # admin_audit_events is deliberately NOT here — unbounded privilege trail,
  # see the moduledoc (#452) before adding it.
  @defaults [
    log_events: 90,
    audit_events: 365,
    stripe_events: 90,
    revoked_api_keys: 30,
    usage_events: 400,
    webhook_deliveries: 30,
    sandbox_requests: 30
  ]

  @impl Oban.Worker
  def perform(_job) do
    results =
      Enum.map(@defaults, fn {table, _} -> {table, prune(table)} end) ++
        [
          {:exports, Fountain.Exports.purge_expired()},
          {:chatgpt_link_attempts, Fountain.ChatGPTAccounts.purge_ended_attempts()}
        ]

    deleted = results |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if deleted > 0 do
      detail =
        results
        |> Enum.reject(&(elem(&1, 1) == 0))
        |> Enum.map_join(", ", fn {t, n} -> "#{t}=#{n}" end)

      Logger.info("retention: pruned #{deleted} rows (#{detail})")
    end

    record_run(results, deleted)

    :ok
  end

  # One summary row per run, not one per deleted row — the point is that the
  # trail can account for its own shrinkage, and per-row events would be the
  # thing being pruned.
  #
  # Written *after* the pruning, deliberately: a row written first would sit
  # inside the same transaction-less pass that deletes `audit_events`, and on a
  # run where the window had been shortened it could delete the record of
  # itself. Written after, this run's summary is always newer than its own
  # cutoff.
  #
  # `user_id: nil` — this is a system event spanning every tenant, so it
  # belongs to the admin views (`_unsafe_list_recent/1`) rather than to any one
  # trail. A zero-deletion run records nothing: it is the deletions that need
  # accounting for, and a daily row saying "removed nothing" would bury them.
  defp record_run(_results, 0), do: :ok

  defp record_run(results, deleted) do
    counts =
      results
      |> Enum.reject(&(elem(&1, 1) == 0))
      |> Map.new(fn {table, n} -> {to_string(table), n} end)

    Fountain.Audit.record(%{
      user_id: nil,
      action: "retention.pruned",
      resource_type: "retention_run",
      actor: "system:retention_pruner",
      metadata: Map.put(counts, "total", deleted)
    })
  end

  @doc "Retention window in days for `table`, or nil when disabled."
  def window_days(table) do
    :fountain
    |> Application.get_env(:retention_days, [])
    |> Keyword.get(table, Keyword.fetch!(@defaults, table))
  end

  @doc "Tables this worker prunes, with their default windows."
  def defaults, do: @defaults

  @doc """
  Delete expired rows from one table. Returns the number deleted.

  Public so a pruning run can be triggered and asserted directly rather than
  only through the scheduler.
  """
  def prune(table) do
    case window_days(table) do
      nil -> 0
      days -> do_prune(table, cutoff(days))
    end
  end

  defp cutoff(days), do: DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

  defp do_prune(:log_events, cutoff) do
    delete_where("log_events", dynamic([r], r.inserted_at < ^cutoff))
  end

  defp do_prune(:audit_events, cutoff) do
    delete_where("audit_events", dynamic([r], r.inserted_at < ^cutoff))
  end

  defp do_prune(:stripe_events, cutoff) do
    delete_where("stripe_events", dynamic([r], r.inserted_at < ^cutoff))
  end

  defp do_prune(:usage_events, cutoff) do
    delete_where("usage_events", dynamic([r], r.inserted_at < ^cutoff))
  end

  # One row per HTTP attempt, so this grows with conversation volume times
  # endpoint count. 30 days is longer than any "why did my integration miss
  # that" investigation and short enough that the table stays a debugging
  # aid rather than a second event store (#700).
  defp do_prune(:webhook_deliveries, cutoff) do
    delete_where("webhook_deliveries", dynamic([r], r.inserted_at < ^cutoff))
  end

  # Terminal rows only. A `queued` or `starting` row is live work, and the
  # cutoff must never be what decides that.
  defp do_prune(:sandbox_requests, cutoff) do
    terminal = ~w(started failed cancelled expired)

    delete_where(
      "sandbox_requests",
      dynamic([r], r.inserted_at < ^cutoff and r.status in ^terminal)
    )
  end

  defp do_prune(:revoked_api_keys, cutoff) do
    # Revoked keys past the window, plus keys whose own expires_at is that
    # far in the past. A key that is neither revoked nor expiring is never
    # pruned no matter how old — deleting one would silently break whoever
    # is holding it. The expires_at leg exists because every hard kill
    # (SIGKILL on the pod, the provision watchdog) leaves an un-revoked
    # sprite callback key behind: inert at expiry (auth enforces
    # expires_at), but its row otherwise accumulated forever in the table
    # every authenticated request looks up against.
    delete_where(
      "api_keys",
      dynamic(
        [r],
        (not is_nil(r.revoked_at) and r.revoked_at < ^cutoff) or
          (not is_nil(r.expires_at) and r.expires_at < ^cutoff)
      )
    )
  end

  # Deletes in batches so a large backlog cannot hold a single long transaction
  # open against the primary.
  defp delete_where(table, condition, batch \\ 5_000, acc \\ 0) do
    ids =
      from(r in table, where: ^condition, select: r.id, limit: ^batch)
      |> Repo.all()

    case ids do
      [] ->
        acc

      ids ->
        {count, _} = from(r in table, where: r.id in ^ids) |> Repo.delete_all()

        if length(ids) < batch,
          do: acc + count,
          else: delete_where(table, condition, batch, acc + count)
    end
  end
end
