# E2B

[E2B](https://e2b.dev) is one of the two
[sandbox providers](sandbox-contract.md). `E2B_API_KEY` turns it on, and
`SANDBOX_PROVIDER=e2b` makes it the default for a new sandbox. One agent can
also pin it with `sandbox_provider`. A sandbox that already exists always
stays on the provider Fountain made it on.

```bash
E2B_API_KEY=e2b_...          # enables the provider
E2B_TEMPLATE=fountain        # a template built from images/e2b/ (see below)
# E2B_BASE_URL=https://api.e2b.app
# SANDBOX_PROVIDER=e2b       # make it the instance default
```

## Summary

| | |
|---|---|
| Role | Sandbox provider. |
| Turned on by | `E2B_API_KEY` |
| Env vars | `E2B_API_KEY`, `E2B_TEMPLATE`, `E2B_BASE_URL` |
| Suspend | An explicit pause, with a snapshot of filesystem **and memory**. |
| Capabilities advertised | `:suspend`, `:network_policy`, `:attach` |
| Needs first | A template built from `images/e2b/`. The stock `base` has no agent CLIs. |

## Template

The stock `base` template carries no agent CLI. Build the reference template
once for each account.

```bash
E2B_API_KEY=... scripts/sandbox-image/build-e2b.sh
```

The script runs `e2b template create fountain` against `images/e2b/`. Then it
creates one sandbox from the new template. It checks the shape that the
provision pipeline assumes, then it destroys the sandbox. `E2B_TEMPLATE`
selects a different template name.

`e2b template create` takes the name and rebuilds that template in place. So
the template id that an instance points at stays the same. Sandboxes that
already run keep the copy that they started from.

CI runs the same script. The `Sandbox images` workflow rebuilds the template
when `images/e2b/` changes, once each week for the agent CLI versions, and on
request. It needs an `E2B_API_KEY` repository secret. That key must belong to
the account the instance uses. A template that another account builds is not
visible to the instance.

The image recreates the sandbox shape that the provision pipeline assumes. That is a
`sprite` user with passwordless sudo, `/home/sprite`, node, npm, bun, git and
the three agent CLIs. So no provision code exists for one provider alone.

## How the contract maps

| Fountain operation | E2B mechanics |
|---|---|
| Create or adopt by name | E2B assigns the ids. The minted name rides in sandbox `metadata`, and a lookup filters on it server-side. A create race leaves a duplicate, and the reaper converges it. |
| Suspend and resume | Real calls. `pause` snapshots filesystem and memory, keeps them without a time limit, and costs storage alone. `connect` restores. The idle bound truly parks. |
| TTL | Each E2B sandbox that runs has one. A live command heartbeats it. Fountain creates a sandbox with `autoPause: true`. A heartbeat that arrives late then pauses the sandbox and keeps its state, and does not kill it. An operation that finds the sandbox auto-paused resumes it first. |
| Exec and streams | envd, the daemon in the sandbox, over Connect-RPC with the JSON codec. That is plain HTTPS, and not gRPC. |
| Reattach after a deploy | envd does not replay the output of a process you reconnect to. So a detachable command runs under a shim that journals, with `tee` to `/tmp/fountain/<tag>.*`. A reattach replays the journal from byte zero through a `tail` streamer, and reads the real exit code from the shim's exit file. |
| Network policy | Native default-deny. `denyOut 0.0.0.0/0` plus the allowlist, and you can update it on a sandbox that runs. The provision-open-then-lock flow works unchanged. |
| Checkpoints | Not supported. E2B does not advertise `:checkpoint`. |

## Operational notes

- **Plans.** An agent turn can take more than one hour. E2B's Hobby tier caps
  continuous runtime at 1h, so you need Pro.
- **Reaper.** Reconciliation lists both `running` and `paused` sandboxes,
  filtered to metadata that Fountain stamped. It never touches another
  sandbox on the account.
- **Egress.** The callback host, `PUBLIC_URL`, must be reachable from inside
  the sandbox. A `limited` environment gets it through the same allowlist
  mechanics that Sprites uses.

## Verify

Create a conversation on an agent pinned to `e2b`, and watch it reach its
first turn. A run that stops short of that is a failure to provision, and the
stage events name the step.

## Related

- [About sandboxes](../concepts/sandboxes.md).
- [The sandbox contract](sandbox-contract.md).
- [Sandbox errors](../troubleshooting/sandbox-errors.md).
