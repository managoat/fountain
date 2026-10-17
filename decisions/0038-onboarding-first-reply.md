---
type: ADR
title: "Onboarding is the path from verified to first reply, carried by the API"
description: "The primary audience is the developer integrating the API, and activation is the first conversation with a reply, through the API or the CLI's `auth register`."
tags: [onboarding, product, billing, inference, cli, analytics]
status: stable
adr: "0038"
adr_status: "Accepted"
date: 2026-09-02
generated: { by: human:jhgaylor, at: 2026-09-02T14:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-09-02T14:00:00-04:00 }
stale_after: 2026-11-02
---

# 0038 — Onboarding is the path from verified to first reply, carried by the API

**Status:** Accepted, 2026-09-02. Decisions 1, 2, 5 and 6 stand (5 without
its verified landing); 3, 4 and 7 are retired, and keep their numbers because
other ADRs cite them. Implementation was tracked under #1039.

## Context

#1039 asked what onboarding is before anyone built more of it, because what
existed had accreted: signup and verification, a welcome email, a three-item
dashboard checklist (a credential, an agent, a conversation), a docs index
box that installed the CLI and logged in, a guided tour that needed an API
key, a repository and a GitHub token, the SDK, the CLI, the catalog. Four
surfaces each described a different first hour and each ended by sending the
developer to one of the others.

On 2026-09-02 the funnel said 49 verified accounts, 40 of which created
nothing; 9 had ever started a conversation, 3 of them internal and the rest
friends. There was not yet an active user who was not the maintainer or a
friend, so the numbers could not judge a design. What could is a test anyone
can run: from a blank account with nothing but an email address, how long
until a reply.

The accreted path cost the developer before the product had done anything:
there was no zero-prerequisite hello world, since the shortest documented path
needed a repository and a GitHub token, and the first screen asked for an
inference key before there was anything to run.

## Decision

1. **The primary audience is the developer integrating the API.** The
   operator self-hosting and the person evaluating in ten minutes get a
   signpost from the path, not a path of their own.

2. **Activation is the first conversation with a reply**, from any door: the
   developer's own code, the SDK, the CLI, or a client app. A conversation
   with no reply does not count. The number the path is judged on is the time
   from verification to first reply. Nothing measures it across accounts any
   more (see History).

3. *Retired 2026-10-15.* The deployment held platform inference keys and ran
   an account with no credential of its own on them
   ([0075](0075-no-deployment-paid-inference.md) removed them). A tenant with
   no credential has none to run on.

4. *Retired 2026-10-15.* Every verified account got a default `starter` agent.
   Verification no longer plants one.

5. **The path is a key and one request, and the API carries it.** There is
   one first request, `curl` and the SDK equivalent, from one source:
   `apps/fountain/priv/first_request/`, read at compile time by
   `Fountain.FirstRequest`, included in `docs/quickstart.md` and served as
   `first_request` in `GET /api/catalog`. The quickstart creates an agent with
   `POST /api/agents` before it, since a new account has none.

6. **The CLI is the second door, and it does the steps rather than describing
   them.** `managoat auth register` creates the account through
   `POST /api/auth/register`, waits for verification by polling the token
   endpoint until it stops answering `email_unverified`, saves the key and
   prints the same first request; `managoat quickstart` sends it to the first
   agent the account lists, and says so when there is none. The CLI reaches
   the request text over the wire through `GET /api/catalog`, because Go
   cannot read the server's files and a build-time copy would be the second
   copy this is meant to prevent. The wait is nine attempts over ten minutes,
   shaped by the ten-per-hour limit on `POST /api/auth/token`. The CLI is not
   required for the path, since installing anything is a cost the primary
   audience should not pay to see a reply.

7. *Retired 2026-10-13.* `onboarding_completed_at` was the one onboarding
   field, stamped at first reply. Nothing writes it any more, and the column
   was dropped on 2026-10-13 (`20261013200000_drop_vestigial_columns`).
   `users.onboarding_state` was dropped (#1393), which settled NC-6 from
   [0007](0007-g3-launch-go.md).

## Consequences

- **The console does not onboard.** A verified person lands on `/dashboard`;
  the API, the docs quickstart and the CLI carry the first hour.
- **A new account starts empty.** It has no agent and, on a deployment with
  no inference keys of its own, no credential; the first run needs both from
  the developer. [0075](0075-no-deployment-paid-inference.md) records that a
  refusal at admission for a run with no credential is not built.
- **The CLI doing sign-up makes bot sign-up easier** than a form with a
  browser in front of it. The rate limits and anti-enumeration rules on the
  two endpoints apply, and registration closes after the first admin unless
  the operator sets `REGISTRATION_ENABLED=true`
  ([0011](0011-self-host-first-admin-bootstrap.md)).

## Alternatives considered

- **Onboarding is docs.** Docs describe; they cannot run the first request.
- **The CLI as the primary carrier.** It can do steps rather than describe
  them, which is why it is the second door, but it requires an install, the
  Linux install had a known trap (#1327), and a developer evaluating an API
  should be able to see a reply without installing anything.
- **The console checklist, kept and improved.** It defined done as "three
  things exist", which is not activation, and it sent the third item to a
  different origin to click a button.
- **A read-only demo agent on the deployment's key, no metering.** The
  developer would activate on a toy and stall on their own agent.
- **"Connect your Claude account" instead of platform keys.** Obtaining the
  `claude_code_oauth_token` credential is a paste after a CLI login on
  Anthropic's side, not an OAuth flow Managoat can start; a better paste step,
  not the removal of the step.
- **Do nothing until strangers arrive.** The number would still be
  unmeasured when they did.

## History

- 2026-09-02 — Decided: seven decisions, among them platform inference keys
  metered against the opening credit (amending
  [0008](0008-byo-inference-credentials.md)), a starter agent planted at
  verification, a verified landing at `/start`, and `onboarding_completed_at`
  stamped at first reply (#1388–#1393, #1426, #1443).
- 2026-09-03 — Walked on production on a platform key: verification to first
  reply in 35 seconds (14 the sandbox, 5 the model, 16 a human copying the
  request).
- 2026-09-07 — Platform keys made settable from `/admin/inference`.
- 2026-10-12 — With no hosted service, the activation measurement
  (`Fountain.Funnel`, `Fountain.Activation`, the PostHog events,
  [0025](0025-product-analytics-in-posthog.md)) is removed; with credits gone
  ([0031](0031-credits-are-the-product.md)), platform inference is unmetered
  and has no daily ceiling.
- 2026-10-13 — The verified landing `/start`, the welcome email, the
  unverified-account pruner, `Fountain.Onboarding` and the stamp are removed;
  the snippet half became `Fountain.FirstRequest`.
- 2026-10-14 — Closed registration after the first admin, not the balance
  gate, keeps strangers off platform keys; platform keys are offered only on a
  brokered deployment, so the deployment's key never enters a sandbox.
- 2026-10-15 — Platform inference retired by
  [0075](0075-no-deployment-paid-inference.md).
- 2026-10-15 — The starter agent retired: the person who verifies is almost
  always the operator who installed the instance; on production it had been
  planted in three accounts and run one conversation. Existing starter agents
  stay as ordinary agents, and their `system:onboarding` audit rows stay.
- 2026-10-15 — The first-request snippets moved from `docs/snippets/` to
  `apps/fountain/priv/first_request/` ([0081](0081-the-manual-is-a-static-build.md)).
- 2026-10-17 — Decision 7 records that the `onboarding_completed_at` column has been dropped.
