### Removed

- **A parked sandbox's files are no longer read from a park snapshot**
  (#PR, ADR 0063 retired). A park no longer snapshots the git work trees, and
  `GET /api/sandboxes/:id/files`, `/file`, `/diff` and `/git-status` answer a
  suspended sandbox with `409 sandbox_not_ready` again, as ADR 0039 defines;
  the machine is still never woken for a read. `snapshot_at` is gone from the
  four responses, `SANDBOX_SNAPSHOTS_ENABLED` is no longer read, and the
  `fountain.sandbox_snapshot.stop.duration` metric is no longer reported. The
  `sandbox_snapshots` table stays for one release, unused; a later migration
  drops it.
