### Upgrade notes

- **The `sandbox_requests` table and the `users.max_concurrent_sandboxes`
  column are dropped** (migration `20261013180000`), with any pending
  sandbox-queue drainer jobs. Upgrade to this release only after the release
  that removed the sandbox queue and the per-account cap is fully rolled
  out: that one stopped reading them, and the release before it still does.
