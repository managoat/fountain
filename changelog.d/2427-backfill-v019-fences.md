### Upgrade notes

- **Upgrading from v0.19.0: pending deletions and resets are finished**
  (#2427). v0.20.0 could not see a sandbox deletion or reset that was
  requested on v0.19.0 and had not finished before the upgrade. Such a
  machine looked live and kept billing. v0.20.1 finds these machines when
  it migrates, and the reaper finishes the deletions and resets within
  minutes. No operator action is needed.

### Fixed

- A sandbox whose deletion or reset was requested on v0.19.0 and had not
  finished before the upgrade is now deleted or reset, as it was asked to be
  (#2427).
