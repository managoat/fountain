### Upgrade notes

- **`MACHINE_OWNER_ENABLED` is gone; every sandbox has its owner process** (#2344). A sandbox's destroy, park, wake, turn admission, attach and detach always run in the one process that owns that sandbox, so two operations on one sandbox queue behind each other instead of racing. A deployment that set the variable to `true` sees no change. A deployment that left it unset now runs the owner too. Remove the variable from your environment; Fountain no longer reads it.

### Changed

- **Abandoned resets and deletions are finished by one five-minute pass** (#2344). A sandbox whose reset or deletion was asked for and then abandoned holds its tenant's quota slot and keeps billing until it is finished. A reset the provider did not confirm is tried again on the next five-minute run, as before. A deletion whose caller died is finished on the first five-minute run after it is fifteen minutes old. Before this release, an abandoned deletion of an ephemeral sandbox waited for the hourly reaper, and could wait longer when that run's destroy budget was spent on expiries. The pass no longer shares the hourly budget.
- **The reaper's metrics for abandoned destroys moved** (#2344). `fountain_reaper_run_reconciled` is now `fountain_reaper_teardowns_reconciled`, and the new `fountain_reaper_teardowns_refused` counts the abandoned destroys a run could not finish. `fountain_reaper_run_refused` counts only the hourly run's expiries and idle parks.
- **An attach to a home that was reset and has since been deleted answers `sandbox_not_attachable`** (#2344), as an attach to any other deleted sandbox does. It answered `sandbox_reset_pending`, although the reset had finished. Both are 409.
