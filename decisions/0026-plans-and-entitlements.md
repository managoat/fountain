---
type: ADR
title: "Plans priced on concurrent sandboxes, with teammate contacts as a per-unit add-on"
description: "Superseded by 0031, itself retired. Was: plans priced on concurrent sandboxes with teammate contacts as an add-on."
tags: [billing, entitlements, quotas, team-comms]
status: deprecated
adr: "0026"
adr_status: "Superseded by 0031"
date: 2026-08-22
generated: { by: human:jhgaylor, at: 2026-08-22T06:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-22T06:00:00-04:00 }
---

# 0026 — Plans priced on concurrent sandboxes, with teammate contacts as a per-unit add-on

**Status:** Superseded by ADR 0031 (2026-08-25): the tiers, the subscription and the plan column were retired by #1116 and the dead columns dropped by #1127; the concurrency cap is a balance-funded protection. Everything below is history: amended by ADR 0030 (2026-08-25): the teammate-contact
add-on (`Billing.sync_contact_addon/1`, `STRIPE_PRICE_ID_CONTACT`,
`users.comped_contacts`) was retired in favour of rent from the prepaid
balance; the contact *ceiling* stays. Everything else described here is built: `Fountain.Plans`,
the `users.plan` column and the `sandbox_limit_override` rename-in-Elixir,
`Quotas.sandbox_limit/1` reading from the plan, the price-to-plan mapping in
`Billing.sync_subscription/1`, `Billing.change_plan/3`,
`Billing.sync_contact_addon/1`, the contact ceiling in `Team.Comms`, the plan
picker on `/account/billing`, the pricing table on `/`, and
`mix fountain.verify_plans`. The Stripe prices themselves are an operator
step; see `docs/guides/operate/plans-and-prices.md`.

## Context

Fountain sold one thing: a flat monthly subscription behind a single
`STRIPE_PRICE_ID`, with a 14-day trial (ADR 0006, which explicitly left the
price *shape* undecided). There was no `plan` column and no tier concept
anywhere in the code.

The only per-tenant entitlement that existed was
`users.max_concurrent_sandboxes` — default 5, admin-settable, enforced by
`Fountain.Quotas` at every sandbox creation. It was a de-facto manual tier: an
operator could hand a customer a bigger cap, and nothing tied that cap to what
the customer paid. Everything else the product does was available to everyone
who was past the gate.

#798 laid out the fuller picture: sandbox-active-hours are the honest variable
unit, metering exists but drives nothing, and a real model wants capacity tiers
*plus* metered hours or prepaid credits. That is still true, and it is still
where this is going. It is not what this ADR does.

