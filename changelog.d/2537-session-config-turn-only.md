### Fixed

- A `session_config` option sent on one prompt now holds for that turn only
  (#2537). An option that neither the conversation nor the agent names goes
  back to the runtime's earlier value on the next turn, instead of staying
  set until the runtime process restarts. The turn records it under
  `config_selection.restored`, and the stream emits a `config` stage event
  with outcome `restored`. Fountain takes managoat_acp 0.6.0 for this.

### Changed

- A conversation's `session_config_options` no longer lists the runtime's
  permission mode options, `mode` and `collaboration_mode` (#2537), which
  `session_config` refuses.
