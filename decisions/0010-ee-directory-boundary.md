---
type: ADR
title: "Top-level `ee/` directory boundary for billing and transactional email"
description: "Retired 2026-10-12: ee/ and everything in it were deleted when Fountain became self-hosted only. Billing and billing-adjacent growth mail live in a top-level ee/ directory compiled into the same OTP app; the license change and the core/ee seam are not yet built."
tags: [licensing, ee, billing]
status: deprecated
adr: "0010"
adr_status: "Retired"
date: 2026-08-04
generated: { by: human:jhgaylor, at: 2026-08-07T02:39:02-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-07T02:39:02-04:00 }
---

# 0010 — Top-level `ee/` directory boundary for billing and transactional email

**Status:** Retired 2026-10-12; see the addendum at the end. The text above the addendum is history. Was: Accepted (documents the file move built in the PR that adds this
ADR; the license change and the core/ee seam are explicitly **not yet built**
— see "Not done yet" below). **Scope narrowed by the 2026-08-05 addendum at
the bottom: account email returned to core; ee/ is billing + billing-adjacent
growth mail.**

## Context

Fountain is MIT-licensed end to end. Billing (the Stripe integration) and
transactional email are hosted-SaaS concerns that we intend to license
differently from the core product in the future. Nothing in the repo marked
that boundary: billing was a core context like any other, and every
transactional email lived in one shared module. Before a license split is
possible, the code has to live behind a directory line that a LICENSE file
can apply to.

## Decision

**A top-level `ee/` directory, compiled into the same `:fountain` OTP app.**
GitLab-style: `ee/lib` and `ee/test` are appended to `apps/fountain`'s
`elixirc_paths` and `test_paths`. There is no second umbrella app, no
behaviour indirection, and no conditional compilation.

**Scope:** all of billing (context, usage-event schema, Stripe webhook
controller, billing LiveView, billing Oban workers, `fountain.verify_lifecycle`)
and **all** transactional email (`Fountain.Mailer`, `Fountain.Emails.UserEmails`,
every email Oban worker, the unverified-account pruner, the email verification
controller) — not just the signup-verification flow.

**Module names change nowhere.** Only file paths moved. This is the central
risk control: Oban cron/queue config, `Mimic.copy` lists, the router, and
`config :fountain, Fountain.Mailer` all reference modules by name and were
untouched.

**This pass is move-only.** Core code keeps calling `Fountain.Billing`,
`Fountain.Emails.UserEmails`, etc. directly (conversation gates, registration
enqueues, admin pages, funnel stages). That is permitted and expected while
everything is one app under one license.

Two placement calls worth recording:

- `FountainWeb.CachingBodyReader` **stays core** even though its only consumer
  is Stripe signature verification: it is compile-time-wired into
  `endpoint.ex` as `Plug.Parsers`' body reader, and it is generic raw-body
  infrastructure. Moving it would make a future core-only build fail at the
  endpoint.
- `FountainWeb.Live.BillingLive` **moved wholesale** even though it also hosts
  the account export/deletion UI (core functionality). Splitting it meant
  route/template surgery — behavior-change risk this pass deliberately avoids.
  The handlers already delegate to core `Fountain.Exports` /
  `Fountain.Accounts.Deletion`, so the later split is mechanical.

## Not done yet (deliberately)

Per the repo rule that ADRs must not describe unbuilt behavior as existing:

- **The license change.** `ee/LICENSE` is today a byte-for-byte copy of the
  root MIT license. Public docs (`README.md`, `docs/self-hosting.md`) still
  say "Fountain is MIT licensed" and are still correct.
- **Dependency-inversion seams / core-only build.** Core does not compile
  without `ee/`; billing gates have no always-allow default; there is no
  community-build CI job.
- **BillingLive export/deletion extraction** (the impurity above).
- ~~**Sobelow coverage of ee web modules.**~~ Closed in the follow-up PR:
  `scripts/sobelow.sh` (used by `mix precommit` and CI) assembles a temporary
  merged tree — core `lib` with `ee/lib` overlaid — and scans that, restoring
  the exact pre-move scan. The script fails on any core/ee path collision
  rather than letting one file shadow the other.

