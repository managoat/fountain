### Added

- **Reasoning effort and fast mode, and any other ACP session config option**
  (#2537, ADR 0062).
  - Set `session_config`, a map of the runtime's option id to a value, on an
    agent, on a conversation (at creation or with a reapply), or on a prompt
    for that turn only. For example `{"effort": "high", "fast": true}` on
    claude, or `{"reasoning_effort": "high"}` on codex.
  - Fountain applies the options after the model and before every prompt.
    An option the current model doesn't offer is skipped. A value the runtime
    refuses fails the turn with the runtime's message.
  - Each turn records what was requested, applied and skipped under
    `config_selection`, and emits `config` stage events.
  - The conversation's `session_config_options` lists what the runtime
    offers.
  - See
    [Set reasoning effort and fast mode](https://managoat.com/docs/api#set-reasoning-effort-and-fast-mode).
