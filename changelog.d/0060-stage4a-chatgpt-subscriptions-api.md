### Upgrade notes

- **One additive migration, no operator action** (#2459). `20260921060000`
  creates `chatgpt_link_attempts`, one row per ChatGPT sign-in an account
  has begun. It is empty until somebody links a subscription, its rows are
  deleted with their account, and rolling it back drops it. A new Oban
  queue, `chatgpt`, polls the sign-ins ten at a time; it needs no
  configuration and is idle while there are none.

- **`chatgpt_subscriptions` is a new feature flag, and it is off** (#2459).
  It holds the one door that links a new ChatGPT subscription to an account.
  Unlike `connections` it reads off on a deployment with no PostHog as well:
  the feature is in development (ADR 0060), with no console page, no
  schedule that keeps an idle subscription alive and two broker protections
  still to build. `FEATURE_FLAGS_ON=chatgpt_subscriptions` forces it on
  where the credential broker is configured; do not do that on an instance
  that serves people you do not trust. See
  https://managoat.com/docs/reference/feature-status.

### Added

- **`/api/account/chatgpt-subscriptions`** (#2459): list, rename, disconnect
  and remove the ChatGPT subscriptions an account has linked for the `codex`
  runtime, and start, list, read and cancel the device-code sign-in that
  links or reconnects one. A full-scope key is required, another account's
  id is a 404, and no route returns or refreshes a token. An account may
  start ten sign-ins an hour, counted in the database across its API keys:
  the eleventh is `429 chatgpt_link_attempts_rate_limited` with
  `Retry-After`. `GET /api/auth/me` reports the gate as
  `chatgpt_subscriptions_enabled`. See
  https://managoat.com/docs/api#chatgpt-subscriptions.

- **A credential set names a ChatGPT subscription over the API** (#2459).
  `PATCH /api/account/inference-credential-sets/:id` takes
  `chatgpt_grant_id`, or `null` to stop naming one, and every set now reports
  `chatgpt_grant_id` and a read-only `chatgpt_grant` with the subscription's
  name and status. A named subscription is used or the codex run fails with
  `409 chatgpt_grant_unusable`; nothing is substituted.

- **`CHATGPT_GRANT_CEILING`** (#2459): how many ChatGPT subscriptions one
  account may link, `5` unless set. A link beyond it is `409
  chatgpt_grant_limit_reached`.

### Changed

- **The `Error` schema declares what `409 chatgpt_grant_unusable` already
  rendered** (#2459): `grant_id`, `grant`, `until`, and the values of
  `reason`. It also gains `count`, `attempt_id`, `state`, `sets` and
  `retry_after_seconds` for the new refusals. The OpenAPI contract and the generated TypeScript and Swift
  models are regenerated; no SDK's handwritten surface changed.

- **`409 codex_inference_conflict` says who is exempt** (#2459). A credential
  set that names a ChatGPT subscription shares a sandbox with any other
  Codex source, on a sandbox first bound since subscriptions had a Codex home
  of their own. The behaviour is #2457's; the message, the schema and the
  configuration page now say so.
