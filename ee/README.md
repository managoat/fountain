# Fountain EE

Code in `ee/` is compiled into the same `:fountain` OTP app as everything
under `apps/fountain` (wired in via `elixirc_paths` / `test_paths` in
`apps/fountain/mix.exs`), but sits behind a directory boundary that
carries its own license, GitLab-style. **`ee/` is under the Elastic License
2.0** (`ee/LICENSE`); the server under `apps/fountain` is AGPL-3.0-or-later
(root `LICENSE`). You may run `ee/` in your own instance for free and keep
your changes private; you may not offer it to third parties as a hosted
service. See `decisions/0027-agpl-relicensing.md`.

## Contents

- **Credits** — `Fountain.Credits` and its ledger, purchases, the pricer
  and expirer workers, `Fountain.Billing` (Stripe
  Checkout and the credit webhooks), the usage-event schema, the finance
  panel and the billing LiveView.
- **Credit and growth email** — `Fountain.Emails.BillingEmails` (welcome,
  credits low, credits exhausted) and the `welcome_email` and
  `credits_email` workers.

Account email (verification, password reset, suspension/deletion notices,
email change) and `Fountain.Mailer` are **core** — a community instance must
never depend on ee/ for mail it actually needs (#475/#476). See
`decisions/0010-ee-directory-boundary.md` and its 2026-08-05 addendum.

## Boundary status

Core currently calls these modules directly; dependency-inversion seams and a
core-only (ee-less) build are deliberately future work, not yet built.

Known impurity: `ee/lib/fountain_web/live/billing_live.ex` also hosts the
account export/deletion UI (core functionality) pending extraction.
