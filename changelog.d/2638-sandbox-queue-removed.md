### Upgrade notes

- **The sandbox-capacity queue and the per-account sandbox cap are removed.**
  `SANDBOX_FLEET_CEILING` (default 20) is the one capacity limit left. These
  variables are no longer read; remove them from your configuration:
  `SANDBOX_CAP_CEILING`, `SANDBOX_QUEUE_MAX_DEPTH` and
  `SANDBOX_QUEUE_MAX_WAIT_SECONDS`. Requests still waiting in the queue when
  you upgrade are not started.
- **The `sandbox_requests` table and the `users.max_concurrent_sandboxes`
  column stay for one release, unread**, so replicas still running the
  previous release keep working during a rolling deploy; a later release
  drops them.

### Changed

- **A start or wake past the fleet ceiling is refused with `503 fleet_full`**
  and `Retry-After: 60`, never queued. A teammate schedule's cron firing that
  meets a full fleet retries on its own for up to 30 minutes after the
  firing, as it does for a busy teammate, instead of waiting in the queue.

### Removed

- **The sandbox queue**: `queue: true` and the `202` response on
  `POST /api/conversations`, `GET /api/sandbox-queue`,
  `GET /api/sandbox-queue/{id}`, `DELETE /api/sandbox-queue/{id}`, the
  `SandboxRequest` schemas, the `sandbox_request.*` audit events, the
  five-minute drainer job and the `fountain.sandbox_queue.*` metrics.
- **The per-account sandbox cap**: `429 sandbox_quota_exceeded`,
  `POST /api/admin/users/{id}/sandbox-limit`, the admin users page's limit
  control, and `max_concurrent_sandboxes` and `sandbox_limit_override` on the
  admin user object. The admin pages still show each account's active
  sandboxes.
- **`QuotaExceededError`** from the TypeScript SDK (unreleased; it ships with
  the next major).
