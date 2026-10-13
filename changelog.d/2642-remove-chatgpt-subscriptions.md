### Upgrade notes

- **ChatGPT subscriptions and the deployment's ChatGPT account are removed**
  (#2642). The codex runtime runs on an OpenAI API key only: a credential
  set's, an environment's or a vault's, or `PLATFORM_OPENAI_API_KEY`.
  Migration `20261013120000` clears each credential set's
  `chatgpt_grant_id`, so a codex agent on such a set runs on the set's OpenAI
  key, or has none. A conversation that ran on a subscription, or on the
  ChatGPT account at `/admin/inference`, keeps its history: it still lists,
  and its turns show `inference: null`. Its next prompt or wake is refused
  with `409 inference_source_changed`; start a new conversation. The grant
  tables, `inference_credentials.chatgpt_grant_id` and the `managed_*`
  columns of `broker_sessions` stay for one release so that a replica of the
  previous release keeps working during a rolling upgrade, and a later
  release drops them with the stored sign-ins. Fountain cannot revoke a
  sign-in at OpenAI. To end one now, sign the device out in the ChatGPT
  account's security settings.
- **`FEATURE_FLAGS_ON` and `CHATGPT_GRANT_CEILING` are no longer read**
  (#2642). `chatgpt_subscriptions` was the last feature flag, and
  `Fountain.FeatureFlags` is gone with it. Remove both from your
  configuration.
- **The `fountain_chatgpt_*` metrics are gone** (#2642): the refresh-lock
  contention counter, the keepalive sweep and job counters, and the refresh
  rate-limit and breaker counters. Remove alerts and panels that read them.
  The `chatgpt` and `chatgpt_refresh` Oban queues and the two daily
  keepalive jobs are gone too.

### Removed

- **`/api/account/chatgpt-subscriptions`** and its sign-in `attempts` routes
  (#2642). They answer `404`. `chatgpt_grant_id` and `chatgpt_grant` are
  gone from a credential set, and a `PATCH` that sends `chatgpt_grant_id`
  changes nothing. `chatgpt_subscriptions_enabled` is gone from
  `GET /api/auth/me`, and `chatgpt_grant_id` and the `grant` scope from a
  turn's `inference`. `409 chatgpt_grant_unusable` and the other `chatgpt_*`
  errors are gone.
- **The console's ChatGPT surfaces** (#2642): the ChatGPT subscriptions
  card and the set's subscription picker at `/account/inference-credentials`,
  the banners on `/start` and the agent form, and the ChatGPT account row at
  `/admin/inference`. The `admin.platform_chatgpt.*` admin events are no
  longer recorded; existing rows stay.

### Changed

- **`CODEX_CHATGPT_ACCESS_TOKEN` is an ordinary name** (#2642). An
  environment or vault secret, and a secret binding, may use it as a key or
  in its value. The credential broker no longer has a protected path for
  `chatgpt.com`: a request there is an ordinary request, credentialed only by
  a binding of yours.
