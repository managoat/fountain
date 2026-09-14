### Changed

- **The Microsoft connection provider ships as the `fountain_microsoft`
  extension** (ADR 0054, #2152). The bundled image carries it exactly as
  before: the `microsoft` slug, endpoints, scopes, env key and the
  `microsoft (connection)` manual page are unchanged, and `MICROSOFT_OAUTH_CLIENT_ID`
  / `_SECRET` / `_SCOPES` still configure it — read by the extension now, under
  `config :fountain_microsoft`. A core distribution (`BUNDLE_EXTENSIONS=false`)
  no longer lists a Microsoft row, and those variables are inert on it.
