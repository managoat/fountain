# Daytona

[Daytona](https://daytona.io) is one of the four
[sandbox providers](sandbox-contract.md), and of the three hosted ones it
matches the contract most closely.

`DAYTONA_API_KEY` turns it on. `SANDBOX_PROVIDER=daytona` makes it the default
for a new sandbox, and one agent can pin it with `sandbox_provider`. A sandbox
that already exists always stays on the provider Fountain made it on.

```bash
DAYTONA_API_KEY=dtn_...            # enables the provider
DAYTONA_SNAPSHOT=fountain          # a snapshot built from images/daytona/ (unset = org default image)
# DAYTONA_API_URL=https://app.daytona.io/api   # self-hosted Daytona
# SANDBOX_PROVIDER=daytona
```

## Summary

| | |
|---|---|
| Role | Sandbox provider, and the closest match to the contract. |
| Turned on by | `DAYTONA_API_KEY` |
| Env vars | `DAYTONA_API_KEY`, `DAYTONA_SNAPSHOT`, `DAYTONA_API_URL` |
| Suspend | An explicit stop. It keeps the disk, and archives a long park. |
| Capabilities advertised | `:suspend`, `:network_policy`, `:attach` |
| Self-hostable | Yes, through `DAYTONA_API_URL`. |
| Needs first | An organization on Tier 3 or higher, and a snapshot built from `images/daytona/`. The stock image has no agent CLIs. |

## Snapshot

The stock image carries no agent CLI. Build the reference snapshot once for
each organization.

```bash
DAYTONA_API_KEY=... scripts/sandbox-image/build-daytona.sh
```

The script sends the content of `images/daytona/Dockerfile` to the snapshot
API and waits for the build to reach `active`. Then it creates one sandbox
from the new snapshot. It checks the shape that the provision pipeline
assumes, then it destroys the sandbox. `DAYTONA_SNAPSHOT` selects a different
snapshot name.

A snapshot name is unique for each organization, and Daytona has no rename. So
a rebuild of the name that an instance points at is a delete and a create. In
the minutes between them, the organization has no snapshot of that name. A
conversation that starts on Daytona in that window cannot create its sandbox.
Sandboxes that already exist keep the copy that they started from.

CI runs the same script. The `Sandbox images` workflow rebuilds the snapshot
when `images/daytona/` changes, once each week for the agent CLI versions, and
on request. It first builds the same Dockerfile with `docker build` on the
runner. That gate catches an upstream break before the delete opens the window
above. The workflow needs a `DAYTONA_API_KEY` repository secret. That key must
belong to the account the instance uses. A snapshot that another organization
builds is not visible to the instance.

## How the contract maps

| Fountain operation | Daytona mechanics |
|---|---|
| Create or adopt by name | Native. A sandbox is addressable by name in the API paths. A create that conflicts adopts the sandbox when the get that follows succeeds. |
| Suspend and resume | `stop` keeps the whole disk, and `start` resumes it. A sandbox that stays parked archives itself to object storage on its own. It still starts, more slowly, and it takes no more disk quota. |
| TTL | None. Fountain creates a sandbox with `ttlMinutes: 0` and `autoStopInterval: 0`, and Fountain's own lifecycle owns the suspend. Nothing heartbeats. |
| Exec | A one-shot toolbox `process/execute`, with cwd, env and timeout. |
| Streams and reattach | A daemon-side session journals the output on the server. The log websocket **replays from byte zero before it follows**, so a reattach is the same stream opened again. The daemon publishes no exit code, and its follow stream is unreliable at both ends. So the adapter's shim writes an exit sentinel, and the stream reconnects with a byte-exact skip. |
| Stdin | The daemon FIFO sends EOF after each write. So a command that consumes stdin reads from a file that `tail -f` feeds. A write appends through a one-shot exec, and `close_stdin` kills the tail for a real EOF. |
| Network policy | `networkBlockAll` and `domainAllowList`, for each sandbox, and you can update them on a sandbox that runs. It is truly default-deny, so `allow: []` needs no translation. |
| Checkpoints | Not supported. Daytona does not advertise `:checkpoint`. |

## Operational notes

- **The size of the domain allowlist.** Daytona caps `domainAllowList` at
  about 20 entries. The API rejects a `limited` environment with a longer
  allowlist.
- **Org tiers.** Daytona needs Tier 3 or higher. Fountain sets the network
  policy of every sandbox it provisions, and Daytona refuses that on Tier 1 and
  Tier 2: the API answers 400 "Network access is restricted and cannot be
  overridden at the sandbox level". So every conversation on a lower tier fails
  at the `network` stage, a few seconds after it starts. See
  [Daytona's network limits](https://www.daytona.io/docs/en/network-limits/).
- **Reaper.** Reconciliation lists the sandboxes Fountain labelled, and no
  others. It never touches another sandbox in the organization.

## Verify

Create a conversation on an agent pinned to `daytona`, and watch it reach its
first turn. A run that stops short of that is a failure to provision, and the
stage events name the step.

## Related

- [About sandboxes](../concepts/sandboxes.md).
- [The sandbox contract](sandbox-contract.md).
- [Sandbox errors](../troubleshooting/sandbox-errors.md).
