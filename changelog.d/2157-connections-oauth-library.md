### Changed

- The OAuth 2.0 authorization-code client behind Connections lives in the
  `managoat_mcp_auth` library as `Managoat.McpAuth.Client` (0.2.0), so the
  library is the whole client side of MCP authorization.
  `Fountain.Connections.OAuth` is the adapter that maps a
  `Fountain.Connections.Provider` onto the library's config; no wire or
  behaviour change (#2152).
