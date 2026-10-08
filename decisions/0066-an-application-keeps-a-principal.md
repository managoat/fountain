---
type: ADR
title: "An application keeps a principal for a customer who never registers"
description: "Proposed, unbuilt: an application claims its own principal, which ends the expiry, funds the principal from the application's ledger and lets the application renew its credential; and a principal may hold a ChatGPT subscription that its current owner links on the customer's behalf. Amends 0044 (an application claiming its own principal is the intended path, documented and tested, not an accident of the eligibility check) and 0060 (the owner predicate answers through a principal's current owner). Neither change is built."
tags: [api, security, billing, accounts, inference, apps]
status: draft
adr: "0066"
adr_status: "Proposed"
date: 2026-10-07
---

# 0066 — An application keeps a principal for a customer who never registers

**Status:** Proposed, 2026-10-07. Nothing described here is built. The one
path that already works, an application claiming its own principal, works by
omission: no check refuses it, and nothing documents or tests it as intended.

## Context

[0044](0044-claimable-principals.md) built claimable principals for one shape:
an anonymous visitor who may register with Fountain later.
[0053](0053-inference-credential-sets.md) decision 7 then made principals the
answer for every business with many customers: sets are not a tenancy
mechanism, "a business with many customers gets principals, not sets".
[0060](0060-many-user-chatgpt-subscriptions.md) kept a principal out of the
ChatGPT grant table.

