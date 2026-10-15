---
type: ADR
title: "Hard Stripe billing gate at launch with a 14-day trial"
description: "Retired 2026-10-13: billing was removed. Was: a hard Stripe billing gate at launch with a 14-day trial."
tags: [billing, stripe]
status: deprecated
adr: "0006"
adr_status: "Retired"
date: 2026-05-09
generated: { by: human:jhgaylor, at: 2026-08-05T02:16:38-04:00 }
verified: { by: agent:claude-code, at: 2026-08-25T05:00:00-04:00 }
---

# 0006 — Hard Stripe billing gate at launch with a 14-day trial

**Status:** Retired 2026-10-13. It was superseded by
[ADR 0031](0031-credits-are-the-product.md) (2026-08-25), which was itself
retired on 2026-10-12 when credits and Stripe were removed, so nothing of
either decision remains in the code. Was: Superseded by ADR 0031. There is no subscription, no trial and no `subscription_status`; the gate that protects spend is the credit balance (`Billing.check_spend/1` = `Credits.gate/1`), and a refusal is `402 insufficient_credits`. What survives from here is the *shape* of the decision — a hard gate on spend at the doors, not on features, with the console readable regardless — and the Stripe webhook plumbing, now carrying credit packs. The text below is history: it describes the gate as built on 2026-05-09 and amended through 2026-08-05, none of which is in the code.

## Context

The Phase 2 engineering plan raised OQ-5b: ship a hard billing gate at launch (block users without an active subscription from creating sandboxes), or ship a usage-tracking stub and add the gate later? OQ-5a asked which payment provider; OQ-5c asked the usage period.

The case for a stub at launch was reduced sprint scope: skip Stripe integration, leave `BILLING_WEBHOOK_URL` empty, ship the rest. The case for a hard gate was that Fountain pays for tenants' sandbox usage on a shared Sprites account ([ADR 0005](0005-platform-shared-sprites-token.md)), so every free user is a direct cost line on the Sprites bill. Without a gate, scaling users without scaling revenue is the default behavior of the system.

Two related calls fall out of "hard gate": choice of provider (Stripe — best Elixir tooling via `stripity_stripe`, fastest path to ship a Checkout flow) and how to avoid locking users out the moment a payment fails (a `past_due` window with read-only access).

## Decision

Fountain ships with a **hard Stripe billing gate** at launch, integrated via `stripity_stripe`. New users get a **14-day trial** that begins at registration; a Stripe Customer is created at email verification, and `users.subscription_status` is synced from Stripe webhooks (`trialing`, `active`, `past_due`, `canceled`).

Gate enforcement, via `Fountain.Billing.assert_active!(user)`:

- **Allowed when** `subscription_status in [:trialing, :active]`.
- **Allowed read-only when** `subscription_status == :past_due` — the user can view past conversations, list resources, update payment method, but cannot start new conversations or provision sandboxes. This window exists so a temporary card decline doesn't lock users out of their own data while they fix payment.
- **Blocked when** `subscription_status in [:canceled, nil]` — POST to write endpoints returns 402 Payment Required pointing at the upgrade URL; LiveViews flash + redirect to `/account/billing`.

Plan management uses Stripe Checkout (new subscriptions) and Stripe Customer Portal (existing subscriptions, payment method updates, cancellation). Webhook endpoint `POST /api/stripe/webhook` is signature-verified via `Stripe.Webhook.construct_event/3`.

Usage period (OQ-5c): **calendar month in the user's selected timezone** (default UTC). `BillingLive` aggregates `usage_events` for the current calendar month. *(Per-user timezone was **never built** — the period is calendar-month **UTC**, hardcoded; see Addendum 2026-08-02.)*

Pricing tier shape (Free / Pro / etc.) is **not** decided here — that's growth/marketing's call before launch. This ADR commits to the gate mechanism, not the price points.

## Consequences

- Sprint scope grows by the Stripe integration: customer creation flow, webhook endpoint, Checkout + Portal links, `assert_active!` enforcement at three call sites (`ConversationServer.init/1`, `POST /api/conversations`, `:require_active_subscription` LiveView hook). Recommend treating it as its own sprint or a clearly-scoped track within the auth/billing sprint.
- Revenue exists from day 14 of the first paying user. Without the gate, revenue would be zero until a future sprint added it; the runway implication of that gap was the dispositive argument.
- Users who registered, did the wizard, and never paid silently consume Sprites resources during the 14-day trial. Mitigation: trial users are still bound by the per-tenant concurrency cap (default 5, [ADR 0005](0005-platform-shared-sprites-token.md)). If trial-period costs surprise on the Sprites bill, drop the trial cap separately from the paid cap.
- Pricing decisions become unblocking: growth/marketing must propose tier prices before launch, even if "Free tier = blocked after trial" is the simplest opening position. The ADR does not require multiple tiers; one paid tier + the trial is enough to ship.
- `past_due` UX must be tested explicitly — it's the most common churn-inducing state and the easiest to get wrong (false lockouts on transient declines, or true lockouts when the read-only window is too short).
- Stripe is now a launch-blocking dependency. If Stripe is down, no new subscriptions complete and webhooks queue. `stripity_stripe` and Stripe's own retry behavior on webhook delivery are the mitigations; document the behavior when webhooks are delayed (subscription state lags reality by minutes — acceptable).
- Provider lock-in is Stripe-shaped: switching providers later means re-implementing Customer Portal flows and remapping subscription states. Within the cost of doing business; the alternative (provider-neutral abstraction at launch) costs more than it saves.
- Reversal cost: low for the gate itself (changing `assert_active!` to always return `:ok` is one line). High for the Stripe integration if it has to be ripped out — but no realistic post-launch path requires that.

