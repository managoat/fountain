---
type: ADR
title: "Sandboxes run on hosted providers only; the self-hosted runner is removed"
description: "Managoat provisions sandboxes on Sprites or E2B only; the self-hosted runner is removed."
tags: [sandbox, architecture, self-hosting, cli]
status: stable
adr: "0071"
adr_status: "Accepted"
date: 2026-10-14
---

# 0071 — Sandboxes run on hosted providers only; the self-hosted runner is removed

**Status:** Accepted, 2026-10-14. Built. Supersedes
[0022](0022-self-hosted-runner-provider.md) and
[0036](0036-firecracker-runner-backend.md). Dropping the `runners` table is a
separate migration, one release later.

## Context

[0022](0022-self-hosted-runner-provider.md) made a machine the user owns a
sandbox provider: a `fountain runner` daemon dialled out to the server and
served the sandbox contract over a WebSocket, so a sandbox was a directory on
that machine. [0036](0036-firecracker-runner-backend.md) gave the daemon a
microVM backend so a sandbox could be a Firecracker VM instead.

The provider cost more than it carried. It was the one adapter without a
network policy, so a brokered conversation could not run on it in production.
It needed its own reattach path in the conversation server: a bounded wait for
the daemon's socket to come back (`runner_reconnect`) and a replay of the
daemon's process journal to find the active turn (`RunnerReplay`). It needed
its own broker CA install in the sandbox's HOME, its own presence states
(`machine_offline`), its own error vocabulary (`no_runner_online`,
`runner_offline`, `sprite_name_not_supported`), a Horde registry for daemon
connections, a console page, an API, a Go daemon with two backends and a hex
library for the wire protocol.

In the 30 days before this decision, production had one registered runner,
the maintainer's own machine, and 26 sandboxes on it. No other account used
the provider.

## Decision

1. **Sprites and E2B are the providers.** `Fountain.SandboxProviders` knows
   `sprites` and `e2b`. `SANDBOX_PROVIDER` accepts those two, and boot refuses
   `runner`. `SANDBOX_RUNNERS_ENABLED` is no longer read.
2. **The runner is removed end to end.** Removed: `Fountain.Runners`, its
   Horde registry and host, `FountainWeb.RunnerController`,
   `GET /api/runners`, `DELETE /api/runners/:id`, `GET /api/runners/ws`, the
   `/account/runners` page, the `Runner` and `RunnerListResponse` schemas and
   the `runner` object on a sandbox response, the `managoat_runner` hex
   dependency, the broker CA install into HOME, and the `fountain runner` and
   `fountain runner-guest` commands with `cli/internal/runner` (the process
   and Firecracker backends). The `managoat_runner` library itself is not
   changed by this decision.
3. **The conversation server keeps one reattach path.** The runner's reconnect
   wait, journal replay, the permission timeout that failed a turn during a
   reconnect, and their state fields are removed. A transport error mid-turn
   fails the turn, as it already did on every other provider.
4. **Existing rows are retired by a migration, not by a boot sweep.**
   `20261014153100_retire_runner_rows` sets `sandbox_provider` to NULL (the
   instance default) on agents pinned to `runner`, and marks every
   non-terminal sandbox on `runner` `terminated`, ending when it was last
   written. Terminal rows keep `provider = 'runner'` as history.
   `Conversations.sandbox_provider_atom/1` reads an unknown provider as
   `:removed`, so the sweeps that walk terminal rows skip them. This is the
   shape the Daytona removal used (`20261012140000_retire_daytona_rows`).
   Nothing is destroyed on the runner's machine, because the server can no
   longer reach it. Its sandbox directories or VMs are the machine owner's to
   delete.
5. **The `runners` table stays for one release.** The previous release,
   serving during a rolling deploy, still reads it. A follow-up migration
   drops it once this release is the oldest one running.
6. **Parking stays.** [0017](0017-suspend-idle-sandboxes.md) is unchanged for
   Sprites and E2B.

## Consequences

- A user cannot bring their own machine. A Mac, a GPU box or a LAN-only
  resource is reachable only from a hosted sandbox's network.
- Every shipped provider advertises `:network_policy`. A brokered launch on an
  adapter without it is refused unconditionally
  ([0019](0019-egress-credential-brokerage.md)); `BROKER_ALLOW_UNENFORCED`,
  which once made that advisory, is removed (#2057). The agent form's warning
  for that pairing is removed, because no shipped provider can produce it.
- Usage reports still show `runner` hours from before the removal, outside
  the platform-paid total.
- A client that read `sandbox.runner`, the `machine_offline` presence state or
  the `runner_offline`, `no_runner_online` and `sprite_name_not_supported`
  errors gets none of them. The changelog entry is marked breaking.

## Alternatives considered

- **Keep the provider, unadvertised.** The reattach branches and the Go daemon
  would still need maintaining and testing for one machine.
- **A boot sweep instead of a migration.** A sweep runs on every boot and
  needs code that knows the removed provider for as long as it exists. The
  migration runs once and leaves nothing behind.
- **Let the reaper treat an unknown provider as gone.** The reaper would call
  `Managoat.Sandbox` for a provider with no adapter, which raises. It would
  also leave agents pinned to `runner` failing every launch.

## History

- 2026-10-14 — Runner provider removed and its rows retired by migration, under the simplification tracker #2676.
- 2026-10-14 — `BROKER_ALLOW_UNENFORCED` removed, so a brokered launch on an adapter without `:network_policy` is refused unconditionally (#2057).
