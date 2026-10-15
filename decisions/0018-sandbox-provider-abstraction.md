---
type: ADR
title: "Pluggable sandbox backends: the `Managoat.Sandbox` abstraction"
description: "Managoat.Sandbox is one behaviour, facade and error taxonomy, with Sprites and E2B as adapters and one platform credential per provider."
tags: [sandbox, architecture]
status: stable
adr: "0018"
adr_status: "Accepted"
date: 2026-08-14
generated: { by: human:jhgaylor, at: 2026-08-14T04:34:34-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-14T04:34:34-04:00 }
---

# 0018 — Pluggable sandbox backends: the `Managoat.Sandbox` abstraction

**Status:** Accepted, 2026-08-14. Built. The module is `Managoat.Sandbox`
since the sandbox library was folded back into `apps/fountain/lib/managoat/`.

Amends [0005](0005-platform-shared-sprites-token.md) (one platform credential
per provider), reaffirms [0017](0017-suspend-idle-sandboxes.md) with a
capability-degradation rule, and lifted the two-implementation cap in
[0016](0016-governance-as-an-acp-proxy.md).

## Context

Every conversation runs inside a sandbox, and the `sprites-ex` SDK was once
called directly from about fifteen modules. 0016 sketched the intended seam,
one sandbox behaviour with a conformance suite, but capped it at two
implementations and gated the second on a named customer. This decision built
the seam and proved it against two differently shaped hosted providers, E2B
and Daytona, chosen over Modal (gRPC-only control plane, no clean path from
Elixir) and raw Firecracker microVMs (a platform build, not an integration).
Proving the seam against more than one backend is what keeps it honest: E2B
exercises the no-native-name and TTL paths that Sprites does not.

The providers behind the seam today are Sprites and E2B
([0071](0071-hosted-sandbox-providers-only.md)).

## Decision

### One behaviour, one facade, one error taxonomy

`Managoat.Sandbox` is both the `@behaviour` adapters implement and the facade
call sites use; nothing outside the sandbox modules names a provider SDK or
its error shapes. Handles and commands are provider-tagged structs whose
`private` field is adapter-opaque and excluded from `inspect` (the Sprites
handle embeds the platform bearer token). Errors normalise into a closed
taxonomy (`:not_found`, `{:rate_limited, _}`, `{:unavailable, _}`,
`{:denied, _}`, `{:invalid, _}`, `{:provider, _, _}`) that the retry layer
classifies directly. The not-found/transient distinction is load-bearing on
the wake path, where only a definitive not-found may give up a parked disk.

The owner-message contract for streaming commands is normative:
`{:stdout | :stderr, %{ref: ref}, bin}`, exactly one terminal frame
(`{:exit, %{ref: ref}, code}` or `{:error, %{ref: ref}, reason}`), a
deliberate close without an exit frame reads as exit 0, and attach replays
buffered output from byte zero; the byte-skip arithmetic in reattach depends
on it. `Managoat.Sandbox.ConformanceCase` is the executable form of this;
`Managoat.Sandbox.Fake` (an in-memory adapter whose commands are real
processes) passes it in full and is the reference for adapter authors.

### Selection: instance default, per-agent override, sticky rows

`SANDBOX_PROVIDER` picks the default for new sandboxes. A provider is enabled
by the presence of its credential plus a registered adapter, and an explicitly
chosen default without credentials refuses to boot. `agents.sandbox_provider`
(nullable) overrides per agent, validated against enabled providers at save
time and re-checked at conversation start. The resolved provider is stamped
into `sandboxes.provider` when the row is minted and never re-resolved: a
parked sandbox wakes on the backend that holds its disk regardless of the
instance default, and a row whose provider lost its credentials refuses to
wake retryably rather than being retired, since retiring it would destroy the
agent's memory.

