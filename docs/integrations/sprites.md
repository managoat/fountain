# Sprites

[sprites.dev](https://sprites.dev) is the first of the two
[sandbox providers](sandbox-contract.md), and the instance default
(`SANDBOX_PROVIDER=sprites`). It is a hosted service. A Managoat instance
needs at least one provider credential. With none configured, each
conversation fails at provision time.

[The Sprites transport reference](sprites-contract.md) writes down the exact
API surface Managoat consumes. It also says what a compatible replacement
behind `SPRITES_BASE_URL` would have to provide.

## Summary

| | |
|---|---|
| Role | Sandbox provider, and the instance default. |
| Turned on by | `SPRITES_TOKEN` |
| Env vars | `SPRITES_TOKEN`, `SPRITES_BASE_URL`, `SPRITES_TIMEOUT_MS` |
| Suspend | Parks on its own. The sprite scales itself to zero and keeps its disk. |
| Capabilities advertised | `:suspend`, `:network_policy`, `:attach`, `:tty` and `:public_url`. |
| Billed to | One platform token, so the operator and not the tenant. |

## The provider side

Create a sprites.dev organization for this instance, then issue an API
token. That token is the whole setup on the provider side.

### One organization per instance

The Sprites organization behind `SPRITES_TOKEN` belongs to one Managoat
instance. Do not share it, or the token, with another application or a
second Managoat instance. That setup is unsupported, and Managoat does not
defend against it ([ADR 0005](https://github.com/managoat/managoat/blob/main/decisions/0005-platform-shared-sprites-token.md)).

Managoat assumes that each sprite at a name it minted is its own:

- **It adopts by name.** A create that gets a `409` uses the sprite already
  there, because that is how a retry after a lost response looks. The
  provision then writes the tenant's environment and vault values to that
  sprite's disk.
- **It destroys by name.** A conversation's teardown, a provision that
  discards an interrupted attempt, and the hourly reaper's sweep of finished
  sandboxes all destroy the sprite at the name the row holds. None of them
  checks who made it.

A sprite whose name Managoat never minted is never destroyed. The reaper
counts such sprites and leaves them alone. So the damage needs a name clash,
which in practice means a second instance on the same organization. The
token is the larger reason: whatever holds it can list, run commands in and
destroy every sprite in the organization, including each tenant's machine.
A shared organization also shares its concurrent-sprite limit, which
`SANDBOX_FLEET_CEILING_SPRITES` does not see.

## Env vars

| Variable | Default | Effect |
|---|---|---|
| `SPRITES_TOKEN` | — | The platform token. Managoat does not check it at boot, so the app starts without it and the first conversation fails at provision time. |
| `SPRITES_BASE_URL` | `https://api.sprites.dev` | Repoints the Sprites API. Whatever you point it at must implement the same transport. [E2B](e2b.md) is a separate provider, and not a replacement behind this variable. |
| `SPRITES_TIMEOUT_MS` | `30000` | Bounds each HTTP call to the Sprites API. A long command, such as a package install or a clone, sets its own timeout for that call. Boot refuses a value that is not positive. |

## The cost model

**One platform token pays for each Sprites sandbox.** Managoat provisions
every tenant's Sprites sandboxes with `SPRITES_TOKEN`, and the bill lands on
that token's account, which is yours. Two results follow.

- Each signup that can start a conversation can spend your money. Close
  registration, or restrict it, before you put an instance on the internet.
- Managoat caps live sprites across every account, at 20 by default
  (`SANDBOX_FLEET_CEILING_SPRITES`, falling back to `SANDBOX_FLEET_CEILING`;
  the $20 Sprites plan's limit); a start past it gets `503 fleet_full`.
  Sandboxes on other providers do not count against it. There is no per-account cap. A sandbox counts from
  the moment a provision starts, because that is the moment it starts to
  cost money.

Managoat never shows the token to a tenant, to the admin UI, or to a sandbox.
A sprite receives a scoped token that expires, and its only audience is your
Managoat instance's own API.

## Verify

Start a conversation. Progress streams as stage events. A token that is bad or
absent shows up as a failure at the `provision` stage, in the conversation's
log view.

A Sprites outage affects nothing else. Sign-in, dashboards and configuration
all still work, and the health endpoints deliberately ask Sprites no
question.

## Related

- [About sandboxes](../concepts/sandboxes.md), for what a provider is.
- [The sandbox contract](sandbox-contract.md), and the
  [Sprites transport reference](sprites-contract.md) for the wire protocol.
- [Sandbox errors](../troubleshooting/sandbox-errors.md).
