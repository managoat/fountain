### Upgrade notes

- **Session config options are set on the agent only** (#2739, ADR 0062).
  `session_config` on `POST /api/conversations` and on
  `POST /api/conversations/{id}/prompts` now returns
  `422 session_config_agent_only`; `null` and `{}` are still accepted. Set
  reasoning effort, fast mode and the runtime's other options on the agent,
  and start a new conversation to use them. A conversation's
  `session_config` in responses is now the agent's options it copied at
  launch, which every turn requests. Conversations that set options of their
  own at launch keep them: the upgrade folds them into that copy. The
  conversation's own `session_config` column is dropped in a later release.

### Removed

- A prompt's one-turn `session_config`, the restore of a prompt-only option
  on the next turn (`config_selection.restored` and the `restored` outcome
  of the `config` stage event), and `409 conversation_session_config_differs`
  on a channel resume (#2739).
- `fountain acp` no longer forwards `session/set_config_option` as each
  prompt's `session_config`. It acknowledges the method and applies nothing,
  with `_meta.fountain.applied: false` (#2739). See
  [ACP](https://managoat.com/docs/integrations/acp).
