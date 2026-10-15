---
type: ADR
title: "Render Sandboxes as a fourth hosted provider, and identity without names"
description: "Retired 2026-10-13, never built. Was: Render as a fourth sandbox backend."
tags: [sandbox, architecture, providers]
status: deprecated
adr: "0040"
adr_status: "Retired"
date: 2026-09-03
generated: { by: claude-opus/5, at: 2026-09-03T03:10:00-04:00 }
stale_after: 2026-12-03
---

# 0040 — Render Sandboxes as a fourth hosted provider, and identity without names

**Status:** Retired 2026-10-13, never built. Fountain runs Sprites, E2B and
the self-hosted runner, and no Render adapter or wiring was ever written; the
text below is history. Was: Accepted, 2026-09-03, with nothing built. The
decision rested on a live measurement of the early-access API
([#1434](https://github.com/BinaryBourbon/fountain/issues/1434)), not on an
adapter. The adapter is [#1436](https://github.com/BinaryBourbon/fountain/issues/1436),
the Fountain wiring [#1437](https://github.com/BinaryBourbon/fountain/issues/1437),
and the tracker [#1441](https://github.com/BinaryBourbon/fountain/issues/1441).
Remove this paragraph and set `verified` when the ladder in
[#1439](https://github.com/BinaryBourbon/fountain/issues/1439) is green.

Extends [0018](0018-sandbox-provider-abstraction.md) with a fourth hosted
backend and one change to the behaviour it defined. Interacts with
[0023](0023-persistent-agent-sandbox.md) (an agent's memory is its disk) and
[0019](0019-egress-credential-brokerage.md) (the broker needs egress).

## Context

Render opened early access to Sandboxes on 2026-09-02. We measured the API
against the ten requirements in
[what we need from a platform](https://github.com/BinaryBourbon/fountain/blob/main/docs/integrations/platform-requirements.md)
on 2026-09-03, driving the HTTP API directly because no adapter exists.

The measurement is worth reading in full on #1434, but four results decide
this ADR:

1. **The runtime is the best of the five we have measured.** Create to
   `running` in 1.6s. Output streams incrementally with sub-100ms latency and
   correct stdout/stderr tagging. True exit codes on both the buffered and the
   streaming path. `deny-all` egress genuinely blocks DNS, TLS and raw IPs
   rather than failing open. A spawned process survives the disconnection of
   the client that started it.
2. **There is no caller-supplied identity, and no metadata field either.**
   `sandboxPOST` is exactly `{ownerId, plan, timeoutSeconds, region,
   networkPolicy, env}`. Ids are server-assigned `sbx-…`. The sandbox object
   returned by `GET` and by the listing carries no `env`, so a name smuggled
   through `env` at creation cannot be read back on any path that does not
   execute a command inside the sandbox. E2B has no names either, but it has
   metadata, which is what its adapter emulates names with. Render has
   neither.
3. **There is no park.** No pause, no stop, no resume. `timeoutSeconds` ends
   in a destruction, and a termination removes filesystem state. The status
   enum already contains `suspended` and `resuming`, so parking looks planned,
   but nothing today can produce those states.
4. **Cloudflare rejects some command payloads at the edge.** `<any command> ;
   <curl|wget>` on one line is blocked with Cloudflare's own error page, as is
   the literal string `/etc/passwd`, `/etc/hosts` or `/etc/shadow` anywhere in
   the body. The 403 carries none of the `render-request-id` or `ratelimit-*`
   headers that every response reaching Render's application carries, so the
   request never arrives. Newline-separated scripts pass.

The absent pieces are the same ones every backend has been missing, and we
already ship the shims for them. The identity gap is the one that has no
precedent, because it reaches the behaviour rather than an adapter.

## Decision

### Render ships, and declares what it cannot do

Render becomes the fourth hosted provider behind `Managoat.Sandbox`, built in
`managoat/managoat_sandbox` beside its three siblings ([0037](0037-component-libraries.md)).
It advertises `:attach` (emulated, as E2B's is) and nothing else. It does
**not** advertise `:suspend`, `:network_policy`, `:public_url`, `:checkpoint`
or `:tty`.

0018's degradation rule then does the rest without a special case:
`Lifecycle.idle_action/1` reads `:suspend` and returns `:destroy`, and the
idle sweep destroys instead of parking.

### The seam gains a provider ref beside the Fountain-minted name

This is the substantive change to 0018.

`Managoat.Sandbox` is name-keyed: Fountain mints `fountain-<prefix>-<hex>`,
`create/2` adopts an existing name, `build_handle/1` reconstructs a handle
from a name with no network call, and `list_all_names/0` gives the reaper the
account view it reconciles against. On Render, three of those four are
unimplementable, because nothing on any read path can tell us a sandbox's
Fountain name.

The decision is to **give a handle a provider ref: the identity the provider
itself addresses a sandbox by**, and to persist it as `sandboxes.provider_ref`
beside `sandboxes.provider`.

- Fountain still mints `sprite_name`. It stays the tenant-facing identity, it
  stays public API surface, and no user-visible behaviour changes. 0018's
  reason for keeping that name keeps applying.
- An adapter whose platform accepts caller-supplied names (Sprites, Daytona,
  the runner) reports `ref == name`. Every existing call path behaves exactly
  as it does today.
- An adapter whose platform assigns identity (Render, and E2B if its metadata
  emulation is ever retired) reports the platform's own id.
- `create/2` returns a handle carrying both. Fountain writes `provider_ref` at
  the two mint sites, beside `provider`, and **never re-resolves it**, on the
  same reasoning 0018 gave for the provider column: the row has to keep
  addressing the sandbox that holds its disk.
- `build_handle/1` becomes `build_handle/2`, taking the name and the ref, with
  the ref `nil` for name-addressed providers.
- `list_all_names/0` becomes `list_all_refs/0`. The reaper reconciles the
  provider's refs against `provider_ref`, and falls back to `sprite_name` for
  rows minted before the column existed.

The conformance suite gains a case for a server-assigned-identity adapter, so
the shape is pinned rather than described.

### Idempotent creation is given up on Render, and the reaper covers it

Name-adopting creation is what makes a create idempotent under retry. Without
it, a create whose response we lose leaves a sandbox we pay for and cannot
address.

We accept that, rather than emulate it. The emulation E2B uses needs a
metadata field to filter on, and Render has none; the alternative, executing a
command inside every listed sandbox to read a name from its environment, costs
a round trip per sandbox per sweep and fails exactly when the sandbox is
unhealthy.

The orphan is already covered: it is a sandbox the provider lists and our
database does not, which is precisely what the reaper's untracked sweep
destroys. The cost of the gap is therefore bounded by the sweep interval, not
unbounded. **This is the first backend where the untracked sweep is
load-bearing rather than a backstop**, and #1436 should treat a listing
failure on Render with the standing-down behaviour 0018 already specifies.

### A Render agent has no memory between conversations

Under 0023 the sandbox filesystem is the agent's memory, and the next turn
resumes on that disk. With no park, an idle Render sandbox is destroyed, so
the next conversation starts on a fresh disk.

We ship that rather than hide it. It has to be visible in three places: this
ADR, `docs/integrations/render.md`, and the `Lifecycle.explain/2` copy a user
reads when their sandbox goes idle, whose destroy arm already refuses to
promise memory. An operator choosing Render is choosing a fast, cheap,
forgetful backend, and that is a reasonable choice for a large class of work.

### Egress translates fail-open, and `limited` refuses

`networkPolicy` is exactly `{default: "allow-all" | "deny-all"}`. The deny is
real and total, which is better than Sprites. There is no allowlist, and
`deny-all` also blocks the broker (0019), so a conversation that needs
brokered credentials cannot run under it.

`NetworkPolicy{allow: [...]}` therefore translates to `allow-all` and fails
open, as it does on Sprites, and the integration page has to say so. A
`limited` network environment refuses to provision on Render, the way a
Daytona organisation without the egress entitlement does.

### The TTL is a destruction, so our ceiling sits below it

`timeoutSeconds` destroys the sandbox. If our own max-lifetime sweep runs
after it, the sandbox disappears with no lifecycle event and the conversation
breaks with no explanation.

The adapter sets `timeoutSeconds` from the deployment's configured maximum
lifetime plus a margin, and `SANDBOX_MAX_LIFETIME_HOURS` must resolve below
the value sent. #1437 owns the check.

### Every command is base64-wrapped

The adapter sends `echo <base64> | base64 -d | bash` for every command, always,
rather than reactively after a rejection. Verified against every payload the
edge rejected.

Two supporting rules. The command is **not** sent in the token-mint body,
which is optional and only feeds Render's dashboard timeline, so the text
crosses the control plane once rather than twice. And `errors.ex` classifies a
403 whose body is HTML as its own error rather than `{:denied, _}`: a
credential failure is permanent and must not be retried, while an edge
rejection is neither the operator's fault nor a reason to stop.

We report the rejection to Render rather than treat the wrapping as the end of
it. A product whose request body is by definition a shell command the customer
intends to run cannot keep a rule that matches shell injection, and a
workaround that defeats the inspection entirely is evidence for that, not
against it.

### Ship on the stock image

Render has no custom images. Its stock image is Debian 12 with node 24, npm,
git, python3 and the coreutils the shims need already present, and installing
the agent CLI, the ACP adapter and bun on top took 11.7s. Cold start is
therefore about 13s from nothing to a provisioned sandbox.

That is cheap enough to ship on, so Render does not wait for custom images.
`images/render/` becomes an optimisation for whenever they land, not a
prerequisite ([#1438](https://github.com/BinaryBourbon/fountain/issues/1438)).
Commands run as `root` with a writable npm prefix, so the exit-243 trap the
provider recipe warns about does not apply, and there is no `sprite` user to
select.

## Consequences

- **The behaviour changes for every adapter**, even though only two need it.
  `build_handle/2`, `list_all_refs/0` and the ref on a handle land in
  `managoat_sandbox` 0.2.0, and Fountain pins it in the same campaign.
  Name-addressed adapters are a one-line change each.
- **A migration adds `sandboxes.provider_ref`**, nullable, with the reaper
  falling back to `sprite_name` where it is null. No backfill: existing rows
  are all on name-addressed providers or on E2B's metadata emulation.
- **Render cannot host an agent whose value is continuity.** The provider
  select has to be an informed choice, not a default. `SANDBOX_PROVIDER`
  should not become `render` on the hosted deployment while 0023 agents are
  the product.
- **`attach/3` needs the shim on Render** even though the platform keeps the
  process alive, because the exit code is client-reported and the output is
  not retained. If `GET /sandboxes/{id}/logs` ships as specified, most of that
  shim is deletable, and #1436 should keep it separable for that reason.
- **The untracked sweep becomes a correctness dependency**, not a backstop.

## Alternatives considered

- **Wait for Render to add metadata or a name.** Correct in the long run and
  requested, but it blocks a backend that is otherwise the fastest we have
  measured, on a vendor timeline we do not control. The ref is useful anyway:
  E2B's metadata emulation exists only because the seam had nowhere to put a
  server-assigned id.
- **Keep `list_all_names/0` and read the name from inside each sandbox.** One
  exec per sandbox per reaper sweep, against a rate-limited API, and it fails
  for exactly the unhealthy sandboxes the sweep exists to find.
- **Store the id in `sandboxes` and let the Render adapter reach for it.** It
  makes the reaper's reconcile provider-shaped, which is the coupling 0018
  removed. The ref keeps the branch inside the adapter.
- **Refuse Render until it can park.** Rejected. 0018's capability set exists
  so that backends can differ, and a fast forgetful sandbox is a legitimate
  shape. Hiding it behind a fake park is what the rule forbids; declining to
  ship it is not what the rule requires.
- **Detect the edge rejection and retry unwrapped.** A rejection costs a round
  trip and is silent about which rule fired. Wrapping every command costs
  about thirty bytes and is deterministic.

## Verification status

Nothing in this ADR is implemented. The measurements it rests on were taken on
2026-09-03 against the early-access API, workspace `tea-d6h5vsc50q8c73adag70`,
with two sandboxes created and terminated; the full matrix, including the
payloads the edge rejected, is on #1434. No claim here has been checked
through an adapter, and the platform-requirements page marks the Render column
as the one measured without one.
