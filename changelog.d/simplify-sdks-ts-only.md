### Removed

- **TypeScript is the one maintained SDK** (#PR). The Python, Elixir and Swift
  SDKs are removed from the repository with their CI jobs, release gates,
  publishers and manual pages. Their published releases stay where they are,
  unmaintained and untested against new servers: `fountain-agent-sdk` on PyPI,
  `fountain_sdk` on Hex, and the `sdk-swift-v*` tags (and the historical `v*`
  tags) that SwiftPM resolves. Move to `@managoat/fountain-sdk`, the `fountain`
  CLI, or the HTTP API. See https://managoat.com/docs/sdk#other-languages.