`sandboxes.machine_name` is the provider-scoped identity Managoat mints. It
is the same value on every provider, and no machine is renamed at its
provider. The API answers `machine_name` on sandboxes, conversations'
embedded sandbox and the admin sandbox list, and a launch accepts it; audit
events about a sandbox and the `reattach` stage event carry a
`"machine_name"` key. `sprite_name` remains a deprecated duplicate of the
same value in those responses (`deprecated: true` in the OpenAPI document),
in the event metadata and as a launch input; a launch with both names,
different, is `422 machine_name_conflict`. The duplicate and the
`invalid_sprite_name` error code go in the release that removes the
Fountain-name aliases ([#2776](https://github.com/managoat/managoat/issues/2776)).
Events written before the rename carry only `"sprite_name"` and are not
rewritten.

### Capability flags and the lifecycle degradation rule

`capabilities/0` answers operational questions, most importantly `:suspend`:
can an idle sandbox park with its disk preserved at negligible cost? Sprites
advertises it implicitly (scale-to-zero; its `suspend/1` is a no-op), E2B
with a real pause. A provider without it gets destroy-on-idle, priced exactly
like the max-lifetime ceiling. `idle_action/1` (in `Fountain.Machines.Policy`)
is the one place this decision lives.

Two failure policies, deliberately asymmetric:

- Suspend before the row flips; a failed suspend degrades to destroy. An
  unparked sandbox keeps billing, so cost control wins.
- Resume before the row flips; a failed resume leaves the row suspended and
  fails retryably. The parked disk is the agent's memory, so data protection
  wins.

0017's "suspended rows are never aged out" stands on every provider: E2B
retains paused snapshots indefinitely at storage-only cost.

### Per-provider reaping

The reaper's destroy and reconcile passes run per enabled provider with error
isolation: one backend's listing failure does not stop another's destroys,
rows on a provider whose listing failed (or whose credentials were pulled) are
skipped and logged rather than destroyed, and untracked counts carry a
provider tag. The provider is on the sandbox row and in audit metadata.

### The E2B adapter

E2B ids are server-assigned, so the minted name rides in sandbox metadata
(create adopts an existing name; the reaper converges race duplicates). Every
running sandbox has a TTL, so live commands heartbeat it and `autoPause: true`
turns a missed heartbeat into a pause rather than a kill; operations that find
the sandbox auto-paused resume it first. envd does not replay a reconnected
process's output, so detachable spawns run under a journaling shim (`tee` to
`/tmp/fountain/<tag>.*`) and attach replays through a `tail -c +1 -f`
streamer, with the real exit code read from a sentinel file.

E2B's egress control is default-deny (`denyOut 0.0.0.0/0` plus an
allowlist), so the intent-level `NetworkPolicy{allow: [...]}` needs a
fail-open translation only on Sprites, inside that adapter.

### Production's E2B image is loam's

Production's E2B endpoint is loam's E2B-compatible API
(`https://api.e2b.loam.inevitable.fyi`), not hosted e2b.app. Its `fountain`
template is an alias of loam's `e2b-fountain` template, built by loam from
its own `images/e2b-fountain/Containerfile`
([arugula-salad/loam](https://github.com/arugula-salad/loam)). loam serves no
template build routes, so Managoat cannot build that template. A change to the
agent CLIs or the guest shape production boots is a change to loam's image,
and loam rebuilds it only when its tree changes, so its CLIs age until
something there does.

`images/e2b/` and `scripts/sandbox-image/build-e2b.sh` are the reference
recipe for an instance on hosted E2B, recreating the `sprite`-user layout the
provisioning pipeline assumes, so no per-provider provisioning code exists.
The `Sandbox images` workflow builds that recipe on the runner and smokes
production's template on loam (start a sandbox, run `smoke.sh`, destroy it).
The live E2B suite runs against loam with a key of loam's `fountain-ci`
project. There is no documented way back to hosted E2B for production; an
operator who wants it builds the reference template on an account of their
own and points `E2B_BASE_URL`, `E2B_API_KEY` and `E2B_TEMPLATE` at it.

## Consequences

- Adding a provider is an adapter that passes the conformance suite, plus a
  credential; no call site changes.
- A provider's disk is tied to its rows: removing a provider means migrating
  agents pinned to it and terminating its live rows, as was done for Daytona
  and the self-hosted runner.
- The E2B adapter was proven live (create, adopt, exec, streaming spawn with
  stdin, attach with replay from byte zero, stdin EOF with real exit code,
  suspend, resume with the filesystem intact, destroy; deny-all egress
  blocking and an allowlist opening exactly the listed host) and needed no
  changes from the live run.

## Alternatives considered

- **Modal**: gRPC-only control plane, no clean path from Elixir.
- **Raw Firecracker microVMs**: a platform build, not an integration.
- **Keep 0016's two-implementation cap**: one alternative backend cannot show
  whether the seam is shaped by its first provider.

## History

- 2026-08-14 — Accepted and built (#676–#686): the behaviour, facade, error taxonomy, conformance suite and Fake; E2B and Daytona adapters; live smoke tests on both passed.
- 2026-10-12 — Daytona removed (simplify 2/5): pinned agents moved to the instance default, live Daytona rows marked terminated, `images/daytona/` deleted.
- 2026-10-14 — The self-hosted runner removed ([0071](0071-hosted-sandbox-providers-only.md), #2676).
- 2026-10-15 — Production's E2B template is loam's; CI builds the reference recipe and smokes loam's template; the hosted e2b.app template and rollback key deleted.
- 2026-10-15 — The usage event log removed ([0079](0079-usage-is-plain-counts.md)), so the `provider` key on usage events went with it.
- 2026-10-15 — `sprite_name` renamed to `machine_name` ([#2108](https://github.com/managoat/managoat/issues/2108)), a one-step column rename safe on one node with Recreate ([0072](0072-fountain-runs-as-one-node.md)); `sprite_name` kept as a deprecated duplicate.
