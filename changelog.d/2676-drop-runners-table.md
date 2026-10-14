### Upgrade notes

- **A migration drops the `runners` table** (#2676, migration
  `20261014153200`). Upgrade to this release only after the release that
  removed the self-hosted runner provider (#2682) is fully rolled out:
  replicas of the release before it write that table on every daemon connect.