Separately, teammate comms (#850) let a teammate be given an email inbox and a
phone number, both provisioned under Fountain's own AgentMail and AgentPhone
keys. It shipped behind a PostHog flag with no billing attached at all, and
each contact costs Fountain money every month for as long as it exists.

## Decision

### One axis: concurrent sandboxes

Three public tiers, differing in nothing but the cap `Quotas` already enforces:

| Plan | Concurrent sandboxes | Contact ceiling | Price |
|---|---|---|---|
| Trial | 2 | 0 | free |
| Solo | 5 | 1 | $29/mo |
| Team | 15 | 3 | $79/mo |
| Scale | 40 | 10 | $199/mo |

> **These caps were retuned on 2026-08-23** to 2 / 5 / 10 at the same prices.
> See the second amendment at the end of this document; `Fountain.Plans` is
> the live catalog either way.

Concurrency is the only axis because it is the only number that is
simultaneously a real cost to Fountain (capacity on the shared provider
account, ADR 0005/0018), already enforced in code, and legible to a customer
with no usage meter in front of them. Everything else the product does stays
on every plan. A feature-gated ladder would need a second enforcement
mechanism, would put the subscription gate back in the business of protecting
features rather than spend (which the 0006 addendum deliberately undid), and
would sell a worse product to the smallest customers.

Sandbox-hours are deliberately **not** part of this. They are the better
variable unit and they remain the plan, but they need the metering correctness
work in #798 first, and shipping tiers does not foreclose them: a tier gains an
included-hours figure later without any of this changing shape.

### `legacy`: grandfathering as a plan, not as a migration

Every account that bought the flat price is on a fourth plan, `legacy`, pinned
to the old `STRIPE_PRICE_ID`. It carries **Team's** capacity at **Solo's**
price, and `public?: false` keeps it out of the pricing table and the plan
picker.

The alternative was to snap everyone to the tier their price maps to. That
would have been Solo, at 5 concurrent — the same number they had — but it
would have made every future capacity decision for those accounts, and it
would have meant the first customers paid the same as new ones for less. A
closed plan says the true thing instead: they are on an earlier deal, they keep
it as long as they like, and every move off it is an upgrade.

`Plans.upgrade?/2` orders `legacy` below every public plan, which is what makes
it structurally upgrade-only. Nothing in the UI can offer a move back onto a
price nobody can buy.

### The cap column becomes an override

`users.max_concurrent_sandboxes` is now the operator's *override*, not the
entitlement. Null means "whatever the plan says", so an upgrade takes effect
without anyone touching the column, and the two situations the override exists
for still work: raise it for a trusted tenant, drop it to zero during abuse.

The Postgres column keeps its name. The Elixir field is
`sandbox_limit_override`, mapped with Ecto's `:source`. This is not squeamishness
about a rename — it is that a rename breaks every pod still running the
previous release for the length of a rolling deploy, while making the column
nullable does not, because the previous release already treats a null as "use
the default". The worst an old pod does mid-rollout is apply the old default of
5, to exactly the rows the migration nulled.

Admin surfaces show the enforced cap and the plan it came from. The API keeps
`max_concurrent_sandboxes` as the *effective* number and adds
`sandbox_limit_override` and `plan` beside it, so nothing reading it breaks.

### The plan follows the Stripe price, and only the webhook writes it

`Billing.change_plan/3` asks Stripe to reprice the subscription's plan item and
writes nothing locally. `customer.subscription.updated` comes back and
`maybe_adopt_plan/3` writes `users.plan` from the price on that subscription.

The entitlement therefore always follows what Stripe actually charges, never
what we asked it to charge. A repricing that half-failed cannot leave a tenant
holding a cap they are not paying for.

Three cases leave the stored plan alone on purpose:

* a `.deleted` event — the account is losing access, not changing tier, and the
  plan it held is what a resubscription should default back to;
* a price this deployment does not recognise — realistically an env var not yet
  set on the replica handling the webhook, and nulling a paying tenant's
  entitlement over that is worse than leaving it stale;
* an event with no items at all.

`Plans.slug_for_price_id/1` answering `nil` for the contact add-on price is
what makes "the first item that names a plan" correct rather than
order-dependent. A tenant with contacts carries two items.

### Teammate contacts: a per-unit add-on, plus a ceiling

An AgentMail inbox and an AgentPhone number are a recurring per-teammate cost,
which is the wrong shape for a flat tier: a tenant with ten numbers costs
Fountain ten times what a tenant with one does, at the same price. So they
are billed per unit — a second subscription item on the same subscription,
whose quantity `Billing.sync_contact_addon/1` sets to the tenant's contact
count.

**Set, never increment.** The quantity is computed from the contact rows every
time, so a dropped call, an Oban retry, a crash between provisioning and
syncing, or an admin deleting rows directly all converge on the right number at
the next provision or release. An increment would drift, and a drifted
increment bills a tenant for numbers they do not have.

The sync runs *after* the row is committed and is best-effort by rescuing. The
providers have already been paid by that point; a Stripe hiccup must not fail a
provision they completed, or strand a released number as un-released.

That leaves one window: a tenant provisioning in a burst while the sync is
down. `Plans.team_contacts/1` closes it with a per-plan ceiling — an abuse
bound, not an entitlement. Any plan can buy contacts; no plan can buy an
unbounded number of them faster than anyone would notice. The ceiling refuses
with 402 (the same status the subscription gate uses, because the fix is a plan
change and not a retry) and buys nothing before it refuses.

Zero quantity deletes the item rather than setting it to zero: Stripe rejects a
zero quantity on a licensed price, and a lingering item puts "1 × contact" on
the invoice of a tenant who released their last number.

The add-on item lives on the subscription, so a **new** subscription starts
without it — and the quantity is otherwise only pushed on provision and
release. A tenant who cancelled (or was comped and then un-comped) and came
back through Checkout would therefore keep their numbers and stop being billed
for them until they happened to add or remove one.
`complete_checkout/4` re-attaches the item after adopting the subscription,
best-effort and last, so a Stripe hiccup there cannot make the webhook fail and
have Stripe redeliver an adoption that already succeeded.

### The trial is a plan, and a smaller one

A `trialing` account gets the `trial` plan's numbers — 2 concurrent, 40 turn
hours, 0 teammate contacts — whatever tier its subscription names.

Before this, a trial carried the full numbers of the tier it sat on (`solo`,
because that is the price registration opens the trial with). Converting
therefore bought the customer nothing on the day they paid, which is a strange
thing for the moment you most want to feel like progress. It also made the
customer portal's `end_trial` setting look punitive rather than generous: end
the trial early and the customer loses free days for no gain. With the trial
genuinely smaller, ending it *is* the upgrade.

`Plans.effective/1` is the split. `resolve/1` keeps answering "what tier is
this subscription for" — the price id, the plan picker, what the trial converts
into. `effective/1` answers "whose numbers apply today". Every entitlement
reader routes through the second when handed a `%User{}`; a bare slug carries
no status and cannot, which is exactly how `turn_hour_allowance/2` first read
the paid allowance for a trialing account.

Two constraints shaped it:

* **Only when billing is on.** `subscription_status` defaults to `"trialing"`
  in the schema, so on a self-hosted instance every account would otherwise be
  silently capped at two sandboxes — for someone paying their own provider
  bill. The guard is `Billing.enabled?/0`, the same switch `DEFAULT_PLAN`
  answers to.
* **An operator override still wins.** `sandbox_limit_override` is an operator
  naming a number for an account; a trial is not a reason to second-guess it.

Zero contacts is the sharpest edge and the one most likely to be revisited: it
means a prospective customer cannot evaluate teammate email and phone during
their trial at all. It is set that way because each contact is a recurring bill
from the moment it exists, and a free trial that mints one is an abuse vector
with a monthly cost. One number in the catalog changes it.

The trial's 40 hours keep the 20-per-slot ratio the other plans hold, rather
than being chosen freely — the ladder stays derivable from one axis.

### Two levers for comping, deliberately separate

`comp_account/1` makes **everything** free: it cancels the Stripe
subscriptions, and `sync_contact_addon/1` short-circuits on the resulting
`comped` status. That is the right lever for an account that should pay
nothing at all.

`users.comped_contacts` is the narrower one: the first N contacts are not
billed, so the quantity pushed to Stripe is `max(0, count - comped_contacts)`.
It exists because the account comp cannot express the case that actually comes
up — a tenant who pays for their tier and holds a number Fountain eats the cost
of. Flooring at zero is what makes an allowance larger than the contact count
harmless rather than a negative quantity Stripe rejects.

Both are admin-only and audited (`admin.comped_contacts.changed`). Setting the
allowance re-syncs the add-on immediately; without that the change would not
reach Stripe until the tenant's next provision or release.

`Accounts.update_plan/3` is admin-only for the same reason:
`Billing.change_plan/3` refuses for a comped account — an operator's decision
is not the customer's to revise — so a comped account would otherwise have no
door onto its own entitlements at all.

### Self-hosting

`DEFAULT_PLAN` (default `solo`) is the plan for any account with no plan of its
own, which on a self-hosted instance is every account. A self-hoster pays their
own provider bill, so `DEFAULT_PLAN=scale` lifts the cap for everyone at once
without inventing a billing relationship. `BILLING_ENABLED=false` continues to
mean what it meant.

A plan with no price id configured is simply not sellable:
`Billing.available_plans/0` filters on it, so the pricing table and the plan
picker show nothing rather than a button that leads to a Stripe error. This is
also what lets the price ids be rolled out one at a time.

### Drift between the catalog and Stripe

The catalog carries a display price; Stripe carries the charged price; nothing
links them. `mix fountain.verify_plans` does: it reads every configured price
from Stripe and fails if the amount, currency, interval or active flag
disagrees with the catalog. It is read-only and safe against live mode, which
is where it is worth running.

## Consequences

* An upgrade is a real, immediate capacity change, prorated by Stripe, with no
  operator in the loop. That was the missing product motion.
* The subscription gate is unchanged and still protects spend rather than
  features (0006 addendum). Nothing new calls `check_active/1`.
* Two numbers now describe an account's capacity — the plan's and the enforced
  one. Every surface that shows a cap has to show the enforced one, and the
  admin views say which it is.
* **A downgrade does not reclaim capacity already in use.** The cap is checked
  at sandbox creation, so a tenant who moves from Scale to Solo keeps the
  sandboxes already running and is refused the next one until the count falls
  below the new cap. Killing an agent mid-task to enforce a billing change is
  the wrong trade, but it does mean a downgrade can leave an account
  temporarily over its cap, and any capacity report has to tolerate that.
* Teammate contacts stop being free to Fountain and start being metered by
  count. A tenant on the flag today will see a line item appear on their next
  invoice once `STRIPE_PRICE_ID_CONTACT` is set; setting that variable is
  therefore a customer-facing act, not a config tidy-up.
* The tiers make the #798 hours work easier, not harder, but they also mean a
  later hours model has to fit *inside* a tier rather than replace it. See the
  amendment below, which is that model's first increment.
* Price points are now partly in code (`Fountain.Plans`) and partly in Stripe.
  `verify_plans` is the only thing standing between that and a customer being
  shown one number and charged another. Run it.

## Amendment (2026-08-23) — included turn hours, reported and not enforced

**Status:** Accepted and built (#1016 steps 1 to 3). The allowance is
displayed on every surface. **No code path refuses anything because of it**;
steps 4 and 5 of #1016, which decide the overage shape and add a ceiling, are
deliberately not built.

Each plan now carries `included_turn_hours` — 20 hours per concurrent slot, so
Solo 100, Team 300, Scale 800, `legacy` 300 at Team's capacity. Three things
about it are decisions rather than details.

**The unit is turn time, not sandbox-active time.** #798 called
sandbox-active-hours the honest variable unit, and for *Fountain's* cost it is:
an idle sprite is billed at full rate. It is the wrong unit to sell, because
the tenant behaviour it punishes is forgetting to close a tab, not doing work.
`SandboxUsage` has separated `busy_seconds` from `idle_seconds` since #666, so
the allowance is denominated in busy time and the idle half stays a cost signal
for the operator (`provider_spend/1`) rather than a customer-facing number.
Hours on a self-hosted runner (0022) are excluded for the same reason from the
other direction: Fountain pays nothing for that machine.

> **Addendum, 2026-08-24 — summed per turn, not the sandbox's union.** Once
> several conversations may run on one sandbox at the same time (0023, step
> 6), "busy time" has two readings: the union of a sandbox's turn intervals
> (how long the machine had any turn in flight, which is what a provider bill
> relates to) and their sum (how much work the tenant did). The allowance is
> spent in the sum — `SandboxUsage.turn_seconds` and
> `turn_seconds_for_user/3` — so two conversations each running an hour on
> one machine spend two hours of it. `busy_seconds` keeps the union and stays
> capped at `active_seconds`; `turn_seconds` is not capped and may exceed it.

The prod distribution this was set against, at the time of writing: the
dogfood account burned 271 turn hours in a month against 11,091 active hours,
and every other tenant was under half a turn hour. The ratio between those two
columns is the whole argument.

**The period is Stripe's, not the calendar's.** `users.current_period_start`
is now synced beside `current_period_end`, and `Billing.billing_period/2`
returns `%{start, end, source}`. An account with no invoiced period — comped,
self-hosted, or not yet reported by a webhook — gets the calendar month with
`source: :calendar_month`, and **every surface displays that fact**. The
alternative considered and rejected was deriving the start from the previous
`current_period_end`, which is wrong for a `trialing` account, where that field
holds the trial end rather than a period boundary.

**It is reported before it is enforced, on purpose.** Setting a number that
bills people before seeing a cycle of real usage against it is how you pick a
figure that is wrong for everybody. The overage shape (post-paid versus prepaid
credits) stays open in #1016. Note for whoever closes it: the contact add-on
this ADR built is a *licensed* quantity price, and Stripe ignores quantity on a
metered price — hours need Meter Events or a credit balance, not a second
licensed item.

## Alternatives considered

**Two tiers instead of three.** Simpler, and the middle tier is where most
customers land, so a ladder without one pushes them to the top or the bottom.
Three gives the upgrade motion somewhere to go.

**Feature-gated tiers.** Rejected above: a second enforcement mechanism, and it
re-entangles the gate with features.

**Contacts included per tier.** Simplest to build and the easiest to explain,
but it prices a genuinely per-unit cost as a flat one. A tier generous enough
for the tenant with ten numbers is priced wrong for the tenant with one.

**Contacts as a separate subscription.** A second Stripe subscription per
tenant would mean two invoices, two dunning paths, and a second thing for
`sync_subscription/1` to disambiguate. One subscription with two items keeps
all of that in one place.

Refs: #798, ADR 0005, ADR 0006 (and its 2026-08-05 addendum), ADR 0013,
ADR 0017, ADR 0018.

## Amendment (2026-08-23) — the caps retuned to 2 / 5 / 10, and the trial ties Solo

**Status:** Accepted and built. Only the numbers in `@plan_specs` moved. The
axis, the derivation, the override, the webhook-writes-the-plan rule and the
contact add-on are all unchanged.

| Plan | Concurrent | Turn hours | Was |
|---|---|---|---|
| `trial` | 2 | 40 | unchanged |
| `solo` | 2 | 40 | 5 / 100 |
| `team` | 5 | 100 | 15 / 300 |
| `scale` | 10 | 200 | 40 / 800 |
| `legacy` | 5 | 100 | 15 / 300 |

Prices do not move, so no Stripe price is touched and `verify_plans` keeps
passing. Nothing is migrated: `Quotas.sandbox_limit/1` resolves the cap from
`users.plan` on each request, so the new numbers apply at the next deploy and
an operator override still beats them.

**This lowers the cap on existing accounts, which the original ladder never
did.** The 2026-08-22 changeover was written so that nobody lost capacity;
this one is a deliberate reduction, and a tenant sitting above their new cap
keeps the sandboxes they have and is refused the next start. The lever for an
account that needs the old number is `sandbox_limit_override`, per account,
which is what it is for.

**The trial now ties Solo rather than sitting below it.** The section above
argued that a trial carrying its tier's full numbers gives a converting
customer nothing on the day they pay. At 2 concurrent on both, that is again
true for the *bottom* tier specifically: converting from the trial to Solo
buys the teammate contact and the removal of the clock, not more concurrency.
The invariant that replaces "smaller on every axis" is **never larger than a
plan somebody pays for** — enforced as `<=` in `plans_trial_test.exs`, which
still leaves the trial strictly below Team and Scale because the public caps
climb strictly. Contacts stay strictly below Solo, and that assertion is
pinned separately: if that ties too, a free trial and a paid Solo are the same
product with a clock on one of them.
