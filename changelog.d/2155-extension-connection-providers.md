### Added

- `Fountain.Extension.connection_providers/0` (ADR 0054, #2152): an extension
  contributes config-backed connection providers, listed after the host's own
  platform providers, with their slugs reserved and the one OAuth client driving
  them. Boot validation refuses a malformed or colliding provider.

### Fixed

- Connections remain locally revocable and removable when their extension is
  unavailable; its tokens are omitted from new sandbox credentials. Config-backed
  MCP providers reject tenant-only rediscovery requests (#2155).
