defmodule Fountain.Repo.Migrations.BackfillDestroyingFromFenceColumns do
  use Ecto.Migration

  require Logger

  # Carries the fences v0.19.0 wrote onto the `destroying` stamp v0.20.x reads
  # (ADR 0058, stage 9b-i). v0.19.0 fences in two columns only: a reset sets
  # `reset_requested_at`, a forced teardown sets it and `teardown_requested_at`.
  # v0.20.0 reads neither. Its `Sandbox` schema does not declare them, and every
  # reader refuses on the stamp alone. So a fence that was abandoned or in
  # flight when a self-hoster upgraded from v0.19.0 is a machine v0.20.0 thinks
  # is live: it keeps billing, and it holds a quota slot. This stamps those
  # rows, so the reaper's teardown run finishes what was asked for, except a
  # reset on a machine that has been used since (below).
  #
  # The version is load-bearing. It is after `20260918050000`, the last
  # migration v0.20.0 ships, and before `20260918200000`, which drops the two
  # columns. On any database, fresh or upgraded, this reads the columns before
  # they go.
  #
  # Raw SQL, because the schema no longer declares the columns this reads.
  #
  # **A reset on a machine used since the request is skipped.** v0.20.0 could
  # not see the fence, so the user could go back to the machine, run turns and
  # build new state on it. Finishing the old reset would wipe that work, and
  # interrupt a turn still running: the reset door checks only the lease, with
  # no running-turn check and no grace, because a stamp written on v0.20.x
  # blocks admission from the moment it lands. A backfilled stamp lands after
  # v0.20.0 has admitted work. The user's later work is taken as replacing the
  # request. The row is left unstamped and live, and its id is logged so an
  # operator can tell the owner, who can reset it again from the console or
  # the API. The migration that drops the columns then discards the request.
  #
  # "Used" means a turn **inserted** at or after `reset_requested_at`, on a
  # conversation whose `sandbox_id` is this row. That is the one binding both
  # versions write: a turn belongs to a conversation, and a conversation names
  # its machine in `sandbox_id`. Ending or releasing a conversation keeps
  # `sandbox_id`. The one write that moves it, the wake's co-tenant move, moves
  # it onto a replacement machine after the old one is gone. v0.19.0's reset
  # refuses a machine with a turn running, so a turn inserted after the fence
  # came from v0.20.0. `turns.inserted_at` is stored to the second, hence the
  # truncation. A turn in the same second as the fence counts as used, which
  # is the safe side.
  #
  # A conversation **bound** since the request with no turn yet does not
  # count. Attaching to an existing machine runs nothing on it, so there is no
  # work to lose. Once the stamp lands, admission refuses a first turn, and the
  # reset tells the conversation through its server, as any reset does.
  #
  # **The skip is decided by intent, not by label**, so it sits in the `WHERE`
  # and not in the CASE. Intent is a reset when `teardown_requested_at` is
  # null. The odd-shape branch below turns some resets into teardowns, and for
  # a machine used since, a destroy is worse than a wipe.
  #
  # **Teardowns are never skipped.** They come from account deletion,
  # termination and home destroys, and they must finish. The teardown run
  # already waits for a live server to go before it destroys.
  #
  # **Teardown is tested first in the CASE.** A v0.19.0 teardown writes both
  # columns (`reset_requested_at || now` and `teardown_requested_at`), so testing
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
  # skips stamped rows, so nothing would finish it. Nothing v0.19.0 wrote
  # reaches this branch: its reset fences only that shape, and refuses every
  # later non-terminal write. A row v0.20.0 touched can, because v0.20.0 wrote
  # to it without seeing the fence. Such a row is destroyed instead of
  # orphaned, unless it has been used since (above).
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
          "because the machine has run turns since. Reset it again from the console " <>
          "or the API if it is still wanted."
      )
    end
  end

  # Nothing to undo. The columns still exist at this version, so nothing was
  # lost, and the stamps are the requests the columns recorded. Clearing them
  # would make those machines look live again.
  def down, do: :ok
end
