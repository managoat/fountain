### Upgrade notes

- **A migration drops the `sandbox_snapshots` table** (#2657, migration
  `20261014130000`). Upgrade to this release only after the release that
  removed park snapshots (#2656) is fully rolled out: replicas of the release
  before it write that table on every park.
