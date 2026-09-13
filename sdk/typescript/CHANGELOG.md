# Changelog

Notable changes to `@managoat/fountain-sdk`, published as
`@agentshit/fountain-sdk` up to 1.23.0. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

The SDK versions independently of the Fountain server. It talks to the REST
API, which is additive, so a given SDK release keeps working against later
server releases.

---

## [1.31.1] - 2026-09-13

### Fixed

- Classify `sandbox_unavailable` as `NotReadyError`, preserving the server's `Retry-After` delay for callers retrying a refused sandbox binding (#2049).

## [1.31.0] — 2026-09-11

### Added

- `Conversation.reapply()` calls `POST /api/conversations/{id}/reapply`: re-select a conversation's agent, environment and vault on the machine it is already running. The conversation, the transcript and the files on disk all stay. An omitted option keeps its selection, and `null` clears the environment override or the vault.

### Changed

- Generated types carry the new operation and its `ConversationReapplyRequest` body.

## [1.30.0] - 2026-09-11

### Added

- Generated types carry a conversation's `pending_requests`, the permission requests that outlived a turn and are still waiting for an answer. Each entry has the request id, the tool, the options the agent offered, when it was asked and when it expires.
- Generated types carry a turn's `waiting`, true when the turn ended with such a request still open.
- `permission_policy` accepts `ask_timeout`, a number of seconds a request that outlived its turn waits before it is denied. It is the one policy key whose value is a number rather than a verdict, so the value type is now a union of the verdict enum and a number.

## [1.29.0] - 2026-09-11

### Changed

- Generated types carry `queue` on a conversation create, and the `SandboxRequest` shape a queued start answers with (ADR 0042). At the tenant sandbox cap or the fleet ceiling, a start that sets `queue: true` gets 202 and a request id instead of 429 or 503.
- `/api/sandbox-queue` is deliberately not wrapped. The run handle promises an immediate conversation, and a queued start hands back a request first; reach the three routes over the raw HTTP client until a queued-run handle owns the polling and the cancellation.

## [1.28.0] - 2026-09-10

### Added