## Alternatives considered

- **Usage-tracking stub at launch, gate added in growth sprint.** Rejected: every free user is a direct Sprites cost. Adding the gate later means migrating users who never expected to pay, which is worse UX than charging from launch.
- **Soft warn at launch (track usage, surface warnings, no enforcement).** Rejected: same cost problem as the stub, plus a worse story for "we never said this was free." A hard gate with a generous trial is more honest.
- **Paddle or Lemon Squeezy as merchant-of-record (handles tax/VAT globally).** Rejected for launch: Stripe has materially better Elixir tooling and a faster path to a working Checkout flow. International tax compliance is a real concern but addressable post-launch (Stripe Tax, or a provider switch if Stripe Tax proves inadequate). Don't trade ship velocity for problems that don't exist yet.
- **Lifetime / one-time payment instead of subscription.** Rejected: incompatible with a per-conversation cost model where Fountain pays Sprites continuously. Subscription matches the cost shape.

## Addendum — 2026-08-02

Five points where this ADR has drifted from (or never matched) the code:

- **Enforcement sites.** There is no billing check in `ConversationServer.init/1` — there never was. The gate's backstops are `Fountain.Conversations.start_conversation/1` and the wake path (both reuse and fresh-sandbox arms call `Fountain.Billing.check_active/1` alongside the suspension check), plus a per-turn gate inside `ConversationServer` (`turn_gate/1`, added for #313 so a live sandbox doesn't outlive its subscription), and the `:require_active_subscription` LiveView hook. `assert_active!/1` still exists; the pipeline call sites use the non-raising `check_active/1`.
- **Allowed statuses.** The code allows `~w(trialing active comped)` (`apps/fountain/lib/fountain/billing.ex`), not `[:trialing, :active]`. `comped` is operator-granted free access, set only from the admin panel.
- **`past_due` cannot view past conversations.** `/conversations`, `/conversations/new`, and `/conversations/:id` sit inside the `:active_subscription` live_session in the router, so a `past_due` user is redirected to billing. What remains reachable is the log viewer (`/conversations/:id/logs`) plus dashboard, resource, onboarding, and billing/settings routes in the `:authenticated` live_session. The "read-only window" as described above is narrower in practice.
- **Usage period timezone was never built.** There is no user timezone field; `BillingLive.current_month_range/0` computes the calendar month in UTC, hardcoded. Per-user timezone selection remains unbuilt; if it matters, it is a new piece of work, not something this ADR delivered.
- **The gate is now conditional — and opt-in.** `BILLING_ENABLED` (`config/runtime.exs`) feeds `Fountain.Billing.enabled?/0`. It defaulted to `"true"` until #336 flipped it: the default is now `"false"`, because on a self-hosted instance the gate is a lock on the front door with no key, and the operator most likely to miss the variable is exactly the one it locks out. The hosted deployment opts in explicitly (`k8s/deployment.yaml` sets `BILLING_ENABLED=true`). The "hard gate" decision stands for the hosted product, but it is now config, not an invariant of the source.


## Addendum — 2026-08-05: the gate's scope outside conversations is deliberate

The 2026-08-05 billing review (#500) flagged that the API surface outside
conversations is not billing-gated: a canceled user with a still-valid API key
can list, create, update, and delete agents, environments, vaults, and
secrets. Only conversation start, wake, and per-turn processing call
`Billing.check_active/1`.

Decision (2026-08-05): that is the invariant, not an accident of where the
checks landed. **The gate protects spend, not features.** Every conversation
consumes sprite cost on the shared Sprites account ([ADR 0005](0005-platform-shared-sprites-token.md)), so the
conversation lifecycle is the enforced boundary. Configuration CRUD costs
nothing to serve, and leaving it open means an expired user can still reach
and manage their own data (consistent with [ADR 0009](0009-account-deletion-and-export.md) — payment state never
holds data hostage) and a returning subscriber's configs are intact when they
reactivate.

Accordingly, the Decision section's "Blocked when canceled — POST to write
endpoints returns 402" is scoped to the sprite-cost surfaces. It was never
enforced on config CRUD and will not be. If abuse appears (say, canceled
accounts using vaults as free encrypted storage), the answer is a quota, not
a billing gate.

The remaining `past_due` drift — ADR promised read access to past
conversations, code delivers log-view-only — is an open decision tracked in
#505, not resolved here.

## Addendum — 2026-08-05: read-only access widened to match the promise (#505)

Decision (Jake, 2026-08-05): the original read-only window is the intent —
a card decline must not hide the user's data. The code now matches it:

- `/conversations` and `/conversations/:id` moved from the
  `:active_subscription` live_session to `:authenticated`, so `past_due` and
  `canceled` users can list and view their conversations. Only
  `/conversations/new` remains router-gated.
- Inside `ConversationsLive.Show`, the gate moved to the events that create
  spend: `send_prompt`, `update_prompt`, and `images_selected` are refused
  (flash, no effect) when the subscription is inactive, and the composer is
  replaced by a read-only banner linking to billing. This is the same
  "gate protects spend, not features" invariant as the addendum above.
- `terminate` and `interrupt` stay available to lapsed users deliberately:
  they *stop* spend, and blocking a lapsed user from ending a running sprite
  would protect spend in reverse. `delete` stays available too — removing
  data is not consumption (consistent with [ADR 0009](0009-account-deletion-and-export.md)).
- The API surface is unchanged: conversation start/wake/turn processing
  remain gated by `Billing.check_active/1`; conversation *reads* over the API
  were and are governed by the addendum above, not this one.

This closes the third bullet of the 2026-08-02 addendum ("`past_due` cannot
view past conversations") — that drift no longer exists.