## Consequences

- **The Dockerfile must `COPY ee ./ee`.** Mix silently skips missing
  `elixirc_paths` directories, so a build context without `ee/` produces a
  release that compiles and boots but is missing billing/email modules and
  fails at runtime. The release boot check and docker build are the guards.
- `mix test <path>` for ee files resolves only from `apps/fountain`
  (`mix test ../../ee/test/...`) or with an absolute path; root-relative
  paths do not match.
- ~~ExCoveralls reports ee modules with absolute paths (its `Path.relative_to`
  is against the app cwd). Cosmetic; `coveralls.json` skip regexes are
  unanchored and still match.~~ Moot since #620 replaced ExCoveralls with
  built-in cover, which excludes by module name and so never sees a path.
- Historical ADRs (notably 0006) reference pre-move file paths; they describe
  the state at their time and are not rewritten.

## Addendum — 2026-08-05: scope narrowed to billing + growth mail (#475/#476)

The original scope put **all** transactional email in ee/. The retrospective
the same day settled two product positions that changed the calculus: Fountain
ships a **single image** (no separate community/ee artifacts planned), and a
community instance must never depend on ee/ for anything it actually needs.
Password reset living behind a possible future ee license failed that test.

What moved back to core (#475, #476):

- `Fountain.Mailer` and the account templates in `Fountain.Emails.UserEmails`:
  verification, password reset, suspended/unsuspended, deleted, email-change
  confirmation/notice.
- `EmailVerificationController` and the `verification_email`,
  `email_change_email`, `account_email`, `unverified_account_pruner` workers.

What ee/ holds now: the Stripe billing surface, and billing-adjacent/growth
mail — `Fountain.Emails.BillingEmails` (welcome, trial ending/expired, the
four payment-lifecycle emails, subscription canceled) with the
`welcome_email`, `trial_ending_email`, `lifecycle_email`,
`stripe_customer_sync` workers. `BillingEmails` borrows the now-public
`UserEmails.from_address/0` / `support_phrase/0` so the mail surface keeps
one sender and one support-contact policy.

One framing correction, per the same retrospective: this boundary
**preserves the option** of licensing ee/ differently; it is not a plan of
record. Everything remains MIT until an explicit license decision says
otherwise.

> **Settled by 0027 (2026-08-22).** That decision exercised the option this
> ADR preserved: `ee/` is now under the Elastic License 2.0 and the server is
> AGPL-3.0-or-later. The "Not done yet" note above, that `ee/LICENSE` is a
> copy of the root MIT license and that the public docs correctly say MIT,
> described the state on 2026-08-04 and is no longer true. See
> [`0027-agpl-relicensing.md`](0027-agpl-relicensing.md).

## Addendum — 2026-10-12: retired, `ee/` is gone

Fountain is no longer sold as a hosted service. It is a self-hosted
application, and billing went with the hosted business. Everything this ADR
put under `ee/` was deleted rather than moved: `Fountain.Credits` and its
ledger, `Fountain.Billing` (the balance gate, finance and reconciliation),
the Stripe webhook and the credits API, `/account/billing`, `/admin/finance`,
the credit workers and the credit emails. The `stripity_stripe` dependency,
`ee/LICENSE`, `ee/README.md` and `ee/test` went with them.

What `ee/` had borrowed from core stays in core, where it already lived or
was moved before the deletion: `Fountain.Usage` (the `usage_events` table),
`Fountain.Machines.Usage` (the sandbox cost on `/admin` and
`/admin/sandboxes`) and the account emails in `Fountain.Emails.UserEmails`.

There is no longer a second licence in the repository, and the build no longer
overlays a second source tree: `elixirc_paths`, the test paths, the sobelow
overlay, the test partitioner and the Dockerfile name no `ee/` path.
