### Added

- The manual documents the sandbox codex builds for itself, and the one lever
  that widens it (#1684). The pinned `codex-acp` adapter sends a per-session
  policy of `workspaceWrite` with no writable roots and no network, which
  `~/.codex/config.toml` cannot widen, so a first turn that writes outside its
  workspace or calls the network fails. Setting `INITIAL_AGENT_MODE` to
  `agent-full-access` in an environment's `env_vars` gives codex full access;
  it is all or nothing, it is not a permission policy, and it does not widen
  the environment's own network policy. No behaviour changed. See
  [Run Codex as an API](https://managoat.com/docs/catalog/runtimes/codex#the-sandbox-codex-builds-for-itself).
