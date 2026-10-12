### Upgrade notes

- **A migration drops the webhook and connection tables** (#2618). Migration
  `20261012200000` drops `webhook_endpoints`, `webhook_deliveries`,
  `connections` and `connection_providers`, which the releases removing
  webhooks and Connections left in place, unread, for one release. Take it
  only once the release that removed them is fully rolled out: a rolling
  deploy straight from an older release would fail its old replicas' turns
  until they are replaced. Stored webhook secrets and connection tokens are
  deleted with the tables.
