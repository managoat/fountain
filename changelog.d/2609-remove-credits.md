### Upgrade notes

- **Credits, Stripe and the `ee/` directory are removed** (#2609). Fountain
  no longer prices, grants, gates or sells anything. These variables are no
  longer read; remove them from your configuration: `CREDITS_ENABLED`,
  `STRIPE_SECRET_KEY` (as server configuration), `STRIPE_WEBHOOK_SECRET`,
  `CREDIT_OPENING_CENTS`, `CREDIT_OPENING_DAYS`, `CREDIT_TURN_HOUR_CENTS`,
  `CREDIT_PACKS_CENTS`, `PROVIDER_COST_BASIS`, `SANDBOX_RESERVE_CENTS`,
  `SANDBOX_CAP_FLOOR`, `PLATFORM_INFERENCE_DAILY_CENTS` and
  `PLATFORM_INFERENCE_RATES`. A deployment that had a Stripe webhook endpoint
  pointing at `/api/stripe/webhook` should disable it in the Stripe
  dashboard: the route now answers 404.
- **Usage on platform inference keys is unbounded** (#2609). There is no
  daily ceiling any more: every account without a credential of its own runs
  on the deployment's `PLATFORM_*_API_KEY`, billed to the deployment's
  provider account, with no 503 when a day's spend is high.
- **One migration drops three tables** (#2609): `stripe_events`,
  `stripe_webhook_failures` and `provider_invoices`, and it deletes the Oban
  jobs of the `credits` queue. `credit_ledger` and the `users` columns
  `credit_balance_cents`, `stripe_customer_id` and `comped` stay for one
  release, unread, so replicas still running the previous release keep
  working during a rolling deploy; a later release drops them.

### Changed

- **The per-account sandbox cap is `SANDBOX_CAP_CEILING`** (default 20), or
  the account's override when an operator set one (#2609). It no longer
  follows a balance. The fleet ceiling (`SANDBOX_FLEET_CEILING`) is
  unchanged.
- **`/terms` and `/privacy` are published only when all four `LEGAL_*`
  variables are set** (#2609), and no longer mention Stripe or credits. The
  placeholder pages a billing deployment served without them are gone.
- The release-task smoke check in CI runs
  `Fountain.Release.inventory_sandbox_metadata/0` (#2609).

### Removed

- **Billing and credits** (#2609): the `/account/billing` page, the
  dashboard's credit tile, `GET /api/account/billing`,
  `POST /api/account/billing/credits/checkout`, the Stripe webhook at
  `POST /api/stripe/webhook`, the opening credit, credit packs, the credit
  emails and their workers. No request is refused with
  402 `insufficient_credits` any more, and the `upgrade_url` error field is
  gone.
- **Comps and admin credit grants** (#2609): `POST
  /api/admin/users/:id/comp`, `POST /api/admin/users/:id/credits`, the comp
  button and the comped/billed filter on `/admin/users`. The admin user JSON
  no longer has `comped`, `has_stripe_customer` or `credit_balance_cents`,
  and `GET /api/auth/me` no longer has `comped`.
- **`/admin/finance`, the Finance tab and the Finance Grafana dashboard**
  (#2609). Its sandbox-time, provider and failed-email panels moved to the
  Ops dashboard. The `fountain.credits.*` and
  `fountain.stripe_webhook.failure.count` metrics are gone.
- **The platform inference daily ceiling** (#2609): the
  `platform_inference_unavailable` 503 and the ceiling on `/admin/inference`.
- `Fountain.Release.rebuild_credit_lots/0` (#2609).
