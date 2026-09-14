### Changed

- **The Slack connection provider ships as the `fountain_slack` extension**
  (ADR 0054, #2152). The bundled image carries it exactly as before: the
  `slack` slug, endpoints, user scopes, `user_scope` request, `authed_user`
  token shape, env key and the `slack (connection)` manual page are unchanged,
  and `SLACK_OAUTH_CLIENT_ID` / `_SECRET` / `SLACK_OAUTH_USER_SCOPES` still
  configure it, read by the extension now under `config :fountain_slack`. A
  core distribution (`BUNDLE_EXTENSIONS=false`) no longer lists a Slack row,
  those variables are inert on it, and an existing Slack connection there
  stays revocable and deletable while contributing no token.