- Wire types for the OAuth client registry (#1125): `/api/oauth/clients` and
  `/api/oauth/clients/{id}`, plus `OAuthClient`, `OAuthClientRequest`,
  `OAuthClientUpdateRequest` and `OAuthClientListResponse`. The hand-written
  layer does not model these; registering an app is a once-per-app setup step
  a person does in the console or with `fountain oauth-client`, and the SDK's
  work starts with the API key the flow mints. Reach them through the raw
  client if you need them.

## [1.27.0] — 2026-09-10

### Added

- `conversations({labels})` filters a list by labels, sending one repeated `label` parameter per pair and combining them with AND.
- `Conversation#setLabels()` merges labels onto a conversation. A null value removes a key.
- Generated types carry a conversation's `labels`.

### Fixed

- A query value that is an array now expands into a repeated key rather than one comma-joined value.

## [1.26.0] — 2026-09-10

### Changed

- Generated types carry an agent's `runtime_command`, the shell line the new `acp` runtime launches inside the sandbox, and `acp` joins the runtime enum.
- `Agent["model"]` is `string | null`, and `AgentRequest["model"]` and `AgentUpdate["model"]` are optional and nullable. An `acp` agent needs no model, and clearing one is how an existing agent converts to that runtime. Code that assumed a string needs a null check.

## [1.25.0] — 2026-09-10

### Changed

- **The package is now `@managoat/fountain-sdk`.** Same library, same API, same
  version line: 1.25.0 follows 1.24.0. Update the dependency and the import
  specifier; nothing else about your code changes.

  ```
  npm remove @agentshit/fountain-sdk
  npm install @managoat/fountain-sdk
  ```

  `@agentshit/fountain-sdk` keeps every version it has ever published, so
  existing installs and lockfiles go on resolving. It will receive no new
  ones. The move follows the repository into the managoat organization
  (`decisions/0048`), which is also where the scope that publishes this
  package now lives.

## [1.24.0] — 2026-09-10

### Added

- Generated types cover the `Teammate`, `Schedule` and `Webhook` documents bulk apply now reconciles, the `unchanged` result action, and a webhook row's one-time `secret`.

## [1.23.0] - 2026-09-07

### Added

- Environment creation, update and response types expose `setup_timeout_seconds`
  (1–900, default 120) for bounded cold setup.

## [1.22.0] — 2026-09-07

### Changed

- Turn usage exposes adapter accounting source, version, scope and completeness.
  Metadata-only reports omit unmeasured input/output counters, so those fields
  are now optional. Check for missing counts before arithmetic; missing means
  unknown, not zero. Historical reports gain no invented accounting metadata.

## [1.21.1] — 2026-09-06

### Fixed

- Generated turn types expose model selection evidence: requested and effective models, selection status, evidence source, and failure details.

## [1.21.0] — 2026-09-06

### Added

- `vaults.secrets.update(vault, key, {expires_at})` changes advisory expiry without replacing the value. Null clears expiry; omission preserves it.
- `conversations({sandboxId})` filters by machine, alongside the existing root filter.

### Fixed

- Generated types describe field-validation and coded 422 refusals with a dedicated schema.

## [1.20.2] — 2026-09-06

### Fixed

- Generated operation types include shared authentication, rate-limit and content-negotiation errors, plus documented controller refusals. Runtime request behavior is unchanged.

## [1.20.1] — 2026-09-05

### Added

- `me()` exposes `connections_enabled` separately from the account’s `brokered` status.

## [1.20.0] — 2026-09-03

### Changed

- `error.fieldErrors` now populates on a request the server rejected against
  its OpenAPI schema, not only on one a changeset rejected. Those two
  failures used to come back in different shapes — the schema validator sent
  an array keyed by JSON pointer, which this client read as `{}` — so a
  caller was told the request was invalid and not which field, on exactly the
  failures where the field is the only useful information. The server now
  sends one shape for every 422 (#1431). No API change here; the client got
  better because the wire did.
- `ChangesetError` gains an optional `error`, the code every Fountain error
  carries. On a validation body it is always `validation_failed`.

---

## [1.19.0] — 2026-09-03

### Changed

- `LogEvent.stage` is typed `string | null` rather than `string`. The server
  used to answer `""` for an event with no stage and no state, while its own
  schema declared `state` as one of `started done failed interrupted` or
  `null` — so `""` was a value the published contract did not allow, on the
  busiest read in the API. The server now renders `null` for both fields
  (#1430), which is what the schema always said for `state`; `stage` is typed
  nullable here to match. `LogEvent.state`'s type is unchanged, because the
  document already described it correctly and only the server was wrong.

  Code that reads `event.stage` on an event that has no stage now sees `null`
  where it saw `""`. This client's own readers were already null-safe. A
  falsy check (`if (event.stage)`) behaves the same either way; `event.stage
  .length` does not.

---

## [1.18.0] — 2026-09-03

### Added

- `GET /api/catalog` now carries `first_request`: the one onboarding request
  this deployment hands out (ADR 0038), as `curl` and as the TypeScript
  equivalent, with the prompt and the placeholders a client must still
  substitute. It is the same text the verified landing and the manual print,
  so a client that shows a first request no longer keeps its own copy to
  drift from. `fountain auth register` reads it from here (#1391).

## [1.17.0] — 2026-09-02

### Removed

- `onboarding_state` is gone from `AuthMe`, and `state` is gone from the
  onboarding response. Both were the browser wizard's position. The wizard
  went in #867, after which the field only ever said `step_1` or `completed`
  — which is what `onboarding_completed` and `completed_at` already say. The
  server dropped the column in #1393 (ADR 0038 makes `onboarding_completed_at`
  the one source of truth), so these types now match what the API sends.

  Nothing in the hand-written layer read either field, so this is a generated
  types change only. Code that read `me.onboarding_state` should read
  `me.onboarding_completed`; there is no replacement for a part-way step,
  because the server no longer records one.

- `GET /api/account/onboarding` and `POST /api/account/onboarding/complete`
  are unchanged and still work. Only the vestigial field went.

## [1.16.0] — 2026-09-02

### Changed

- `AuthMe` now types `id`, `email`, `role` and `email_verified` as always
  present. They always were: the server's `AuthMeResponse` schema listed
  `name`, `prefix` and `created_at` as required, three properties copied from
  the API-key schema that this response does not have, and
  `openapi-typescript` drops a required name with no property. The result was
  a response type with every field optional. The server schema now names the
  four fields `GET /api/auth/me` always renders, so the generated type does
  too (#1411).

### Added

- `npm run verify-contract`, which checks this client's declared wire
  dependencies against `sdk/contract/contract.json`, the projection of the
  server's OpenAPI document that all four SDKs now check against. `npm run
  generate` defaults to the same artifact, `dist/openapi.json`, instead of a
  path under `/tmp`.

---

## [1.15.0] — 2026-09-02

### Added

- A sandbox's disk, read-only (ADR 0039), beside `sandboxes()`,
  `sandbox(id)` and `resetSandbox(id)`: `sandboxFiles(id, path?)` lists a
  directory, `sandboxFile(id, path, { maxBytes })` returns one file
  (`content` is text or base64 per `encoding`, with `size` and
  `truncated`), and `sandboxDiff(id, { path, staged, ref, maxBytes })`
  returns `git diff`. The reads need a `full`-scope key, answer only for a
  `ready` sandbox (`sandbox_not_ready` otherwise — a parked one is not
  woken), are confined to `/home/sprite` and the runtime's workspace, and
  come back redacted like the transcript. There is no exec, by decision.
  Types `SandboxRecord`, `SandboxListing`, `SandboxEntry`, `SandboxFile`
  and `SandboxDiff` are exported.

## [1.14.0] — 2026-09-01

### Added

- `client.catalog()` now returns `mcp_servers` (#1322): remote MCP servers
  verified to complete the MCP authorization discovery chain, each with
  `slug`, `name`, `url`, `dcr` (whether the server registers a client for
  Fountain, RFC 7591) and `verified_on`, the date the chain last completed.
  Suggestions, not an allowlist — any URL can still be discovered through
  `client.connections.providers.create({ kind: "mcp", mcp_url })`. The
  field is absent on servers older than this release.

## [1.13.0] — 2026-09-01

### Added

- `client.connections.providers`: where connections get their tokens (#1186).
  `list()` (Google first, then the tenant's own), `get(id)`, `create(input)`,
  `update(id, patch)`, `delete(id)` and `discover(id)`. `kind: "oauth2"` is
  the tenant's own app registration at a service; `kind: "mcp"` takes only
  `mcp_url`, and Fountain discovers the authorization server (RFC 9728 /
  8414) and registers a client there (RFC 7591) where it can. Each provider
  carries the `redirect_uri` to register at the service, the `env_key` its
  tokens are brokered under and the `token_hosts` the broker attaches them
  to. `ConnectionProvider`, `ConnectionProviderInput` and
  `ConnectionProviderPatch` types.
- `Connection.provider_id` (null for Google) and the `expired` status, for a
  provider that issues no refresh token.
- An agent attaches a remote MCP server with a connection:
  `{ linear: { type: "http", url: "https://mcp.linear.app/mcp", connection: "<id>" } }`.

### Changed

- **Breaking:** `client.connections.providers()` (a method) is now
  `client.connections.providers.list()`, and each entry is a full
  `ConnectionProvider` (`id`, `slug`, `platform`, `configured`, …) rather
  than the old `{provider, configured, scopes, env_key, connect_url}` row.

## [1.12.0] — 2026-08-31

### Added

- Generated types for device-authorization login (fountain #1305):
  `POST /api/auth/device` starts a grant (`DeviceAuthResponse` — the
  `user_code` a human types at the console's `/device` page, the
  `device_code` the machine polls with) and `POST /api/auth/device/token`
  polls it (`DeviceTokenRequest`), answering the RFC 8628 error vocabulary
  until approval mints the same `AuthTokenResponse` as
  `POST /api/auth/token`. This is the login path for accounts created with
  "Sign up with GitHub", which have no password to exchange.

## [1.11.1] — 2026-08-28

### Changed

- `DEFAULT_APP_URL` is now
  `https://fountain-conversations.demo.managoat.com/`. The conversations app
  moved there when the demo suite left `jakegaylor.com` for
  `*.demo.managoat.com`, and the old address stopped answering, so every deep
  link `conversationUrl()` built against the default pointed nowhere. Callers
  that pass `appUrl` or set `FOUNTAIN_APP_URL` are unaffected.

## [1.11.0] — 2026-08-25

### Added

- Generated types for the tool bridge on the OpenAI-compatible endpoint
  (fountain #1202): `tools` and `tool_choice` on the chat-completions
  request, `tool_calls` on the reply and `finish_reason: "tool_calls"`. The
  SDK still does not wrap `/v1`; the types follow the spec.

## [1.10.0] — 2026-08-25

### Added

- Generated types for the server's OpenAI-compatible endpoints (fountain
  ADR 0035, #1198): `POST /v1/chat/completions`, `GET /v1/models` and
  `GET /v1/models/{model}`, where the `model` is a Fountain agent. The SDK
  does not wrap them. It is for the real API, and any `openai` client
  already speaks these, but their request and response shapes now ship in
  `paths` for callers that want them typed.

---

## [1.9.0] — 2026-08-25

### Added

- Agent config versions, generated from the server's OpenAPI spec (fountain
  ADR 0029, #1051). `GET /api/agents/{id}/versions` lists an agent's config
  history newest first and `GET /api/agents/{id}/versions/{version}` returns
  one version with its full `config`; both are read-only. `Conversation`
  gains `agent_version_id` and `agent_version`, the version the conversation
  launched under (null for conversations that predate versioning; the number
  is resolved on the conversation list and get endpoints). Types only: the
  hand-written client does not yet wrap the new endpoints.

## [1.8.0] — 2026-08-25

### Changed

- `DEFAULT_BASE_URL` is `https://managoat.com`, the hosted Fountain's new
  domain (fountain#1177). The old host redirects, so an SDK pinned before
  this release keeps working; set `baseUrl` explicitly for a self-hosted
  instance either way.

## [1.7.0] — 2026-08-25

### Added

- `client.connections`: the provider accounts the tenant signed in to once,
  whose credentials Fountain holds (#1178). `list()`, `get(id)`,
  `providers()` (what the deployment can connect and the console URL that
  starts the flow) and `delete(id)`. Connecting is a browser round trip, so
  there is no `create`. An agent uses one by naming it in `mcp_servers`:
  `{ gmail: { connection: "<id>" } }`. `Connection` and `ConnectionProvider`
  types. Only for accounts the egress broker is on for.

## [1.6.0] — 2026-08-25

### Added

- `brokered` on `GET /api/auth/me`: whether the account runs behind the egress
  credential broker, so a client can label the mode without probing
  `/api/secret-bindings` (#1154).
- `BrokerUnavailableError`: the 502 from `/egress` carries a sentence in
  `message` and a stable `reason` word (`econnrefused`, `api_error_503`, ...)
  instead of an inspected server term (#1153).

### Changed

- `GET /api/conversations/:id/egress` needs a full-scope key; a sprite-scoped
  token gets `403 insufficient_scope` (#1152). The `networking_config`
  description says where `limited` is enforced.

## [1.5.0] — 2026-08-25

### Added

- Generated types for `GET /api/conversations/:id/egress`: what a brokered
  conversation sent out through the egress broker (ADR 0019 gate 4).

## [1.4.0] — 2026-08-25

### Changed

- `SecretBinding.auth_type` gains `substitute`, now the default shape: the
  broker replaces the secret's placeholder wherever it appears in a request to
  the bound host.

## [1.3.0] — 2026-08-25

### Added

- Generated types for `/api/secret-bindings` (list, create, update, delete,
  presets): which hosts a secret is attached to at the egress broker, and how
  (ADR 0019 gate 1b). Only answers on an account the broker is on for; 404
  `brokerage_not_enabled` otherwise. No client wrapper yet — use the raw
  types with `client.request`.

## [1.2.0] — 2026-08-25

### Added

- `GET /api/account/billing` `usage.credit_burned_cents`: what the ledger
  took this month (turns, rent, messages) — the charged number, where
  `usage.turn_hours` is the metered one. Null with billing off.

### Changed

- `usage.conversations` counts conversations that ran a turn in the month,
  deleted or not, rather than sandbox provisions; a conversation on a
  persistent home is now counted.

## [1.1.1] — 2026-08-25

### Changed

- `GET /api/account/billing` `period.end` is now the first instant of the
  next month (a half-open window) rather than `23:59:59` of the last day.
  Render the window as `end` minus a second.

## [1.1.0] — 2026-08-25

### Removed

- `GET /api/account/billing` no longer carries `period.source`: the window
  is always the calendar month (ADR 0031), so the field had one value.

## [1.0.1] — 2026-08-25

### Changed

- `FountainErrorCode` names `insufficient_credits` and `fleet_full`, which
  `errorForStatus` already mapped; the 402 message says the account is out
  of credit rather than lacking a subscription.
- `GET /api/admin/users` takes `comped` (boolean) in place of the retired
  `status` filter, and `sort` no longer offers `trial_end`; the billing
  endpoint's summary reads "Credit balance and current-month usage".

## [1.0.0] — 2026-08-25

### Changed

- Credits are the product (ADR 0031). `GET /api/account/billing` returns
  `comped`, `has_stripe_customer`, `sandbox_cap`, `period`, `credits` and
  `usage`; the subscription fields (`status`, `plan`, `trial_ends_at`,
  `current_period_*`, `cancel_at_period_end`) are gone.
- A `402` now carries `insufficient_credits` (mapped to
  `SubscriptionRequiredError`, kept under that name); a full fleet is
  `503 fleet_full` (mapped to `NotReadyError`).
- Admin user objects carry `comped` instead of `subscription_status`,
  `plan`, `trial_ends_at` and the period fields; `/api/auth/me` carries
  `comped`.

### Removed

- `POST /api/account/billing/portal`, `POST /api/account/billing/checkout`,
  `POST /api/admin/users/{id}/extend-trial`,
  `POST /api/admin/users/{id}/resync-stripe`. Buying credit is
  `POST /api/account/billing/credits/checkout`.

## [0.4.0] — 2026-08-25

### Removed

- `comped_contacts` on admin user objects. The Stripe teammate-contact
  add-on is retired; contacts are rented from the prepaid balance, and an
  operator who wants to give someone free numbers grants credit
  (`POST /api/admin/users/{id}/credits`) or comps the account.

## [0.3.0] — 2026-08-25

### Changed

- `plan.included_turn_hours` on `GET /api/account/billing` is now
  `plan.included_credit_cents`: what the plan puts into the prepaid balance
  each billing period, in cents. A plan is denominated in credit, not hours,
  so a change to the turn-hour price never changes what a plan includes.

## [0.2.0] — 2026-08-24

### Removed

- `usage.turn_hours_included` and `usage.turn_hours_remaining` on
  `GET /api/account/billing`. The allowance is gone: the plan's hours size
  the monthly credit grant (`plan.included_turn_hours`), and `credits` is
  what acts. `usage.turn_hours` stays.

## [0.1.15] — 2026-08-24

### Added

- `POST /api/admin/users/{id}/credits` adds prepaid credit to an account
  (`grant_admin`, never expires). Admin user objects carry
  `credit_balance_cents`.
- A `402 insufficient_credits` response (same shape as
  `subscription_required`, with `upgrade_url`) on every door that spends,
  once the operator turns enforcement on.

## [0.1.14] — 2026-08-24

### Added

- `POST /api/account/billing/credits/checkout` mints a one-time Stripe
  Checkout URL for a credit pack; `credits.packs_cents` on
  `GET /api/account/billing` lists the packs. Refused with
  `subscription_required` for a trialing account and `unknown_pack` for an
  amount that is not on sale.

## [0.1.13] — 2026-08-24

### Added

- `GET /api/account/billing` carries `credits`: the prepaid balance in
  cents, what expires and when, the purchased part, and the turn-hour
  price. It is `null` while the deployment has not started burning
  credits, so do not render a zero balance then. Nothing is refused at
  zero yet (ADR 0030).

## [0.1.12] — 2026-08-24

### Changed

- `PATCH /api/agents/{id}`, `DELETE /api/environments/{id}` and
  `DELETE /api/vaults/{id}` now carry a `409` response in the generated
  types. Each of those requests can move a persistent home's identity key,
  so the server retires the machine and refuses the request while a
  conversation on it runs a turn (#1084). `FountainError` already maps 409
  to `conflict`; the error body's `error` is `sandbox_mid_turn`.

---

## [0.1.11] — 2026-08-24

### Added

- `Sandbox.checkpoint` — `{ id, at }` or `null`: the checkpoint Fountain
  took of a persistent home the last time it parked, generated from the
  server's spec. It is scoped to that machine (ADR 0023, #1073).

## [0.1.10] — 2026-08-24

### Added

- `Turn.origin` — `"user"` for a prompt somebody sent, `"autonomous"` for a
  turn the server opened for a background cycle the agent ran after its
  prompt was answered (part 2 of BinaryBourbon/fountain#817). Generated from
  the server's spec; optional in the type because rows from before the field
  read as `user`.

## [0.1.9] — 2026-08-24

### Changed

- Generated types follow the server's Buzz identity schema: `sandbox_mode`
  on `POST /api/buzz/agents` and in the identity JSON (server #1070). No
  client method changed.

## [0.1.8] — 2026-08-24

### Added

- `resetSandbox(id)` — `DELETE /api/sandboxes/:id`: destroy a persistent
  sandbox (the agent's home) so the next launch on the same agent,
  environment and vault builds a clean machine; the conversations on it are
  kept. `sandbox_not_resettable` for an ephemeral or already-gone sandbox,
  `sandbox_mid_turn` while a conversation on it runs a turn (#1071).

## [0.1.7] — 2026-08-24

### Added

- `run({ sandboxMode })` — `"ephemeral"` or `"persistent"`, replacing the
  agent's default for that conversation. A persistent conversation lands on
  the agent's own machine, which Fountain makes on the first such launch;
  while that first launch is still building it, a second one gets
  `provisioning` (retryable). Agents carry `sandbox_mode` and sandboxes carry
  `mode`, both generated from the server's spec (ADR 0023).

## [0.1.6] — 2026-08-24

### Added

- `run({ sandbox })` attaches the new conversation to a sandbox you already
  have, by id, instead of provisioning one — several conversations then run
  on one disk at once (ADR 0023). `fountain.sandboxes()` and
  `fountain.sandbox(id)` list your machines with the conversations on each
  and which is mid-turn; `SandboxRecord` is their type. `Sandbox` records
  now carry `agent_id`, `environment_id` and `vault_id`.
- Error codes: `sandbox_not_found`, `sandbox_not_attachable`,
  `sandbox_identity_mismatch`, `sandbox_runtime_mismatch`, and
  `sandbox_at_capacity` (retryable — a one-at-a-time runtime's machine is
  busy with another conversation's turn).

## [0.1.5] — 2026-08-24

### Fixed

- No `User-Agent` header when running in a browser. Firefox lets a page set
  one, which turned every call into a CORS preflight asking for `user-agent`,
  and a Fountain whose allow-list did not name it refused the request ("CORS
  Missing Allow Header") — the first thing a signed-in single-page app saw.
  Node and other non-browser runtimes still send `fountain-sdk-js/<version>`.

## [0.1.4] — 2026-08-24

### Added

- `expires_at` on vault secrets, generated from the server's OpenAPI spec.
  `VaultSecretRequest` accepts it (ISO 8601 date-time, or `null` to clear a
  stored expiry) and `VaultSecret` returns it; a request that omits the field
  leaves the stored expiry alone. It is advisory metadata: the server emails
  the owner ahead of the date and enforces nothing on it, so an expired secret
  is still injected as-is. Values stay write-only.

## [0.1.3] — 2026-08-23

### Added

- Turn-hour types, generated from the server's OpenAPI spec (fountain ADR 0026,
  amended). `GET /api/account/billing` now reports what a plan includes and
  what the account has spent against it.

  - `plan.included_turn_hours` — turn hours the tier carries per billing
    period.
  - `usage.turn_hours`, `usage.turn_hours_included`,
    `usage.turn_hours_remaining`.
  - `current_period_start` beside the existing `current_period_end`.
  - `period.source` — `"subscription"` or `"calendar_month"`.

  A **turn hour is not a sandbox hour.** It counts time with a prompt in
  flight, so an agent left running with nobody talking to it spends
  `usage.sandbox_minutes` and none of the allowance. Do not present the two as
  the same unit.

  Read `period.source` before showing an allowance. `"calendar_month"` means
  the server has no invoiced period for that account (comped, self-hosted, or
  no subscription webhook yet), so the numbers do not line up with an invoice
  and a UI that implies they do will be wrong for exactly those accounts.

  Nothing is enforced against these numbers today — no request fails for
  exceeding the included hours.

All fields are optional and additive; nothing existing changed shape.

## [0.1.2] — 2026-08-23

### Added

- Subscription plan types, generated from the server's OpenAPI spec
  (fountain ADR 0026). `GET /api/account/billing` now returns a `plan` object —
  `slug`, `name`, `monthly_cents`, `concurrent_sandboxes`, `sandbox_limit` and
  `team_contacts` — and the checkout endpoint accepts a `plan` query parameter
  naming the tier to buy.

  Read `plan.sandbox_limit`, not `plan.concurrent_sandboxes`, when showing a
  customer how many agents they may run at once. The first is what the server
  actually enforces for that account; the second is the tier's number, and an
  operator override can make them differ.

- Admin account types carry `plan`, `sandbox_limit_override` and
  `comped_contacts`. `max_concurrent_sandboxes` keeps its name and its meaning
  — the cap in force — so nothing reading it breaks.

## [0.1.1] — 2026-08-23

No code change from 0.1.0. This is the first release published by CI through
npm's trusted publishing, so unlike 0.1.0 — which went out from a laptop — the
tarball carries a provenance attestation tying it to the workflow, the
repository and the commit that built it. Verify with `npm audit signatures`.

## [0.1.0] — 2026-08-23

First published release.

### Added

- `fountain.run(prompt, { agent, vault, environment })` — one call that
  provisions a sandbox, runs the agent in it and folds the log feed into an
  answer. `await` it, `for await` it, or read `.textStream`; all three are
  views of one run.
- `fountain.resume(id)` — the sandbox and the agent's session are still there,
  so a follow-up costs one prompt rather than a re-explanation.
- `agents`, `environments`, `vaults` — list, read, create, update, delete, and
  write-only secrets. All of them take a **name** where an id would do.
- `team` — teammates, their standing threads, and their routines.
- Streams that reconnect from a cursor, so a deploy mid-turn neither drops the
  answer nor replays it.
- Errors keyed on the API's `error` code rather than the status, because
  `conversation_busy` is a 400, `sandbox_quota_exceeded` a 429 and
  `provisioning` a 503, and what a caller does about each is unrelated to the
  number. Every error carries `retryable`.
- `run.answer(requestId, optionId)` and `resume(id).answer(...)`, with a
  `{ type: "permission" }` run event, for agents whose `permission_policy` has
  an `ask` entry.
- Types generated from the server's own OpenAPI document, with CI failing on
  any drift between the two.
- A browser entry with no Node built-in reachable from it, and a Node entry
  that adds `~/.fountain/credentials`.

[1.16.0]: https://www.npmjs.com/package/@agentshit/fountain-sdk/v/1.16.0
[0.1.1]: https://www.npmjs.com/package/@agentshit/fountain-sdk/v/0.1.1
[0.1.0]: https://www.npmjs.com/package/@agentshit/fountain-sdk/v/0.1.0
