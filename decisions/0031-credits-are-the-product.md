---
type: ADR
title: "Credits are the product: no tiers, concurrency as a balance-funded protection under a fleet ceiling"
description: "Retire the subscription tiers. A tenant buys credit, burns it on turns (rent and messages were retired with Team comms, 2026-09), and may run as many sandboxes at once as their balance funds, up to a per-account ceiling and the fleet ceiling the providers allow. Stripe stays only as the till for one-time packs. Supersedes ADR 0026 and the subscription gate of ADR 0006; amends ADR 0030 decision 2. Built; persistent-home rent is not."
tags: [billing, credits, quotas, plans]
status: stable
adr: "0031"
adr_status: "Accepted"
date: 2026-08-25
generated: { by: human:jhgaylor, at: 2026-08-25T02:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-25T04:00:00-04:00 }
stale_after: 2026-10-15
---

# 0031 — Credits are the product: no tiers, concurrency as a balance-funded protection under a fleet ceiling

**Status:** Accepted, built (#1114 the cap and fleet ceiling; the
retirement PR that follows it). What runs: `Billing.check_spend/1` is the
balance gate; `Accounts.verify_email/2` posts the opening grant;
`Quotas.sandbox_limit/1` is balance-funded under `SANDBOX_FLEET_CEILING`;
`Fountain.Plans`, `users.plan`, the subscription statuses, the trial
machinery, plan Checkout, the portal and `verify_plans` are gone, with the
subscription columns left unread in Postgres for one release. Stripe holds
no subscription and no price. Persistent-home rent (decision 7) is not built.


**Inference is a priced cost in the ledger since #1388**
([0038](0038-onboarding-first-reply.md)): a tenant with no inference
credential of their own runs on a Fountain platform key and burns
`burn_inference` for the tokens, at provider list price. The gate is
unchanged — the balance, through `Billing.check_spend/1` — and the only new
refusal is a per-deployment daily ceiling on platform inference, which is a
503 like `:fleet_full` rather than a 402, because it is Fountain's limit and
not the tenant's balance.

## Context

ADR 0026 sold three tiers that differed on one axis, the concurrency cap,
because concurrency was the only thing Fountain could meter and enforce.
ADR 0030 then built the usage meter — a prepaid ledger burned by turn-hours,
rent and messages — and kept the tiers beside it, each tier now also sizing
a monthly credit grant. After a day in production the seam between the two
was clean in concept but not in practice: credits were switched on by
`CREDITS_ENABLED`, grants were keyed on Stripe's `current_period_start`,
buying required an `active` subscription, and the concurrency cap was still
a thing sold in three sizes.

The operator's view, which this ADR adopts: Fountain makes margin on hours,
so a tenant should be free to use as many as they want. What Fountain cannot
give is unbounded *concurrency*, because the sandbox providers cap the fleet
— Sprites' $20 plan allows on the order of twenty live sandboxes and larger
plans allow more — and one tenant must not crowd out the rest. That is a
capacity protection, not a price, and selling it in tiers was a brake on
exactly the customers who spend the most.

## Decision

1. **Credits are the only product.** A tenant holds a balance in cents
   (ADR 0030) and spends it on turn-hours, rent and messages at the
   configured prices. There is no subscription, no tier, no monthly fee, and
   no monthly grant. `Fountain.Plans`, `users.plan`, `users.subscription_status`,
   `users.stripe_subscription_id`, the trial sweeper, the trial and dunning
   emails, plan Checkout, the customer portal, `change_plan/3`,
   `mix fountain.verify_plans` and the pricing tiers on the marketing page
   are retired. ADR 0026 is superseded, and ADR 0006's gate becomes the
   balance.

2. **The access gate is the balance.** `Billing.check_spend/1` is
   `Credits.gate/1`: a positive balance may spend, zero or less may not,
   in-flight turns finish (ADR 0030 decision 6). A **comped** account is an
   account whose balance is never checked — the one operator lever, kept.
   Buying a pack is the only door, and it is open to any verified account;
   the card through Stripe Checkout is the identity check a subscription
   used to be.

