### Upgrade notes

- **The unused turn-deadline journal is removed** (#1732, ADR 0046).
  `FOUNTAIN_EXECUTION_LIMITS`, `FOUNTAIN_EXECUTION_DEADLINE_WORKER` and
  `FOUNTAIN_EXECUTION_DEADLINE_INTERVAL_MS` are no longer read, and the
  `notifications` Oban queue is gone. Conversations no longer write an
  execution allowance or a `conversation.execution_allowance_created` audit
  event. The `turn_executions` and `execution_allowances` tables and the
  `turns.limit_reason` and `users.execution_limits` columns stay, unread, until
  a later release drops them.

### Removed

- The `limit_reason` field on turns, which no turn ever set, and the
  `execution_limits_invalid`, `execution_limits_widen`,
  `execution_limits_unsupported` and `execution_fenced` errors. A launch
  request's `execution_limits` field is no longer read (#1732).
