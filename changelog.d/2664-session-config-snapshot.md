### Changed

- **An agent's `session_config` edit reaches new conversations only** (#2664).
  A conversation now copies its agent's session config options (reasoning
  effort, fast mode and the like) when it is created, as it fixes its model,
  instead of reading the agent on every turn. Edit the agent and start a new
  conversation to use the new options, or send them on a prompt's
  `session_config` for one turn. Conversations that exist at upgrade keep
  the agent's options as they are at that moment, so their next turn does
  not change.