3. **The trial is an opening grant.** Verification posts `grant_opening` of
   `CREDIT_OPENING_CENTS` (default $5; the ADR said $10, the operator set $5 on 2026-08-25) expiring `CREDIT_OPENING_DAYS`
   (default 14) later. Nothing else about a "trial" exists: no status, no
   clock, no sweep.

4. **Concurrency is a protection funded by the balance.** For one account,
   `cap = clamp(floor(balance ÷ SANDBOX_RESERVE_CENTS), SANDBOX_CAP_FLOOR, SANDBOX_CAP_CEILING)`
   with defaults reserve $2 (eight turn-hours), floor 2, ceiling 20;
   `users.sandbox_limit_override` still wins when set, as the operator's
   lever for a tenant who has earned more. The $5 opening grant funds the
   floor of two; $100 funds twenty; zero funds none because the gate refuses
   first. Nobody can start a fleet they cannot pay for.

5. **A fleet ceiling bounds the sum.** `SANDBOX_FLEET_CEILING` (default 20,
   the Sprites $20 plan) is the most sandboxes the deployment will have live
   across every tenant; `Quotas.with_sandbox_reservation/3` checks it under
   a global advisory lock beside the per-account one, and refuses with
   `:fleet_full`, which the API reports as 503 with a retry hint rather than
   402. The operator raises it when the provider plan changes; it is a
   number, not a plan.

6. **Stripe is the till, nothing more.** One-time Checkout for packs, and the
   `checkout.session.completed`, `charge.refunded` and
   `charge.dispute.created` webhooks. `CREDITS_ENABLED` now means exactly
   "credits are on": off, nothing is priced, granted, gated or shown, and
   the caps fall back to floor and ceiling. `CREDIT_ENFORCE` and
   `CREDIT_PRICING_SINCE` are retired as switches: pricing starts when
   billing is on.

7. **Persistent-home rent is a follow-up (#1120).** Idle time on a parked
   home (ADR 0023) is Fountain's cost and the fleet ceiling is what bounds it
   for now. The question is not "rent for a mode": `ephemeral` and
   `persistent` are one lifecycle policy on the machine, not two products
   (#805, the design note 0023 is the incremental step toward), and a parked
   ephemeral sandbox costs Fountain the same storage as a parked home. What
   #1120 has to choose is whether the machine's *kept* time is priced as rent
   per machine (the `Credits.Rent` shape) or metered per parked minute (#798,
   what `SandboxUsage` is halfway to). Read #805 before deciding.

## Consequences

- Revenue becomes credits sold and burned; there is no MRR. `Finance`
  drops the plan lines and keeps the ledger figures from #1108. The
  deferred balance is the liability to watch.
- Every existing account is migrated by a release task: the one active
  subscriber keeps their balance and their Stripe subscription is cancelled
  by the operator; trialing accounts keep their opening grant; canceled
  accounts hold $0 and are gated by the balance exactly as they were by the
  status. `team_contacts` becomes one number, `TEAM_CONTACT_CEILING`
  (default 10).
- `GET /api/account/billing` loses `status`, `plan`, `trial_ends_at`, the
  period and the portal/checkout endpoints; it carries `credits` and
  `sandbox_cap`. A major SDK bump.
- The marketing page sells credit: the price per hour, the packs, the
  opening grant, and the concurrency rule stated plainly.
- We give up predictable monthly revenue and the "subscribe first" identity
  check; the card on a pack purchase replaces the second, and the first was
  never real at two users.

## Alternatives considered

- **Keep tiers as a membership fee with included credit** — a tier is then
  a discount on credit plus a cap; the cap still brakes the best customers
  and the fee still needs Stripe subscriptions.
- **Unlimited concurrency, no cap** — one tenant can consume the provider
  plan; the fleet ceiling is the provider's, not ours to waive.
- **A cap bought as a SKU** — reintroduces tiers by another name; the
  balance already answers whether the tenant can pay for what they start.

## Refs

#1086, #798, #1038, #1112; ADR 0006, ADR 0017, ADR 0023, ADR 0026, ADR 0030.
