defmodule Fountain.Repo.Migrations.DropSandboxFenceColumns do
  use Ecto.Migration

  # ADR 0058 stage 9b-ii. `reset_requested_at` and `teardown_requested_at`
  # carried the intent to destroy a machine until stage 9a made the
  # `destroying` stamp carry it; stage 9b-i (#2423) stopped reading and writing
  # them and shipped a release before this one, so no replica that selects them
  # is still serving when this runs.
  #
  # Dropping them drops no standing intent, on any upgrade path. A row fenced
  # by 9a or later carries the `destroying` stamp beside the columns. A row
  # fenced only in the columns, which a v0.19.0 instance wrote because 9a first
  # shipped in v0.20.0, is stamped by v0.20.1's backfill (#2427),
  # `20260918190000_backfill_destroying_from_fence_columns`. Its version sorts
  # before this one, so on every database it runs first: on an upgrade to
  # v0.20.1 before this release, or in the same run as this migration on an
  # upgrade straight from v0.19.0. The one fence it leaves unstamped, a reset
  # on a machine used since the request, is one the user's later work
  # replaced. This migration discards it, as that backfill's comment says.
  def up do
    alter table(:sandboxes) do
      remove :reset_requested_at
      remove :teardown_requested_at
    end
  end

  # Back to empty, nullable columns. No release this could roll back to reads
  # them for anything but the fence, and an empty column is an unfenced row,
  # which is what every row the stamp does not fence is.
  def down do
    alter table(:sandboxes) do
      add :reset_requested_at, :utc_datetime_usec
      add :teardown_requested_at, :utc_datetime_usec
    end
  end
end
