### Upgrade notes

- **`MACHINE_OWNER_ENABLED` is gone; every sandbox has its owner process** (#2344). A sandbox's destroy, park, wake, turn admission, attach and detach always run in the one process that owns that sandbox, so two operations on one sandbox queue behind each other instead of racing. A deployment that set the variable to `true` sees no change. A deployment that left it unset now runs the owner too. Remove the variable from your environment; Fountain no longer reads it.

### Changed

- **A deletion or reset that was asked for and then abandoned is finished within five minutes** (#2344). This covers a reset the provider never confirmed, and a teardown whose caller died partway. Such a sandbox holds its tenant's quota slot and keeps billing until it is finished. An abandoned teardown of an ephemeral sandbox used to wait for the hourly reaper, and could wait longer when that run's destroy budget was spent on expiries. One five-minute pass of the reaper now finishes both kinds, and it no longer shares the hourly budget.
- **The reaper's metrics for abandoned destroys moved** (#2344). `fountain_reaper_run_reconciled` is now `fountain_reaper_teardowns_reconciled`, and the new `fountain_reaper_teardowns_refused` counts the abandoned destroys a run could not finish. `fountain_reaper_run_refused` counts only the hourly run's expiries and idle parks.
- **An attach to a home that was reset and has since been deleted answers `sandbox_not_attachable`** (#2344), as an attach to any other deleted sandbox does. It answered `sandbox_reset_pending`, although the reset had finished. Both are 409.
