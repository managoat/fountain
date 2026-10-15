### Upgrade notes

- **A migration drops `environments.checkpoint_id`** (#2720, migration
  `20261015200000`). Take this release only after the release that removed
  environment checkpoints (#2720) is fully deployed: the release before it
  still selects the column with every environment it loads.
