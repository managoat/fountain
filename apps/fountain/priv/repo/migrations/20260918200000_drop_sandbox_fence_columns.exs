defmodule Fountain.Repo.Migrations.DropSandboxFenceColumns do
  use Ecto.Migration

  require Logger

  # ADR 0058 stage 9b-ii. `reset_requested_at` and `teardown_requested_at`
  # carried the intent to destroy a machine until stage 9a made the
  # `destroying` stamp carry it. Stage 9b-i (#2423) stopped reading and
  # writing them, and shipped in v0.20.0.
  #
  # **Every column-only fence is stamped before the columns go, however the
  # upgrade is rolled, except a reset on a machine used since the request,
  # which is neither stamped nor kept, and is logged by id.** A row fenced by 9a or later carries the `destroying`
  # stamp beside the columns. A row fenced only in the columns was written by
  # v0.19.0, where 9a had not shipped. v0.20.1's backfill (#2427),
  # `20260918190000_backfill_destroying_from_fence_columns`, stamps those rows,
  # but it runs when the first v0.20.1 replica migrates. On a rolling upgrade a
  # v0.19.0 replica still serving after that can write a new column-only
  # fence, and if its caller then dies, nothing on v0.20.x can see it. So this
  # migration runs the backfill again, immediately before the drop, inside the
  # same transaction. What either run stamps, the reaper's teardown run
  # finishes.
  #
  # **That reset is the one request discarded.** Both runs skip it on
  # purpose, for the reasons in #2427's comment: finishing it would wipe the
  # work done since. It is left as its
  # user last used it, and logged by id. Only its owner can reset it again,
  # with `DELETE /api/sandboxes/:id`. A row the backfill already skipped is
  # logged again here, because this is where its request is discarded.
  #
  # **The backfill's SQL is copied, not called.** Its module is not guaranteed
  # to be loaded when this version runs on a database that applied it long
  # ago, and a migration must stay what it was when it ran. `@fenced`,
  # `@used_since_reset` and `restamp_column_only_fences/0` below are the SQL
  # and logs of #2427's `up/0`, unchanged; see that file for why each clause
  # is what it is. Both statements run before the `alter`, which Ecto executes
  # when `up/0` returns.
  #
  # **A rolling upgrade still needs v0.20.0 or later on every replica before
  # this runs**, because an older replica selects both columns and fails every
  # sandbox query once they are gone. A stop-the-world upgrade can come from
  # any version.

  @fenced """
  (reset_requested_at IS NOT NULL OR teardown_requested_at IS NOT NULL)
  AND status NOT IN ('terminated', 'failed')
  AND transition IS DISTINCT FROM 'destroying'
  """

  @used_since_reset """
  teardown_requested_at IS NULL
  AND EXISTS (
    SELECT 1
      FROM turns t
      JOIN conversations c ON c.id = t.conversation_id
     WHERE c.sandbox_id = sandboxes.id
       AND t.inserted_at >= date_trunc('second', sandboxes.reset_requested_at)
  )
  """

  # The worker v0.19.0 enqueued, as Oban stores it. v0.20.x kept a no-op shim
  # under this name to drain its jobs, and this release deletes the shim. A
  # stop-the-world upgrade straight from v0.19.0 can bring queued jobs for it
  # that no module can run. Oban would fail each one as an unknown worker
  # until it was discarded, and a discard fires `FountainObanJobsDiscarded`.
  # Every job it ran is now the reaper's teardown run, so deleting the queued
  # ones loses nothing.
  @reconciler_worker "Fountain.Workers.SandboxResetReconciler"

  def up do
    restamp_column_only_fences()
    delete_reconciler_jobs()

    alter table(:sandboxes) do
      remove :reset_requested_at
      remove :teardown_requested_at
    end
  end

  # Back to empty, nullable columns. No release this could roll back to reads
  # them for anything but the fence, and an empty column is an unfenced row,
  # which is what every row the stamp does not fence is. The stamps and the
  # deleted jobs stay as they are.
  def down do
    alter table(:sandboxes) do
      add :reset_requested_at, :utc_datetime_usec
      add :teardown_requested_at, :utc_datetime_usec
    end
  end

  defp delete_reconciler_jobs do
    %{num_rows: count} =
      repo().query!(
        """
        DELETE FROM oban_jobs
         WHERE worker = $1
           AND state IN ('available', 'scheduled', 'retryable')
        """,
        [@reconciler_worker]
      )

    if count > 0 do
      Logger.warning(
        "migration: deleted #{count} queued #{@reconciler_worker} job(s); " <>
          "the reaper's teardown run does their work"
      )
    end
  end

  # Copied from 20260918190000_backfill_destroying_from_fence_columns.exs
  # (#2427), `up/0`. Keep it identical.
  defp restamp_column_only_fences do
    repo().query!("""
    SELECT id FROM sandboxes
     WHERE #{@fenced}
     ORDER BY id
       FOR UPDATE
    """)

    %{num_rows: count} =
      repo().query!("""
      UPDATE sandboxes
         SET transition = 'destroying',
             transition_reason = CASE
               WHEN teardown_requested_at IS NOT NULL THEN 'teardown'
               WHEN mode = 'persistent' AND status IN ('ready', 'suspended') THEN 'reset'
               ELSE 'teardown'
             END
       WHERE #{@fenced}
         AND NOT (#{@used_since_reset})
      """)

    if count > 0 do
      Logger.warning(
        "migration: stamped #{count} sandbox(es) fenced by v0.19.0 as destroying; " <>
          "the reaper's teardown run will finish them"
      )
    end

    # What the update left: every fenced row still unstamped is a reset on a
    # machine used since the request. Read after the write, so the log names
    # exactly the rows it skipped.
    #
    # id::text, because a raw query hands back the 16-byte UUID.
    %{rows: skipped} =
      repo().query!("""
      SELECT id::text, user_id::text, provider, sprite_name, reset_requested_at
        FROM sandboxes
       WHERE #{@fenced}
       ORDER BY reset_requested_at, id
      """)

    for [id, user_id, provider, name, requested_at] <- skipped do
      Logger.warning(
        "migration: left sandbox #{id} (#{provider}/#{name}, user #{user_id}) live: " <>
          "its reset requested on v0.19.0 at #{requested_at} UTC was not finished, " <>
          "because the machine has run turns since. It is left as its user last used " <>
          "it. If a reset is still wanted, only the owner can request one, with " <>
          "DELETE /api/sandboxes/:id; tell them."
      )
    end
  end
end
