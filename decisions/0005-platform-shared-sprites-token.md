---
type: ADR
title: "Platform-shared SPRITES_TOKEN; per-tenant concurrency cap as noisy-neighbor mitigation"
description: "One platform-level Sprites credential provisions every tenant sandbox; a per-tenant concurrent-sandbox cap is the noisy-neighbor mitigation. Amended by 0018 to one credential per provider. Since 2026-10-13 there is no per-tenant cap: only the deployment-wide SANDBOX_FLEET_CEILING bounds concurrency. Amended 2026-10-15 by 0079: no usage meter; the provider invoice is the cost authority. Amended 2026-10-15: the Sprites organization (and an E2B team) is dedicated to one Managoat instance; Managoat does not defend against another application's sandboxes."
tags: [sandbox, secrets, quotas]
status: stable
adr: "0005"
adr_status: "Accepted"
date: 2026-05-10
generated: { by: human:jhgaylor, at: 2026-08-03T13:41:32-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-03T13:41:32-04:00 }
---

# 0005 — Platform-shared SPRITES_TOKEN; per-tenant concurrency cap as noisy-neighbor mitigation

**Status:** Accepted — 2026-05-10.

## Context

Fountain must provision Sprites sandboxes for all tenants. Two models were considered: each tenant supplies their own Sprites token (BYO), or Fountain holds one platform-level token and manages provisioning for everyone.

The success metric (100 WAU by month 6) and the Option B onboarding goal (users arrive, sign up, start a conversation without touching infrastructure) make BYO-token friction-incompatible with launch.

## Decision

Fountain holds a single **platform-level `SPRITES_TOKEN`** that is used to provision all tenant sandboxes:

- `SPRITES_TOKEN` is an env-var-only secret on Render. It is never stored in the DB, never surfaced in the admin UI, and never visible to tenants.
- Each `ConversationServer` reads it from `Application.fetch_env!(:fountain, :sprites_token)` at provisioning time.
- Sprites sandbox naming: `fountain-<tenant-prefix>-<short-id>` (replacing `aod-conv-<short-id>` from aod-ex). `<tenant-prefix>` is the first 8 chars of the owning user's UUID; `<short-id>` is the first 8 chars of a fresh UUID.
- **Per-tenant concurrency cap** (`users.max_concurrent_sandboxes`, default `5`) is the primary noisy-neighbor mitigation. The cap is enforced in `Fountain.Quotas.check_sandbox_quota!/1` before `Sprites.create/2` is called.
- The cap is admin-adjustable per user (raise for trusted tenants, lower during abuse).
- Fountain pays the Sprites bill and prices its own tiers to recover the cost.

## Consequences

- A single token compromise exposes all tenants’ sandbox provisioning capacity. Mitigations: (1) env-var only, (2) Render environment-level access control, (3) anomaly alerting on Sprites API volume, (4) documented token rotation runbook.
- Fountain must engage Sprites to understand and proactively raise account-level rate limits as WAU grows.
- BYO-token is a viable post-launch power-user feature if the demand emerges; it doesn’t require an architecture change, just an optional per-user Sprites token that `ConversationServer` prefers over the platform token.
- The trust boundary for sandbox isolation is Sprites itself: each sandbox is an isolated Sprite. Verify before launch that the Sprites API does not let one sandbox enumerate or read another’s metadata or logs within the same account.

## Alternatives considered

- **BYO Sprites token per tenant** — Rejected at launch. Adds a required setup step that breaks self-serve onboarding; tenants would need to create and manage their own Sprites accounts before using Fountain.
- **Per-tenant Sprites sub-accounts** — Rejected. Not a feature the Sprites API currently supports.

## Addendum — 2026-08-02

Two mechanisms named above live somewhere other than where this ADR says:

- **Token read location.** `ConversationServer` does not read the token, and nothing calls `Application.fetch_env!(:fountain, :sprites_token)`. Access is centralized in `Fountain.SpritesClient.get!/0` (`apps/fountain/lib/fountain/sprites_client.ex`), which reads `Application.get_env(:fountain, :sprites_token)` and raises explicitly ("SPRITES_TOKEN is not set") when absent. All Sprites API callers go through that client.
- **Cap enforcement.** The production path does not call `Fountain.Quotas.check_sandbox_quota!/1`. Sandbox creation goes through `Fountain.Quotas.with_sandbox_reservation/2,3`, which runs the non-raising `check_sandbox_quota/2` together with the sandbox row insert under a per-user advisory lock (closing the check-then-insert race, #330). It is invoked from `Fountain.Conversations.start_conversation/1` and the wake path (`create_fresh_sandbox_and_start`). The raising `check_sandbox_quota!/2` exists but is exercised only by tests.

The decision itself — one platform token, per-tenant concurrency cap as the noisy-neighbor mitigation — is unchanged.

## Addendum — 2026-08-03

The Decision and Consequences still describe the token as "an env-var-only
secret on Render" with "Render environment-level access control" as a
mitigation. Render is decommissioned (the platform moved to the home-cloud
k3s cluster in 2026-08). In practice the token is materialized by the
Infisical operator into the `fountain-secrets` Kubernetes Secret
(`k8s/infisicalsecret.yaml`) and reaches the app as an env var via
`envFrom`; access control is the cluster's RBAC plus Infisical project
access. It remains env-var-only from the app's perspective — never in the
DB, never in the UI.

## Addendum — 2026-09-10

ADR 0042 keeps the cap and puts an explicit, bounded wait in front of it.
Fresh API starts can opt in to that queue, and a teammate schedule's cron
firing opts in by itself. The reservation still refuses work at the cap. The
drainer replays later under the same reservation lock, so the queue delays
the cap and never raises it.

## Addendum — 2026-10-12: the cap is no longer balance-funded

[ADR 0031](0031-credits-are-the-product.md) had the per-tenant cap funded by
the account's credit balance. Credits are removed, so the cap is the
account's `sandbox_limit_override` when an operator set one, and
`SANDBOX_CAP_CEILING` (default 20) otherwise. `SANDBOX_FLEET_CEILING` still
bounds the deployment as a whole. The noisy-neighbour rationale above is
unchanged, and it is now the whole rationale.

## Addendum — 2026-10-13: no per-tenant cap

Fountain is self-hosted only (2026-10-12), so the tenants sharing a
deployment's provider bill are the operator's own accounts, and the
noisy-neighbour risk this ADR answered is gone. The per-tenant cap is
removed: `SANDBOX_CAP_CEILING`, `users.sandbox_limit_override` and the admin
endpoint that set it, and the `429 sandbox_quota_exceeded` refusal. The
platform-shared credential stands. `SANDBOX_FLEET_CEILING` alone bounds how
many sandboxes the deployment runs, refusing past it with `503 fleet_full`.
ADR 0042's queue is retired with it (see that ADR's 2026-10-13 addendum).

## Addendum — 2026-10-14: where the token lives now

Three names above and in the earlier addenda point at things that are gone:

- **`Fountain.SpritesClient`** was deleted with the last Sprites shims (#680,
  2026-08-14). The token is read from `SPRITES_TOKEN` in
  `config/runtime.exs` (blank counts as unset) and handed to the
  `Managoat.Sandbox.Sprites` adapter's config
  ([0037](0037-component-libraries.md)); every Sprites call goes through
  that adapter.
- **`k8s/infisicalsecret.yaml`** left the repository with the hosted overlay
  (#1115, [0032](0032-hosted-overlay-leaves-the-repo.md)). How a deployment
  delivers the env var is its operator's business; this repository ships
  only the image.
- **Render** has not hosted Fountain since 2026-08 (the 2026-08-03 addendum).

The decision stands as amended: one deployment-wide provider token, read
from the environment only, never stored, shown or exposed to an account.

## Addendum — 2026-10-15: no usage meter

[0079](0079-usage-is-plain-counts.md) removed usage metering. "Prices its
own tiers to recover the cost" assumed a meter to price from; there are no
tiers and no meter, and the provider invoice is the cost authority. The
platform-shared credential stands.

## Addendum — 2026-10-15: the Sprites organization belongs to one instance

Decided by Jake on [#1919](https://github.com/managoat/managoat/issues/1919).
A Managoat instance owns the whole Sprites organization its `SPRITES_TOKEN`
reaches. Sharing that organization or token with another application, or
with a second Managoat instance, is unsupported. Managoat does not defend
against a sprite that belongs to someone else, so no ownership labels are
stamped at create and none are checked on adoption, and the `sprites-ex`
change that would have carried them is not needed.

What Managoat does by name, and why a shared organization breaks it:

- **Adoption.** `Managoat.Sandbox.Sprites.create/2` treats a `409` as "an
  earlier attempt of mine made this" and returns a handle to the existing
  sprite. `Fountain.Machines.Provision` then runs the pipeline on it, which
  writes the tenant's decrypted environment and vault values to its disk.
  A foreign sprite at that name would receive them.
- **Destruction.** Three paths destroy the sprite at a name this instance
  minted: the conversation's own teardown, `Provision`'s discard of a machine
  an interrupted attempt left behind, and the reaper's pass over terminal rows
  whose sprite still exists. None of them asks who made the sprite.
- **What is not touched.** The reaper's pass over sprites with no row only
  counts them. A foreign sprite is destroyed only if its name is one this
  instance minted.

A name clash needs the other party to use a name this instance mints
(`fountain-<tenant-prefix>-<suffix>`), so by accident it is mostly a second
Managoat instance on the same organization. The larger reason is the token
itself: anything that holds it can list, exec into and destroy every sprite
in the organization, so no label that holder could also write would be a
boundary. Two smaller costs remain even without a clash: the provider's
concurrent-sprite limit is shared while `SANDBOX_FLEET_CEILING_SPRITES` counts
only this instance's rows, and the reaper's untracked count includes the
other party's sprites.

Within one instance the tenants are already apart: account-prefixed names
(#1920) and the live `(provider, sprite_name)` unique index (#2141). The same
rule holds for E2B, whose adapter adopts any running or paused sandbox whose
`fountain_name` metadata matches and destroys by the same lookup: an E2B team
and its `E2B_API_KEY` belong to one instance.
