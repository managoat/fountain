### Added

- **A parked sandbox's files can be read without waking it** (#2552, ADR 0063). A
  park now snapshots the git work trees under the agent's working directory,
  and `GET /api/sandboxes/:id/files`, `/file`, `/diff` and `/git-status`
  answer a suspended sandbox from that snapshot, with `snapshot_at` giving
  when it was taken. Reads the snapshot does not cover (ignored files, files
  over 256 KiB, diffs against a ref) still return `409 sandbox_not_ready`.
  `SANDBOX_SNAPSHOTS_ENABLED=false` turns the snapshot off.
