### Upgrade notes

- **Connections are removed** (#2617). `/api/connections`,
  `/api/connection-providers`, the `/connections/:provider/start` and
  `/callback` round trip and the **Connections** page answer `404`, and the
  Google, Microsoft and Slack extensions are gone, with the Gmail MCP server at
  `/api/mcp/gmail`. Fountain stops reading `GOOGLE_OAUTH_CLIENT_ID`,
  `GOOGLE_OAUTH_CLIENT_SECRET`, `GOOGLE_OAUTH_SCOPES`,
  `MICROSOFT_OAUTH_CLIENT_ID`, `MICROSOFT_OAUTH_CLIENT_SECRET`,
  `MICROSOFT_OAUTH_SCOPES`, `SLACK_OAUTH_CLIENT_ID`,
  `SLACK_OAUTH_CLIENT_SECRET` and `SLACK_OAUTH_USER_SCOPES`; remove them. The
  `connections` feature flag is gone, so `FEATURE_FLAGS_ON=connections` does
  nothing. A migration removes every `mcp_servers` entry that names a
  connection from your agents, and an agent can no longer be saved with one.
  Give a remote MCP server its bearer from a vault secret through `${VAR}`
  instead, bound to the server's host where the broker runs. Fountain does
  not revoke the stored grants at Google, Microsoft, Slack or your own OAuth
  apps; revoke them at the provider if you want them gone. The
  `connections` and `connection_providers` tables stay for one more release,
  unread, and a later migration drops them.

### Changed

- **Credential bindings need only the broker** (#2617). The bindings page and
  `/api/secret-bindings` are open to every account on a deployment that runs
  the egress broker; the `connections` flag that also gated creating one is
  gone. `GET /api/auth/me` no longer reports `connections_enabled` or
  `connections_manageable`; read `brokered`.

### Removed

- Connections, connection providers and the verified remote MCP server list
  (#2617): `GET /api/catalog` no longer carries `mcp_servers`, and the
  connection guides and the per-server catalog pages left the manual.
