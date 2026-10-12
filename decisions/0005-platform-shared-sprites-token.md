---
type: ADR
title: "Platform-shared SPRITES_TOKEN; per-tenant concurrency cap as noisy-neighbor mitigation"
description: "One platform-level Sprites credential provisions every tenant sandbox; a per-tenant concurrent-sandbox cap is the noisy-neighbor mitigation. Amended by 0018 to one credential per provider, and by 0042 with a bounded wait in front of the cap. Since 2026-10-12 the cap is an operator override or SANDBOX_CAP_CEILING, not funded by any balance."
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
