### Changed

- **Codex can write to the environment's repositories** (#1684). Fountain now
  sends each repository's `mount_path` to the runtime adapter as an ACP
  `additionalDirectories` entry. Codex adds these to its sandbox's writable
  roots, so an agent can commit to a clone Fountain made, and cut a worktree
  from it, without `INITIAL_AGENT_MODE=agent-full-access`. Claude receives the
  same directories. Network access in codex's sandbox is unchanged. This needs
  `managoat_acp` 0.4.4.
