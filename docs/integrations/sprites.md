# Sprites

[sprites.dev](https://sprites.dev) is the first of the four
[sandbox providers](sandbox-contract.md), and the instance default
(`SANDBOX_PROVIDER=sprites`). It is a hosted service. A Fountain instance
needs at least one provider credential. With none configured, each
conversation fails at provision time.

[The Sprites transport reference](sprites-contract.md) writes down the exact
API surface Fountain consumes. It also says what a compatible replacement
behind `SPRITES_BASE_URL` would have to provide.

## Summary

| | |
|---|---|
| Role | Sandbox provider, and the instance default. |
| Turned on by | `SPRITES_TOKEN` |
| Env vars | `SPRITES_TOKEN`, `SPRITES_BASE_URL`, `SPRITES_TIMEOUT_MS` |
| Suspend | Parks on its own. The sprite scales itself to zero and keeps its disk. |
| Capabilities advertised | `:suspend`, `:network_policy`, `:attach`, `:tty`, `:public_url`, and `:checkpoint`, which is off by default (#654). |
| Billed to | One platform token, so the operator and not the tenant. |

## The provider side

Create a sprites.dev account, then issue an API token. That token is the whole
setup on the provider side.

## Env vars

| Variable | Default | Effect |
|---|---|---|
| `SPRITES_TOKEN` | — | The platform token. Fountain does not check it at boot, so the app starts without it and the first conversation fails at provision time. |
| `SPRITES_BASE_URL` | `https://api.sprites.dev` | Repoints the Sprites API. Whatever you point it at must implement the same transport. [E2B](e2b.md) and [Daytona](daytona.md) are separate providers, and not replacements behind this variable. |
| `SPRITES_TIMEOUT_MS` | `30000` | Bounds each HTTP call to the Sprites API. A long command, such as a package install or a clone, sets its own timeout for that call. Boot refuses a value that is not positive. |

## The cost model

**One platform token pays for each Sprites sandbox.** Fountain provisions
every tenant's Sprites sandboxes with `SPRITES_TOKEN`, and the bill lands on
that token's account, which is yours. Two results follow.

- Each signup that can start a conversation can spend your money. Close
  registration, or restrict it, before you put an instance on the internet.
- Fountain caps concurrency for each user, at 20 by default
  (`SANDBOX_CAP_CEILING`). An admin can override it for one
  user from the admin panel, or with `POST /api/admin/users/:id/sandbox-limit`.
  A sandbox counts from the moment a provision starts, because that is
  the moment it starts to cost money.

Fountain never shows the token to a tenant, to the admin UI, or to a sandbox.
A sprite receives a scoped token that expires, and its only audience is your
Fountain instance's own API.

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
