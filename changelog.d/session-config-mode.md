### Security

- `session_config` refuses the runtime's permission mode (#PRNUM): `mode` on
  claude and codex and `collaboration_mode` on codex return
  `422 session_config_invalid` on agents, conversations, reapply and prompts.
  A prompt's `{"mode": "bypassPermissions"}` or `agent-full-access` could stop
  the runtime from asking permission, around the agent's `permission_policy`.
  An agent or conversation that already stored one keeps running, and
  Fountain no longer sends the option. A reapply that omits `session_config`
  saves the map without it.

### Fixed

- The manual no longer says a prompt's `session_config` always ends with its
  turn (#PRNUM). While the runtime process stays up, an option that only the
  prompt named keeps the prompt's value on later turns. Set the option on the
  conversation or the agent to get the same value on every turn. See
  [Set reasoning effort and fast mode](https://managoat.com/docs/api#set-reasoning-effort-and-fast-mode).
