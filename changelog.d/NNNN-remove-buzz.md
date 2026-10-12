### Upgrade notes

- **The Buzz extension is removed** (#NNNN). Hosted Buzz agents stop when the
  release rolls out: `/api/buzz/agents` and `/api/mcp/buzz/:conversation_id`
  answer `404`, and a migration drops `buzz_identities` and deletes pending
  harness-sweep jobs. The vaults that held each identity's Nostr key are
  untouched; delete them if you no longer need them. `BUZZ_IDENTITY_CEILING`,
  `BUZZ_ACP_BASE_URL`, `BUZZ_ACP_PATH` and `FOUNTAIN_CLI_PATH` are no longer
  read.

### Removed

- The Buzz extension (`apps/fountain_buzz`), its `buzz-backend-fountain`
  provider binary, the `fountain buzz agents` CLI commands and the Buzz manual
  pages (#NNNN). Releases no longer attach `buzz-backend-fountain-*`, and the
  server image no longer bakes `buzz-acp`, `buzz` or the `fountain` CLI.
