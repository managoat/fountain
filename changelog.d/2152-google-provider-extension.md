### Changed

- **The Google connection provider ships in the `fountain_google` extension**,
  beside the Gmail MCP server (ADR 0054, #2152). The bundled image carries it
  exactly as before: the `google` slug, endpoints, scopes, offline-consent
  parameters, env key and the `google (connection)` manual page are unchanged,
  and `GOOGLE_OAUTH_CLIENT_ID` / `_SECRET` / `_SCOPES` still configure it, read
  by the extension now under `config :fountain_google`. Core builds no platform
  provider of its own any more: a core distribution (`BUNDLE_EXTENSIONS=false`)
  lists none, those variables are inert on it, and an existing Google
  connection there stays revocable and deletable while contributing no token.
