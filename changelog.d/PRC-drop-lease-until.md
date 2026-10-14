### Upgrade notes

- **A migration drops `sandboxes.lease_until`** (#PRC, migration
  `20261014180000`). Take this release only after the release that stopped
  writing it (#2685) is fully deployed: that release still selects the column
  with every sandbox it loads.
