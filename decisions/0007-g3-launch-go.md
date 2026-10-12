---
type: ADR
title: "G3: Go for public launch"
description: "Retired 2026-10-12: Fountain is no longer sold as a hosted service. G3: go for public launch as of 2026-05-10 with gates G0 through G2 cleared; the 2026-08-03 addendum records what of the post-launch backlog was built."
tags: [gates, launch]
status: deprecated
adr: "0007"
adr_status: "Retired"
date: 2026-05-10
generated: { by: human:jhgaylor, at: 2026-08-03T13:41:32-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-03T13:41:32-04:00 }
---

# 0007 — G3: Go for public launch

**Status:** Retired 2026-10-12; see the addendum at the end. The text above the addendum is history. Was: Accepted — 2026-05-10.

## Context

All four gates have been cleared:

- **G0** — Option B (API + Hosted UI + Self-Serve Onboarding) chosen.
- **G1** — Press-release narrative locked.
- **G2** — Architecture and engineering plan locked (26 open questions resolved).
- **G3** — Release validation complete. Two critical bugs (BUG-1: missing CLI token endpoint; BUG-2: onboarding redirect path 404) were identified and fixed before this gate. Ten non-critical issues were logged for the post-launch backlog.

Validation report: `plan/phase-3-release-validation/validation-report.md`.

## Decision

**Go.** Fountain is cleared for public launch as of 2026-05-10.

## Launch checklist (operator actions before flipping traffic)

1. Set all `sync: false` env vars in the Render dashboard: `MASTER_SECRETS_KEY`, `DATABASE_URL`, `SMTP_*`, `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET`, `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, `STRIPE_WEBHOOK_SECRET`, `SPRITES_TOKEN`, `FOUNTAIN_DOMAIN`.
2. Create a Stripe product and at least one price in the Stripe dashboard; set the price ID in app config.
3. Register the Stripe webhook endpoint (`POST /api/stripe/webhook`) in the Stripe dashboard for events: `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`.
4. Register the GitHub OAuth app; set the callback URL to `https://<FOUNTAIN_DOMAIN>/auth/oauth/github/callback`.
5. Run `mix ecto.migrate` via Render’s `preDeployCommand` on first deploy (already wired).
6. Verify `POST /api/auth/token` + `fountain auth login` end-to-end with a test account before opening registration.
7. Set `users.role = "admin"` on the operator account directly in the DB after first registration.

## Post-launch backlog (non-blocking, first sprint)

- NC-1: Dark mode implementation
- NC-4: `Billing.sync_subscription/1` unit tests
- NC-5: `BillingLive` LiveView tests
- NC-6: Standardise `onboarding_completed_at` vs `onboarding_state` — **done** (#1393, [0038](0038-onboarding-first-reply.md)): `onboarding_state` is dropped and the stamp is the one field.
- NC-9: `usage_events` user-deletion handling
- NC-2, NC-3, NC-7, NC-8, NC-10: cleanup and coverage gaps

## Consequences

- The success metric is 100 weekly active users by month 6 (2026-11-10).
- The product-analyst and growth-marketer roles are now available for post-launch measurement and growth experiments.
- Revisit org/team features (deferred per [ADR 0003](0003-direction-option-b-api-ui-onboarding.md)) once solo-user multi-tenancy is validated.

## Addendum — 2026-08-03

The launch happened and the metric clock started 2026-05-10; the **launch
checklist above is historical** and must not be followed for any future
deployment:

- **The platform is not Render.** Production moved to the home-cloud k3s
  cluster (deployed via Flux; see `k8s/` and `docs/`). There is no Render
  dashboard to set env vars in and no `preDeployCommand` — migrations run
  automatically at release boot.
- **`STRIPE_PUBLISHABLE_KEY` is read by nothing.** It predates the hosted
  Checkout flow; setting it does nothing.
- **The webhook event list in step 3 is incomplete.** The handler also
  processes `checkout.session.completed` (checkout completion / customer
  adoption) and `customer.subscription.trial_will_end` (trial-ending mail).
  An endpoint registered with only the three events listed above silently
  loses both. The authoritative five-event list lives in
  `docs/integrations/stripe.md`, which is kept current.

Of the post-launch backlog: NC-1 (dark mode), NC-4 and NC-5 are built and
tested; NC-9 was handled by the `nilify` migration for `usage_events`;
NC-6 remains open.

## Addendum — 2026-10-12: retired, the launch metric is withdrawn

Fountain is no longer sold as a hosted service (2026-10-12). The public launch
this ADR cleared did happen, so the decision stands as history, but nothing
in it still governs:

- **The success metric is withdrawn.** There is no 100-WAU target for
  2026-11-10, and no product-analyst or growth role to measure one: PostHog
  analytics, the funnel and the activation metrics were removed (ADR 0025,
  retired).
- **The Stripe steps of the launch checklist describe code that no longer
  exists.** Credits, Stripe and `/api/stripe/webhook` were removed (ADR 0010,
  0030, 0031, retired). The 2026-08-03 addendum above points at
  `docs/integrations/stripe.md` for the webhook events; that page was deleted
  with them.
- **Org/team features are not planned.** The consequence above that they be
  revisited once solo-user multi-tenancy is validated no longer applies; see
  the [ADR 0003](0003-direction-option-b-api-ui-onboarding.md) addendum.

How to deploy an instance is in the manual (`/docs`), not here.
