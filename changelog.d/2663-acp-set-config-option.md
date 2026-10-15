### Fixed

- **`fountain acp` applies the session config options an editor sets**
  (#2663). `session/set_config_option` was acknowledged and ignored, so an
  effort or fast-mode picker looked like it worked and changed nothing. The
  option is now kept for the session and sent as `session_config` on every
  following prompt, until the editor changes it. Once a turn has run, the
  reply carries `configOptions` with the chosen values. `model` is still
  accepted and not applied. `mode` and `collaboration_mode` are refused, as
  the API refuses them. See
  [Session config options](https://managoat.com/docs/integrations/acp#session-config-options).
