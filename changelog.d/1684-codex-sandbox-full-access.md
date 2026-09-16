### Added

- The manual documents the sandbox codex builds for itself, and the one lever
  that widens it (#1684). The pinned `codex-acp` adapter sends a per-session
  policy of `workspaceWrite` with no writable roots and no network, which
  `~/.codex/config.toml` cannot widen. A first turn that writes outside its
  workspace and the temporary directories, or calls the network, is refused
  unless codex asks for access and the request is approved, by codex's own
  reviewer or by the agent's permission policy. Setting `INITIAL_AGENT_MODE` to
  `agent-full-access` in an environment's `env_vars` gives codex full access
  without asking.
  It is all or nothing, and it does not widen the environment's own network
  policy. It also sets codex's approval policy to `never`, so codex's own
  commands and file edits no longer reach the agent's permission policy, and
  `ask` or `auto_deny` no longer stops them. No behaviour changed. See
  [Run Codex as an API](https://managoat.com/docs/catalog/runtimes/codex#the-sandbox-codex-builds-for-itself).
