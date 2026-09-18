### Upgrade notes

- Swift SDK releases are independent of server releases starting at 0.20.0. Use
  SwiftPM `revision: "sdk-swift-v0.20.0"` or its commit SHA to select an independent
  release. Existing version-range installs continue to select server snapshots;
  version-based library dependencies cannot transitively use revision-based
  packages (#1414).

### Changed

- New SDK release tags use `sdk-typescript-v`, `sdk-python-v`, `sdk-elixir-v` and
  `sdk-swift-v`. Existing tags remain valid. The root SDK catalog now records
  ownership, runtime support, independent versions and shared conformance coverage;
  CI checks it against the packages and release hooks (#1414).
