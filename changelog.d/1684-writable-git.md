### Fixed

- **Codex can branch and commit in the environment's repositories** (#1684).
  The earlier change made each clone writable, but codex keeps `.git`
  read-only inside every writable root, so `git worktree add`, a new branch
  and a commit still failed. Fountain now sends each clone's `.git` as a
  writable root of its own.
