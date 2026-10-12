### Upgrade notes

- **A migration drops the last billing and principal columns** (#2611).
  Migration `20261012140000` drops the `credit_ledger` table and the `users`
  columns `credit_balance_cents`, `stripe_customer_id`, `comped` and
  `principal`, which the previous two removals left in place, unread, for one
  release. Take the release that removed credits (#2609) and let it finish
  rolling out first: a rolling deploy straight from an older release would
  fail its old replicas' requests until they are replaced. See
  [Billing and principal columns dropped](https://managoat.com/docs/guides/operate/upgrade#billing-and-principal-columns-dropped).
- **`PROVIDER_HOURLY_CENTS` is no longer read** (#2611). Nothing used it
  since the finance page was removed. Remove it from your configuration.
