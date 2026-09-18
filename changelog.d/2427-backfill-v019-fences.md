### Upgrade notes

- **Upgrading from v0.19.0: pending deletions are finished, and some pending
  resets are dropped** (#2427). v0.20.0 could not see a sandbox deletion or
  reset that was requested on v0.19.0 and had not finished before the
  upgrade. Such a machine looked live and kept billing. v0.20.1 finds these
  machines when it migrates:
  - A pending deletion is finished by the reaper within minutes.
  - A pending reset is finished the same way, unless the machine has run a
    turn since the reset was requested. The migration does not finish that
    reset, because it would wipe the work done since. The machine stays live,
    and the migration logs its id at warning level. If a reset is still
    wanted, reset the machine again from the console or the API.

### Fixed

- A sandbox whose deletion was requested on v0.19.0 and had not finished
  before the upgrade is now deleted. The same goes for a pending reset on a
  machine that has not been used since the request (#2427).
