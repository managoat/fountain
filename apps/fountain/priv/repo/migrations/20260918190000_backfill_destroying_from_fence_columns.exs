defmodule Fountain.Repo.Migrations.BackfillDestroyingFromFenceColumns do
  use Ecto.Migration

  require Logger

  # Carries every fence v0.19.0 wrote onto the `destroying` stamp v0.20.x reads
  # (ADR 0058, stage 9b-i). v0.19.0 fences in two columns only: a reset sets
  # `reset_requested_at`, a forced teardown sets it and `teardown_requested_at`.
  # v0.20.0 reads neither. Its `Sandbox` schema does not declare them, and every
  # reader refuses on the stamp alone. So a fence that was abandoned or in
  # flight when a self-hoster upgraded from v0.19.0 is a machine v0.20.0 thinks
  # is live: it keeps billing, it holds a quota slot, and a user can be attached
  # to a machine they asked to reset. This stamps those rows, so the reaper's
  # teardown run finishes what was asked for.
  #
  # The version is load-bearing. It is after `20260918050000`, the last
  # migration v0.20.0 ships, and before `20260918200000`, which drops the two
  # columns. On any database, fresh or upgraded, this reads the columns before
  # they go.
  #
  # Raw SQL, because the schema no longer declares the columns this reads.
  #
  # **Teardown is tested first.** A v0.19.0 teardown writes both columns
  # (`reset_requested_at || now` and `teardown_requested_at`), so testing
  # `reset_requested_at` first would label every teardown a reset. The two
  # labels are finished differently: the teardown run retries a `"reset"` at
  # once through `Conversations.retry_pending_sandbox_reset/2`, and finishes
  # anything else through the machine's owner. Both words are in
  # `Machines.Destroy`'s vocabulary.
  #
  # **A reset the reset door would refuse is labelled a teardown.** That door
  # acts on a persistent row that is `ready` or `suspended`, and answers
  # `:skipped` for anything else, on every run. A row labelled `"reset"` in any
  # other shape would carry the stamp for ever, and `release_stuck_sandboxes/0`
  # skips stamped rows, so nothing would finish it. v0.19.0 could only fence a
  # reset on that shape, and nothing moves such a row out of it except to a
  # terminal status, so this branch should match nothing. It is here so that a
  # row which does reach it is destroyed instead of orphaned.
  #
  # **Non-terminal rows only.** v0.19.0 never clears either column: a completed
  # reset writes `terminated` and keeps `reset_requested_at` by design. A
  # terminal row with a column set is a finished request and needs nothing.
  #
  # **Rows already stamped `destroying` are left alone.** A fence written on
  # v0.20.x carries its own stamp and its own reason, which is more exact than
  # anything the columns say.
  #
  # **Another transition is overwritten.** `parking`, `resuming` and
  # `provisioning` did not exist in v0.19.0, and neither did the lease, so a
  # v0.19.0 fence reaches this with `transition` null and no lease. A row that
  # has one was touched on v0.20.x, which could not see the fence. Stamping it
  # is what a v0.20.x fence does: `Destroy.stamp_intent!/2` writes `destroying`
  # over any transition and takes no lease. The protocol is built for a stamp
  # that lands mid-operation. `Lease.cas_update/4` keeps `destroying` through a
  # live owner's non-terminal write, and a provision's finalize refuses a
  # stamped row. With no live owner, the other transition is an abandoned
  # operation that a later reader would clear, and the fence would be lost.
  #
  # **No lease is written.** A `destroying` stamp with no live lease is the
  # shape the teardown run picks up. A row whose lease is still live is skipped
  # until the lease lapses, then finished.
  #
  # **`updated_at` is not touched.** The teardown run's 15-minute grace window
  # is measured from `updated_at`, which on a stamped row is normally the
  # stamp. Here the request is older than the stamp, and its caller did not
  # survive the upgrade, so there is nothing to wait for. A fence written more
  # than 15 minutes before this runs is finished on the first run. A newer one
  # waits out the rest of its window. A reset has no window.
  #
  # Nothing is audited here. The destroy writes `sandbox.destroyed`, and the
  # teardown run writes `sandbox.teardown_reconciled` or `sandbox.reset`.
  def up do
    %{num_rows: count} =
      repo().query!("""
      UPDATE sandboxes
         SET transition = 'destroying',
             transition_reason = CASE
               WHEN teardown_requested_at IS NOT NULL THEN 'teardown'
               WHEN mode = 'persistent' AND status IN ('ready', 'suspended') THEN 'reset'
               ELSE 'teardown'
             END
       WHERE (reset_requested_at IS NOT NULL OR teardown_requested_at IS NOT NULL)
         AND status NOT IN ('terminated', 'failed')
         AND transition IS DISTINCT FROM 'destroying'
      """)

    if count > 0 do
      Logger.warning(
        "migration: stamped #{count} sandbox(es) fenced by v0.19.0 as destroying; " <>
          "the reaper's teardown run will finish them"
      )
    end
  end

  # Nothing to undo. The columns still exist at this version, so nothing was
  # lost, and the stamps are the requests the columns recorded. Clearing them
  # would make those machines look live again.
  def down, do: :ok
end