An application whose customers never register with Fountain is a different
shape, and it is the shape of the first app built on Fountain. Ravix's own
ADR 0005 (`decisions/0005-each-person-brings-their-own-agent.md` in
ravix-hq/ravix, read 2026-10-07) cites 0053 decision 7, considers one
principal per person, and rejects it in one line: principals "expire
unclaimed after seven days, and nobody here has a Fountain login to claim one
with." Ravix put every customer on one account with inference credential sets
instead, built admission, allowlist and credential-recovery layers to
multiplex that account, and on 2026-10-07 opened a pull request that leaves
Fountain for a sandbox it owns (ravix-hq/ravix#494). The same reasoning
applies to the next app.

Three facts about principals as built produce that rejection:

1. **An unclaimed principal expires.** `expires_in` defaults to 24 hours and
   is capped at 7 days (`Fountain.Principals.settings/0`).
   `ClaimablePrincipalSweep` closes overdue grants every five minutes:
   credential revoked, compute stopped, unspent lot refunded to the
   application. There is no renewal route for an unclaimed principal.
2. **A claim needs a registered account, and nothing says the application
   cannot be it.** `Principals.claim/4` takes the authenticated user as the
   claimer and refuses a principal, an unverified or suspended account, and
   one that cannot spend. It does not refuse the application that opened the
   principal, and the application holds the claim token it was handed at
   create. So an application can keep a principal today. 0044 does not
   describe this, the guide does not mention it, no test asserts it, and the
   openapi description of the claim route does not say it. It is an accident
   of the eligibility check, and an accident is not something an app can
   build on.
3. **A principal cannot hold a ChatGPT subscription.**
   `ChatGPTAccounts.eligible_owner_filter/0` is "not a principal, verified,
   not suspended", applied at the link door, on rename, and in every read
   that resolves a grant for a turn. 0060 records this in decision 7 of its
   stage 4: a principal holding a full key gets 403
   `chatgpt_owner_ineligible`. A pasted API key or a Claude subscription
   token reaches a principal through the owner write 0053 decision 7 built
   (`PUT /api/claimable-users/:id/inference-credentials/:provider`). The one
   credential that is a sign-in rather than a secret does not.

For an app whose customers bring their own ChatGPT subscription, which is
the Ravix product, the third fact alone disqualifies principals. The first
two make every other customer a week-long tenant.

## Decision

**An application may keep a principal by claiming it.** Claiming by the
application account that opened the principal is the intended path for a
customer who will not register, not a loophole. `principal_owners` records
the application as owner, the row's status is `claimed`, and the expirer
never sees it again. Everything 0044 built for a claimed principal then
applies unchanged. `Principals.billing_subject_id/1` resolves to the
application, so turn-hours and every other credit spend after the claim land
on the application's ledger rather than on the capped introductory lot. The
application renews the principal's credential by principal id under the
existing 30-day key expiry; 0044 decision 6 and its database CHECK are not
touched. `put_inference_credential/5` keeps working for the claiming
account. Deleting the application deletes its principals. The
outstanding-principal cap and the creation rate limit keep bounding
unclaimed principals; a kept principal is bounded by the application's
balance and sandbox cap, as a claimed one is today. What changes is the
record: the guide gains a "keep it" section beside "claim it", the claim
route's openapi description says the application may be the claimer, and a
test pins that a self-claim succeeds, resolves billing to the application and
is never expired.

**A principal may hold a ChatGPT subscription that its current owner links.**
The grant row's `user_id` is the principal. The actor is the principal's
current owner, holding a full-scope key, and must itself pass today's owner
predicate: verified, unsuspended, not a principal. A new owner-scoped route
under `/api/claimable-users/:id/chatgpt-subscriptions` starts the device-code
link on the principal's behalf and returns the code the application shows
its customer; completion, listing, rename, disconnect and removal take the
same owner scoping `put_inference_credential/5` uses (the opening application
while unclaimed, the claiming account after), and the `chatgpt_subscriptions`
rollout flag is read on the owner. Where a read asks today whether a grant's
owner may use it, in the join behind `eligible_owner_filter/0`, in the
suspension gate on a turn and in the keepalive's selection, a principal
answers through its current owner: a principal's grant is usable when the
principal is unsuspended and its owner passes the predicate, and an unclaimed
principal's owner is the application that opened it. Custody and transport do
not change. One `CODEX_HOME` per grant and generation, the per-request broker
check against the durable generation, coordinated refresh, the daily
keepalive, exhaustion recorded when OpenAI confirms it, and the grant's place
in export and deletion are all keyed on the grant's `user_id`, and that is
the principal. 0060's rule that a grant is owned by exactly one user and is
never inherited by an owned principal stands: the principal holds its own
grant, and the application's own grants serve only the application.

Neither change moves ownership later. A customer who registers with Fountain
after their application kept a principal does not take it over: 0044
rejected resource transfer, and a claimed principal cannot be claimed again.
That handover, if an application ever asks for it, is a separate decision.

## Consequences

- An application becomes the long-term funder and operator of as many
  principals as it has customers. The console still has no word for an owned
  principal ([#1566](https://github.com/managoat/fountain/issues/1566)), so
  an application with two thousand customers operates two thousand tenants
  through the API alone. That was already true of a claimed principal; the
  number grows.
- The per-tenant finance table lists every principal that ran turns, with the
  application as billing subject. The activation funnel and the account
  counts already exclude principals (0044, consequences).
- Suspending an application stops its principals' ChatGPT turns, because the
  predicate answers through the owner. Suspending one principal stops only
  that principal. Credit exhaustion on the application refuses every
  principal it funds, at the same spend doors as today.
- The ChatGPT eligibility predicate becomes a join through
  `principal_owners` for a principal row: one more indexed lookup on a path
  that today reads a flag on the user row, skipped for an ordinary account
  the way `billing_subject_id/1` is.
- A customer's refresh token lives on the principal's row under the
  principal's DEK, and the application never sees it: the application holds
  a device code and a principal id. That is the custody 0060 built, applied
  one tenant down.
- A principal's grant counts under no account-wide ceiling. 0060 removed that
  ceiling for users, and this ADR does not reintroduce one for principals.
  Abuse is bounded by the outstanding cap, the rate limit and the
  application's balance, as 0044 bounds anonymous compute.
- The three Fountain-shaped layers Ravix built and then deleted (admission to
  a grant, a billing allowlist, credential recovery after a set's revision
  changed) are what an app has to build when its customers share one
  account. With one principal per customer none of them is needed, which is
  the argument 0053 decision 7 made and this ADR makes possible for a
  customer who never registers.

## What this does not decide

Transfer of a kept principal to a customer who registers later. A principal
switcher in the console (#1566). Whether the owner-scoped sandbox routes
that ADR 0065 proposes (on another branch) accept a `principal`-scoped key;
they should, since 0044 decision 2 leaves sandboxes inside that scope, and
0065 decides it.

## Alternatives considered

- **Raise or remove the unclaimed TTL.** Leaves the principal funded from a
  500-cent introductory lot on the wrong ledger, with no renewal of its
  credential, and still refuses a ChatGPT grant. It fixes the week and
  nothing else.
- **A sub-account or namespace under the application.** 0044 rejected a
  `principals` table beside `users` because every context is written against
  `user_id`; the same argument rejects a lighter sub-tenant.
- **One shared application account with a credential set per customer.**
  What Ravix built. 0053 decision 7 says sets are not a tenancy mechanism,
  and Ravix's exit document lists the admission, allowlist and recovery
  layers that followed, then deletes them.
- **Let the principal link its own subscription with its principal-scoped
  key.** The principal key cannot write account state by design (0044
  decision 2), and the customer never holds that key; the application does,
  and shows the device code in its own interface. Owner-scoped is the shape
  that already exists for the pasted credential.
- **Let the application hold the grant and lend it to its principals.** 0060
  forbids a grant serving any tenant but its owner, and the broker's
  per-request check and the `CODEX_HOME` custody are keyed on one user.
  Lending would reopen the many-grants-on-one-account problem this ADR
  exists to close.
