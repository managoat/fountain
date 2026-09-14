### Added

- `Fountain.Extension.connection_providers/0` (ADR 0054, #2152): an extension
  contributes config-backed connection providers, listed after the host's own
  platform providers, with their slugs reserved and the one OAuth client driving
  them. Boot validation refuses a malformed or colliding provider.
