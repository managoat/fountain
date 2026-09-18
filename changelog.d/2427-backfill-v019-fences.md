### Upgrade notes

- **Upgrading from v0.19.0: pending deletions are finished, and some pending
  resets are dropped** (#2427). v0.20.0 could not see a sandbox deletion or
  reset that was requested on v0.19.0 and had not finished before the
  upgrade. Such a machine looked live and kept billing. v0.20.1 finds these
  machines when it migrates:
  - A pending deletion is finished by the reaper within minutes.
  - A pending reset is finished the same way, unless the machine has run a
    turn since the reset was requested. The migration does not finish that
    reset, because it would wipe the work done since. The machine is left as
    its user last used it, and the migration logs its id at warning level.
    Operators have no reset of their own for it. If a reset is still wanted,
    tell the machine's owner, who can request one with
    `DELETE /api/sandboxes/:id`.

### Fixed

- A sandbox whose deletion was requested on v0.19.0 and had not finished
  before the upgrade is now deleted. The same goes for a pending reset on a
  machine that has not been used since the request (#2427).
