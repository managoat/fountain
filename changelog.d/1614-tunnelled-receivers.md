### Added

- **The integration profiles run without hosting anything** (#1614, #1615,
  #1616). `secrets`, `mcp` and `webhooks` assert on what a deployment does
  outbound — a secret delivered into a sandbox, an MCP server called, a webhook
  posted — so each needs a receiver the deployment and its sandbox provider can
  reach. A run now hosts one locally and publishes it over Cloudflare quick
  tunnels for its duration, so
  `node deployed/verify.mjs https://your-instance.example.com --profile secrets`
  needs no public host, no DNS record and no account. `--receiver-url` still
  takes an already-hosted receiver. A tunnel that never becomes reachable fails
  setup with its own diagnostic, so a borrowed origin cannot be mistaken for a
  failed assertion about the deployment.
