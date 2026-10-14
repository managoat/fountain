### Upgrade notes

- **A migration drops the turn-deadline tables** (#2637). Migration
  `20261013170000` drops `turn_executions`, `execution_allowances`,
  `turns.limit_reason` and `users.execution_limits`, which the release
  removing the turn-deadline journal (#2636) left in place, unread, for one
  release. Take it only once that release is fully rolled out: a rolling
  deploy straight from an older release would fail its old replicas'
  launches until they are replaced.
