### Changed

- **The Gmail MCP server is the `fountain_google` extension** (ADR 0043,
  #2152, #1529). `POST /api/mcp/gmail/:conversation_id/:connection_id`, its
  seven tools and the `fountain-gmail` manual page are unchanged on the
  standard distribution, served by `apps/fountain_google` through the
  extension seam rather than by core. A core distribution
  (`BUNDLE_EXTENSIONS=false`) serves none of them. Core no longer rewrites a
  connection-only `mcp_servers` entry (`{"gmail": {"connection": "<id>"}}`)
  into that server: the entry is now an extension's to serve at each turn, so
  it reaches every runtime through `session/new` and is never written to a
  sandbox's `.mcp.json`. An entry with a URL beside the connection is still
  core's remote-server shape. The test-only `:gmail_req_options` key moved to
  `config :fountain_google, :req_options`. The published OpenAPI document is
  byte-identical: the route was never an operation.
