---
type: ADR
title: "One platform credential per sandbox provider, bounded by a per-provider fleet ceiling"
description: "One platform credential per sandbox provider provisions every sandbox, its organization is dedicated to one Managoat instance, and SANDBOX_FLEET_CEILING_* per provider is the only concurrency bound."
tags: [sandbox, secrets, quotas]
status: stable
adr: "0005"
adr_status: "Accepted"
date: 2026-05-10
generated: { by: human:jhgaylor, at: 2026-08-03T13:41:32-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-03T13:41:32-04:00 }
---

# 0005 — One platform credential per sandbox provider, bounded by a per-provider fleet ceiling

**Status:** Accepted — 2026-05-10.

## Context

Managoat provisions sandboxes for every account on a deployment. Two models
were considered: each account supplies its own Sprites token (BYO), or the
deployment holds one platform-level token and provisions for everyone. When
this was decided, the goal was self-serve onboarding (sign up, start a
conversation, touch no infrastructure), which a required BYO token breaks.

Managoat is self-hosted only since 2026-10-12, so the accounts sharing a
deployment's provider bill are the operator's own. That removed the
noisy-neighbour risk the original per-tenant cap answered.

## Decision

- **One platform credential per provider.** `SPRITES_TOKEN` (and
  `E2B_API_KEY` for E2B) provisions every sandbox. It is read from the
  environment in `config/runtime.exs` (blank counts as unset) and handed to
  the `Managoat.Sandbox.Sprites` adapter's config, through which every
  Sprites call goes. It is never stored in the database, shown in a UI or
  exposed to an account. How a deployment delivers the env var is its
  operator's business; this repository ships only the image.
- **The provider organization belongs to one instance** (#1919). A Managoat
  instance owns the whole Sprites organization its `SPRITES_TOKEN` reaches,
  and the whole E2B team its `E2B_API_KEY` reaches. Sharing either with
  another application or a second Managoat instance is unsupported, and
  Managoat does not defend against a sandbox that belongs to someone else: no
  ownership labels are stamped at create or checked on adoption.
- **Naming.** Sandboxes are named `fountain-<tenant-prefix>-<suffix>`, where
  `<tenant-prefix>` comes from the owning user's UUID. Within one instance
  accounts are kept apart by those account-prefixed names (#1920) and the live
  `(provider, machine_name)` unique index (#2141).
- **No per-tenant cap.** `SANDBOX_FLEET_CEILING_<PROVIDER>` (default
  `SANDBOX_FLEET_CEILING`, itself default 20) alone bounds how many sandboxes
  the deployment runs on each provider, refusing past it with
  `503 fleet_full`. The check and the sandbox row insert run together under
  an advisory lock in `Fountain.Quotas`.
- **No meter.** The provider invoice is the cost authority
  ([0079](0079-usage-is-plain-counts.md)).

## Consequences

- Anything holding the token can list, exec into and destroy every sandbox in
  the organization, so a token compromise exposes all accounts' sandboxes. No
  label the holder could also write would be a boundary, which is the main
  reason for one organization per instance.
- A shared organization breaks Managoat's by-name operations:
  - Adoption. `Managoat.Sandbox.Sprites.create/2` treats a `409` as "an
    earlier attempt of mine made this" and returns a handle to the existing
    sprite; `Fountain.Machines.Provision` then writes the tenant's decrypted
    environment and vault values to its disk. A foreign sprite at that name
    would receive them. The E2B adapter likewise adopts any running or paused
    sandbox whose `fountain_name` metadata matches.
  - Destruction. The conversation's teardown, `Provision`'s discard of a
    machine an interrupted attempt left behind, and the reaper's pass over
    terminal rows whose sprite still exists all destroy by name without
    asking who made the sprite. The reaper's pass over sprites with no row
    only counts them.
  - A clash needs the other party to use a name this instance mints, so by
    accident it is mostly a second Managoat instance on the same
    organization. Even without a clash, the provider's concurrency limit is
    shared while the fleet ceiling counts only this instance's rows, and the
    reaper's untracked count includes the other party's sprites.
- The isolation boundary between sandboxes is the provider itself.
- BYO token remains possible without an architecture change (an optional
  per-user token preferred over the platform one); it is not built.

## Alternatives considered

- **BYO Sprites token per account** — rejected: a required setup step before
  first use. Self-hosting makes it moot, since the operator holds the token.
- **Per-account Sprites sub-accounts** — rejected: the Sprites API does not
  support them.
- **Ownership labels on each sprite** (a `sprites-ex` change) — rejected
  (#1919): the token holder could write the same labels, so they would not be
  a boundary.

## History

- 2026-05-10 — Decided: one platform `SPRITES_TOKEN`, per-tenant concurrency cap (default 5) as the noisy-neighbour mitigation, priced into tiers.
- 2026-08-02 — Token access centralized in one client; the cap check and row insert run under a per-user advisory lock (#330).
- 2026-08-03 — Render decommissioned; the token reached the app from the cluster's secret store.
- 2026-09-10 — A bounded wait queue placed in front of the cap ([0042](0042-bounded-sandbox-capacity-queue.md)).
- 2026-10-12 — Credits removed ([0031](0031-credits-are-the-product.md)); the cap became an operator override or `SANDBOX_CAP_CEILING`.
- 2026-10-13 — Self-hosted only: per-tenant cap and its queue removed; the fleet ceiling alone bounds the deployment.
- 2026-10-14 — Token read in `config/runtime.exs` and passed to the `Managoat.Sandbox.Sprites` adapter ([0037](0037-component-libraries.md)); the hosted overlay left the repository (#1115, [0032](0032-hosted-overlay-leaves-the-repo.md)).
- 2026-10-15 — Usage metering removed; the Sprites organization (and E2B team) belongs to one instance (#1919).
