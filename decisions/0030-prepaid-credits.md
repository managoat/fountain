---
type: ADR
title: "Prepaid credits: a cents ledger burned by turn-hours, rent and messages"
description: "Usage is paid from a Fountain-owned ledger of integer cents, opened by a grant at verification and topped up by one-time Stripe Checkout packs, burned at $0.25 per conversation turn-hour. Zero is a soft stop. Decision 2's tiers were retired by ADR 0031; rent and message pricing (decision 4 and the comms rows of decision 3) were retired with Team comms in 2026-09; the remaining ledger decisions stand and are live on the hosted deployment. Auto top-up is not built."
tags: [billing, credits, entitlements, quotas, team-comms, finance]
status: stable
adr: "0030"
adr_status: "Accepted"
date: 2026-08-24
generated: { by: human:jhgaylor, at: 2026-08-24T20:00:00-04:00 }
verified: { by: agent:claude-code, at: 2026-08-25T05:00:00-04:00 }
---

# 0030 — Prepaid credits beside the capacity tiers: a cents ledger burned by turn-hours, rent and messages

**Status:** Accepted, amended by [ADR 0031](0031-credits-are-the-product.md)
(2026-08-25), which reversed decision 2: there are no tiers, no tier grants
and no subscription, and credits are the only product. The ledger decisions
(1, 3–8) stand and are **built and live** on the hosted deployment
(#1094–#1102, #1116, #1124, #1126, #1127). What exists: `Fountain.Credits`
and the `credit_ledger` with lots (decisions 1, 5), `Workers.CreditPricer`
(3) which also sweeps expiries on its ten-minute tick, `Workers.CreditExpirer`
as the daily backstop (2, expiry only), `Credits.grant_opening/2` posted at
verification (ADR 0031 decision 3), `Credits.Purchases` with refund and
dispute clawback (5), `Billing.check_spend/1` at every door and inside the
reservation lock, the 402, admin grants and the runway emails (6, 7), and
`Billing.Reconciliation` on `/admin/finance` (8, #1038 steps 1 and 2). Every
surface shows the balance.

**Retired 2026-09-13, with Team comms:** decision 4 (rent) and the four
comms rows of decision 3. `Credits.Rent`, the rent collector, the rent-due
email, the message pass of the pricer and the finance panel's contact and
message lines are deleted, and `CREDIT_NUMBER_CENTS`, `CREDIT_INBOX_CENTS`,
`CREDIT_EMAIL_MESSAGE_CENTS` and `CREDIT_SMS_MESSAGE_CENTS` are no longer
read. The feature had no users, and it was the only thing that made the
Team context depend on ee/. Nothing below is rewritten; the sections read as
they were decided.

There are no operator switches: `CREDITS_ENABLED` means credits on —
priced, granted, gated and shown — and off means none of it.
`CREDIT_PRICING_SINCE` and `CREDIT_ENFORCE` (#1104, #1105) and
`Release.start_credits/1` were the phase-5 migration levers and were deleted
once the hosted deployment had crossed over (#1121, #1116).

**Not built, on purpose:** auto top-up (#1086 phase 6); #1038 steps 3
onward (sandbox size, storage, per-provider cost basis).


**Inference is a priced cost in this ledger since #1388**
([0038](0038-onboarding-first-reply.md)): a turn that ran on a Fountain
platform key posts a `burn_inference` debit beside its `burn_turn`, priced
from `turns.usage` at the provider's list price with no markup.

## Context

ADR 0026 shipped capacity tiers and deliberately left the usage half open:
#798 question 1 asked whether the variable cost is recovered by post-paid
overage or by prepaid credits, and #1016 built the meter (turn hours against
an invoiced period) while enforcing nothing so that the shape could be decided
on real data. #1086 surveyed what exists and found that the measurement and
pricing halves are largely done — `Fountain.Billing.SandboxUsage`,
`Fountain.Billing.UsageEvent`, `Fountain.Billing.Finance.rate_card/1`,
`Billing.billing_period/2`, the `Billing.check_active/1` gate and the
`Quotas.with_sandbox_reservation/3` advisory lock — and that what is missing is
a ledger, a purchase path, an enforcement policy and a migration. It listed
five decisions that had to precede code. This ADR takes them, plus three that
fell out of taking them.

Two constraints shaped the answers:

- **There is no provider cost number.** Fountain has never reconciled its
  computed spend against a Sprites, AgentMail or AgentPhone invoice (#1038).
  Any customer price chosen today is chosen without knowing the margin. The
  price is therefore a *product* decision to be revisited when #1038 delivers
  a number, not a derived one.
- **Several conversations share one sandbox** (ADR 0023), so
  `turn_seconds` (per turn, summed) and `busy_seconds` (the union) differ and
  must not be swapped. Whatever unit credits burn on must attribute cleanly
  to a tenant when three of their conversations share a machine.

## Decision

### 1. A credit is a cent

The ledger is denominated in **integer cents**. Every surface displays
**dollars** — "$12.40 remaining", "$0.25 per hour". There is no "credit" unit
and no exchange rate. A rate-card change reprices future burn only; a balance
already sold keeps its dollar value.

### 2. Tiers survive; credits are the usage currency beside them

Solo / Team / Scale / legacy keep exactly what ADR 0026 gave them: the
concurrent-sandbox cap and the teammate-contact ceiling. `Billing.check_active/1`
stays the "subscribe to spend" gate (ADR 0006); the balance check is added
**beside** it, never in place of it. The trial machinery — `TrialSweeper`,
the trial emails, `past_due`, `comped`, `mix fountain.verify_lifecycle` — is
untouched.

`Plans.included_turn_hours` is replaced by a **monthly credit grant** worth
those hours at the turn-hour price: Solo 40 h → $10.00, Team and legacy
100 h → $25.00, Scale 200 h → $50.00, granted at the start of every billing
period (`Billing.billing_period/2`, `:subscription` source). Granted cents
**expire** at the end of the period they were granted for; purchased cents
**never expire**. Burn order is granted first, then purchased, so a customer
never loses paid money while free money sits unused.

The trial gets a **one-time opening grant of $10.00** (Solo's number, keeping
the ADR 0026 guardrail that a trial is never larger than a paid plan),
expiring when the trial ends. A trialing account **cannot buy credits**;
buying is behind `check_active/1` like every other spend.

### 3. What burns credits, and at what price

| Burn | Unit | Price | Source of truth |
|---|---|---|---|
| Conversation time | one hour of `turn_seconds`, per turn, per conversation | **$0.25** | `turns`, via `SandboxUsage` |
| Number rent | one calendar month per live phone number | `CREDIT_NUMBER_CENTS` | `Team.Comms` contacts |
| Inbox rent | one calendar month per live inbox | `CREDIT_INBOX_CENTS` | `Team.Comms` contacts |
| Email sent | one message | `CREDIT_EMAIL_MESSAGE_CENTS` | `usage_events` `comms_email_sent` |
| SMS, each way | one message | `CREDIT_SMS_MESSAGE_CENTS` | `usage_events` `comms_sms_sent` / `comms_sms_received` |

Turn-hours are priced on **`turn_seconds`, not `busy_seconds`**. A tenant pays
for the hours their conversations were in flight and nothing for a parked or
idle sandbox, which is what answers the ADR 0023 attribution question: three
conversations sharing one home each pay for their own turns, and the machine's
idle time is Fountain's cost, deliberately. `busy_seconds` stays what
`Finance` relates to the provider bill; the two numbers now have one reader
each and are never interchanged.

The $0.25 is a placeholder for a margin nobody can compute yet (see Context).
It lives in config (`CREDIT_TURN_HOUR_CENTS`, default 25) so that #1038's
first reconciled month can move it without a deploy. The four comms prices
**default to unset, which means the line does not burn.** Contacts bill nothing
today (#1035, #1042); turning a price on is a price increase and is an
operator's explicit act, documented in `plans-and-prices.md`, never a default.

Inference is not billed. ADR 0008 decision (b) stands.

### 4. Rent is a month up front

A number or inbox is debited **one full month at provisioning** and again on
each monthly anniversary of that provisioning. Provisioning is **refused**
when the balance is below one month of that resource's rent, in the same
`Team.Comms.provision_contact/4` seam that already enforces the contact
ceiling. Releasing a contact mid-month refunds nothing. The anniversary debit
runs from a rent worker keyed by contact id and period, idempotent, so a
worker restart cannot double-charge.

### 5. Fountain owns the ledger; Stripe is the till

`credit_ledger` is the source of truth: append-only rows with a signed amount
in cents, a closed `reason` vocabulary (`grant_opening`, `grant_admin`,
`purchase`, `burn_turn`, `burn_rent`, `burn_message`,
`expire`, `clawback_refund`, `clawback_dispute`), a resource reference, and
an **idempotency key** unique per row. `users.credit_balance_cents` is a cache
of the sum, maintained in the same transaction as the insert and reconciled by
a release task; a gate never sums the ledger.

Purchases are **one-time Stripe Checkout sessions in `mode: :payment`** for
fixed packs ($10, $25, $100), granted by a `checkout.session.completed`
branch beside the subscription one that already exists. Two webhooks the
codebase does not handle today become mandatory: **`charge.refunded`** and
**`charge.dispute.created`** write a negative `clawback_*` row for the
refunded amount, even when that drives the balance negative. Without them a
refund is free money.

Auto top-up (saved payment method, off-session PaymentIntent, SCA) is
**deferred** to #1086 phase 6. `stripity_stripe` 3.2.0 needs no bump for any
of this.

### 6. Zero is a soft stop

- **New sandboxes and new turns are refused** when the balance is ≤ 0. The
  sandbox check lives inside `Quotas.with_sandbox_reservation/3`, under the
  same advisory lock as the concurrency check; the turn check is at the
  `ConversationServer` turn gate beside `check_active/1`.
- **In-flight turns finish.** A turn that crosses zero completes and its burn
  lands as a negative balance, which is tolerated and recovered on the next
  grant or purchase. Nothing is killed or parked because of money.
- **Rent gets seven days of grace.** A contact whose anniversary debit fails
  for lack of balance is marked `rent_due_at`; the tenant is emailed on day 0,
  3 and 6; on day 7 with no top-up the contact is released through the
  existing `Team.Comms.release_contact/3` path. Release is irreversible — the
  number is gone — which is why it is the only spend that waits.
- **Runway warnings** at 20 % of the current period's grant and at $2.00
  remaining, once per period each.

### 7. Two short-circuits that come before any balance read

`Billing.enabled?/0 == false` and `subscription_status == "comped"` return
`:ok` from every balance check **before** the ledger is consulted, in the same
place `check_active/1` does. A self-hosted install never sees a balance; a
comped tenant's burn rows are still written (so `Finance` can see what the
comp cost) but never enforced. This is the trialing-defaults failure class
from `turn_hour_allowance/2`, named so it is not repeated.

### 8. Order of building, and what gates enforcement

#1086's phases stand. Two are load-bearing:

- **Phase 1, the trustworthy meter (#1038), gates phase 4.** `record_usage/5`
  is best-effort by contract (#503); a dropped `sandbox_suspended` today skews
  a report and under credits would charge a customer for parked time.
  Enforcement does not turn on until `[:fountain, :usage, :dropped]` is
  surfaced beside the numbers it undermines and a month of computed-versus-
  invoice deltas has been recorded. Pricing on `turn_seconds` rather than
  `busy_seconds` removes the suspend/resume pairs from the burn path
  entirely, which shrinks that error bar but does not close it.
- **Phases 2 and 3 ship enforcing nothing.** Debit into the ledger, show the
  balance everywhere, sell packs — and refuse nothing until phase 4, the same
  shape #1016 used.
- **Phase 5 migration:** on the deploy that turns enforcement on, every active
  subscriber receives the current period's grant pro-rated to the days left,
  and every trialing account receives the opening grant. No one starts at
  zero.

## Consequences

- `Fountain.Credits` and its workers live in `ee/` (ADR 0010); the gate seam
  crosses the boundary the way `check_active/1` already does. The
  `audit_guardrail_test` fails until the context audits its own mutations
  with a `credit.*` vocabulary, which is intended (ADR 0013).
- `Finance` gains a **deferred balance**: money taken is a liability until it
  is burned, and revenue becomes credits burned, not packs sold. This is the
  accounting #1037 is circling and it lands with phase 2.
- `Plans.included_turn_hours/1` and `Billing.turn_hour_allowance/2` are
  superseded by the grant; they are removed in phase 2 along with the
  "used against included" surfaces they feed. `Plans.team_contacts/1` stays
  as the abuse ceiling.
- Every surface that shows entitlement must agree: `BillingLive`,
  `GET /api/account/billing` (+ `schemas.ex`, the OpenAPI spec, a SDK regen —
  watch the defaults-become-required trap), `/admin/finance`, admin user
  pages, the pricing table on `/`, the dashboard, and the two operator docs
  pages behind the nav, style and Vale gates. `mix fountain.verify_plans`
  learns the pack prices or they drift (#991).
- A customer running an always-on persistent home (ADR 0023) with sparse
  turns pays little; Fountain eats the idle machine. That is accepted for
  now and is exactly the "price the mode" question #798 still holds open.
  When a provider cost number exists, revisit whether a parked-home rent is
  needed.
- We give up: Stripe-side balance visibility, and any automatic recovery from
  a negative balance until auto top-up ships.

## Alternatives considered

- **Credits only, no tiers** — cleanest model, but rewrites ADR 0006 and 0026
  wholesale (trial → grant, `check_active/1` → `check_balance/1`, sweeper,
  emails, lifecycle task) for no customer-visible gain over tiers + credits.
- **Abstract credit unit** — every rate-card change silently reprices sold
  balances; at $0.25/hour the display is either huge (1 credit = $0.01) or
  fractional (1 credit = $1).
- **Burn on `busy_seconds`** — closer to the provider bill, but needs an
  attribution rule for shared sandboxes and charges a tenant for a machine
  that is waiting.
- **Daily pro-rated rent** — smoother runway, but 30× the ledger rows per
  contact and a lapse is still caught only by a worker; month-up-front makes
  the rent always prepaid and the provisioning refusal trivial.
- **Stripe Billing Credit Grants + Meters** — Stripe holds the balance;
  `stripity_stripe` 3.2.0 has no module for either, so raw requests or an SDK
  bump, and a balance read is a round trip on every gate check.
- **Hard stop at zero** — parking a sandbox mid-turn for money loses work
  the customer already paid most of; the negative tolerance is bounded by one
  turn.
- **Auto top-up in v1** — SetupIntent, SCA and failed-payment retry roughly
  double phase 3 for a convenience; packs first, top-up when a customer asks.

## Refs

#1086 (tracker), #798 question 1, #1016 step 4, #1017, #1030, #1035, #1037,
#1038, #1042, #1043; ADR 0006, ADR 0008, ADR 0010, ADR 0013, ADR 0017,
ADR 0023, ADR 0026.
