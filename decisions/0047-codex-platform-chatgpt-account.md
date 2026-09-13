---
type: ADR
title: "Run the codex runtime on the platform's ChatGPT account"
description: "An admin signs the Fountain server in to ChatGPT once; the server keeps the rotating refresh token, the broker carries the access token to chatgpt.com, and a codex sandbox holds only a placeholder. Built and measured in #1755: four of the five G0 measurements pass, a codex turn has run on the grant through Fountain, and the idle-lifetime measurement is due 2026-09-17."
tags: [inference, broker, codex, security, billing]
status: draft
adr: "0047"
adr_status: "Proposed"
date: 2026-09-08
generated: { by: claude-fable/5.1, at: 2026-09-08T12:00:00-04:00 }
stale_after: 2026-10-08
---

# 0047 — Run the codex runtime on the platform's ChatGPT account

**Status:** Proposed, 2026-09-08. **Built and measured in #1755**, out of
the order the gates below prescribe: G1, G2 and G3 are in the code, and
four of the five measurements in [Measured](#measured) were taken on
2026-09-08 with a real ChatGPT Pro account, including a codex turn on the
grant through Fountain proper. What is still open is measurement 5, the
idle lifetime, due 2026-09-17; the PR that records it sets `verified` and
moves this to Accepted. Production connected on 2026-09-08 (a personal Pro
sign-in by device code, the operator's own risk as decision 8 and the docs
say) and ran its first turn on the grant the same hour; see G2 below.

Amends [0038](0038-onboarding-first-reply.md) decision 3 (platform inference
keys) with a second kind of platform credential, and
[0019](0019-egress-credential-brokerage.md) gate 3 (brokered inference
credentials) with a fifth `@inference` entry. Scope is the `codex` runtime
only. Opencode against an `openai/...` model keeps needing an API key.

## Context

### What we want

An admin signs the Fountain **server** in to ChatGPT once. Fountain keeps the
refresh token and owns its lifecycle. The egress broker carries the access
token to `chatgpt.com`. A sandbox running the `codex` runtime holds only a
placeholder. A tenant with no OpenAI credential of their own can then run a
codex agent on the deployment's subscription, metered like any other platform
inference (0038 decision 3).

### Why the Claude pattern does not transfer

The Claude OAuth credential is a long-lived static string from
`claude setup-token`, so gate 3 of 0019 exports it into every sandbox as a
placeholder and the broker substitutes it on `api.anthropic.com`. ChatGPT
has no such string:

- Codex's ChatGPT login is OAuth with a **rotating refresh token**, which
  the source and OpenAI's own guidance treat as single-use: the auth server
  names `refresh_token_reused` as a terminal error (measurement 3 found a
  reuse forks rather than revokes today; the guidance is still the contract
  to design against). OpenAI's CI guidance says one `auth.json` per runner, never shared
  across concurrent jobs. openai/codex#15502 and #15410 report the copy flow
  breaking for exactly this reason; #15410 was closed as not planned.
- Fountain runs many sandboxes per tenant concurrently, and several
  conversations share one sandbox (0023). The first one to refresh would
  kill every other copy.

So the refresh token must live in exactly one place, the server, and a
sandbox must receive something that never needs refreshing from inside.

### What Codex does with a ChatGPT login

Read from `openai/codex` `main` on 2026-09-08. Re-verify against the version
the sandbox images install (`codex --version` inside a sandbox; the review
image had 0.147.0 and production sandboxes ran 0.153.3 on 2026-09-06).

| Fact | Where |
|---|---|
| `auth.json` lives at `$CODEX_HOME/auth.json`, default `~/.codex`. In a Fountain sandbox that is `/home/sprite/.codex/auth.json` (`Managoat.Runtimes.Layout`). | docs, `layout.ex` |
| Three modes: `apiKey`; `chatgpt`, where codex owns the refresh token; and `chatgptAuthTokens`, "externally managed tokens": access token only, `refresh_token: ""`, codex never refreshes and never checks `exp`. `chatgptAuthTokens` loads from disk. | `codex-rs/login/src/auth/manager.rs` ~line 398 |
| JWT payloads are base64-decoded and never signature-checked. `id_token` must be three non-empty dot-separated segments; codex reads `email`, and under the `https://api.openai.com/auth` claim `chatgpt_account_id`, `chatgpt_user_id`, `chatgpt_plan_type`. The access token is parsed only in `get_chatgpt_account_user_id`, which swallows errors. | `codex-rs/login/src/token_data.rs` |
| Refresh is `POST https://auth.openai.com/oauth/token` with JSON `{client_id, grant_type: "refresh_token", refresh_token}`. Client id `app_EMoamEEZ73f0CkXaXp7hrann`. Terminal codes: `refresh_token_expired`, `refresh_token_reused`, `refresh_token_invalidated`; a 400 `invalid_grant` is also terminal. | `manager.rs` `request_chatgpt_token_refresh` |
| In `chatgpt` mode codex refreshes 5 minutes before the access token's `exp`, or when `last_refresh` is older than 8 days. Treat 8 days as the idle limit of the grant until measured. | `manager.rs` consts |
| Device flow on `https://auth.openai.com`: `POST /api/accounts/deviceauth/usercode` `{client_id}` returns `{user_code, device_auth_id, interval}`; the user approves at `/codex/device`; poll `POST /api/accounts/deviceauth/token` `{device_auth_id, user_code}` until 200 (403/404 mean not yet, 15 minutes max), which returns `{authorization_code, code_verifier, code_challenge}`; exchange at `/oauth/token` with `redirect_uri = https://auth.openai.com/deviceauth/callback`. The account must have device-code login enabled in ChatGPT security settings. | `codex-rs/login/src/device_code_auth.rs` |
| With any ChatGPT auth mode the **built-in** `openai` provider's base URL is `https://chatgpt.com/backend-api/codex`. Requests carry `Authorization: Bearer <access>` and `chatgpt-account-id: <account_id>`. | `codex-rs/model-provider-info/src/lib.rs` |
| A provider with `env_key` gets a bare bearer from that env var, **no** account id and **no** `auth.json`. A provider with `requires_openai_auth: true` and no `env_key` gets the ambient `auth.json` auth (bearer plus account id), whatever its id. | `codex-rs/model-provider/src/auth.rs` `resolve_provider_auth` |
| Only the built-in id satisfies `supports_codex_backend_routes` (guardian endpoint, remote compaction, token budget). A non-openai provider also strips encrypted function-call args and internal chat metadata from the request (`client.rs` `build_responses_request`). | `codex-rs/core/src/client.rs` |
| Enterprise "access tokens" (`CODEX_ACCESS_TOKEN`, `codex login --with-access-token`) are static, non-refreshing, and minted in the admin console for Business and Enterprise workspaces only. | docs `enterprise/access-tokens` |

### What Fountain already has

Each of these is reused, not reinvented. Module and function names were
checked against `main` at `59c5ebc8` on 2026-09-08.

- **Tenant credentials.** `Fountain.InferenceCredentials.Credential` holds
  four atoms (`anthropic_api_key`, `claude_code_oauth_token`,
  `openai_api_key`, `gemini_api_key`). `credentials_for_provider/1` and
  `select/2` decide which credential a model runs on; the tenant's own
  always wins.
- **Platform keys** (0038 decision 3, #1388, #1728).
  `Fountain.PlatformInference.key_for/1` reads a `platform_inference_keys`
  row (`PlatformInference.Key`, encrypted with
  `Fountain.Crypto.encrypt_platform/1`) before the
  `PLATFORM_<PROVIDER>_API_KEY` variable. The admin page is
  `FountainWeb.AdminLive.Inference` at `/admin/inference`; the audit events
  are `admin.platform_inference_key.set` and `.cleared` in
  `Fountain.Audit.AdminEvent`.
- **The broker** (0019, on for every tenant since 2026-09-04).
  `Fountain.Broker`'s `@inference` table maps an env var to a credential
  atom and its hosts; `split_inference/2` swaps the value for
  `placeholder/1` (`__lowercase_key__`, vendor-prefixed via
  `@inference_prefix`) and gives the broker an implicit `substitute` binding
  to those hosts. The proxy's unmatched-host policy is `deny`, so the binding
  is also what lets the host through. 0019 decision 4 makes the placeholder
  name a contract between Fountain and the broker.
- **Server-owned refresh tokens.** `Fountain.Connections.access_token/1`
  refreshes 300 s ahead of expiry under a per-row advisory lock (namespace
  4331), marks the row `revoked` on `invalid_grant` and `expired` when there
  is no refresh token. That is the lifecycle this credential needs, already
  written for Gmail.
- **Per-turn refresh** (#1736).
  `Fountain.Conversations.Egress.refresh_before_turn/1` re-reads every
  brokered source before each turn and, when something changed,
  `Broker.refresh/4` rewrites `rules_ciphertext` on every live session row
  behind the token the sandbox already holds. `Broker.prepare/4` is an
  INSERT that an idle ACP peer never sees. New brokered sources go into
  `reread_secrets/1`.
- **Codex provisioning.** `Managoat.Runtimes.Codex.prepare_sandbox/3` in the
  hex library `managoat_runtimes` (pinned `~> 0.3.2` in
  `apps/fountain/mix.exs`) pipes `OPENAI_API_KEY` into
  `codex login --with-api-key`, because codex 0.118+ reads only
  `~/.codex/auth.json`. Changing it is a library release and a pin bump: two
  PRs in two repositories, and the pin was mid-bump when this was built
  (`~> 0.3.2` in `mix.exs`, 0.4.2 on hex). Decision 4 leaves it alone.
- **Codex transport** (#1674). `Fountain.Conversations.CodexTransport`
  rewrites the spawn's `CODEX_CONFIG` to declare and select
  `fountain_openai_http` (`supports_websockets: false`,
  `env_key: "OPENAI_API_KEY"`) because codex's websocket dialer rejects an
  https-scheme proxy and burns the connect timeout first (about 300 s per
  turn, measured). The built-in `openai` id cannot be overridden. This is
  the seam for the new provider shape.

## Decision

The whole design is where each secret lives. Only one thing changes hands at
each hop, and the secret the subscription depends on, the refresh token,
never leaves the server.

```
Admin ──device code / paste──▶ Fountain server ──access token──▶ Broker ──substituted bearer──▶ chatgpt.com
                               (refresh token,                  (substitute rule,
                                encrypted, refreshed             host chatgpt.com)
                                ahead of exp + keepalive)              ▲
                                                                       │ Authorization: Bearer __codex_chatgpt_access_token__
                                                                       │ chatgpt-account-id: <real id>
                                                             Sandbox: ~/.codex/auth.json (chatgptAuthTokens)
```

### 1. The deployment holds one ChatGPT grant, beside its platform API keys

A new table `platform_chatgpt_account`, one row, schema
`Fountain.PlatformChatGPT.Account`: `refresh_token_ciphertext`,
`access_token_ciphertext`, `id_claims` (jsonb, the decoded non-secret
claims), `account_id`, `account_email`, `plan_type`, `access_expires_at`,
`last_refreshed_at`, `status` (`active` | `revoked` | `expired`),
`revoked_reason`, `updated_by_user_id` (nilified on delete, like
`platform_inference_keys`), timestamps. Ciphertexts go through
`Crypto.encrypt_platform/1`. The row gets a nullable `user_id` from day one
so a per-tenant "connect your ChatGPT" is the same row with an owner rather
than a second table, but that surface is not built here.

### 2. The admin connects from `/admin/inference`, by paste first and by device code second

A "ChatGPT account" row joins the three provider rows, with states
*not connected* / *connected as `<email>`* (`<plan>`, last renewed, next
expiry) / *revoked (`<reason>`)* / *expired*, plus Paste and Disconnect.
Paste accepts the file `CODEX_HOME=$(mktemp -d) codex login` writes on a
laptop, which is OpenAI's own CI recipe, validated as `auth_mode: "chatgpt"`
with a non-empty refresh token. Device-code Connect (G3) runs the flow from
the server in a supervised task, shows URL and code in a modal, and polls at
the returned interval. Either way the admin is told plainly: this login is
now Fountain's, and using that same `auth.json` anywhere else will break both.

### 3. Fountain owns the refresh token and is the only thing that ever uses it

`Fountain.PlatformChatGPT.access_token/0` refreshes when within the margin
of `exp`, through `Fountain.PlatformChatGPT.Refresher`, one process per
node, so the deployment's many conversations queue on one round-trip
holding no database connection (unlike `Connections`, whose per-row lock
spans one tenant, this grant is every tenant's); across nodes the write is
a compare-and-swap on the refresh token the read started from, and a loser
serves the winner's tokens. The rotated refresh token is persisted
**before** the new access token is handed out. The margin must exceed the longest turn the deployment
expects, because codex cannot recover a 401 in this mode (decision 5); it
starts at 15 minutes and is config. A keepalive worker
(`Fountain.Workers.PlatformChatGPTKeepalive`, an Oban cron job like
`SecretExpirySweeper`) refreshes when `last_refreshed_at` is older than
6 days so the grant never idles past the 8-day window while nobody runs
codex. A terminal refresh error marks the row `revoked` with the server's
reason code; codex conversations then fall through to the platform
`OPENAI_API_KEY` if one is set, else `{:error, :no_credential}`.

### 4. The sandbox gets `auth.json` in `chatgptAuthTokens` mode, with a placeholder where the bearer goes

A fifth credential atom, `:codex_chatgpt_access_token`, travels in the same
map as the others. `Fountain.Broker`'s `@inference` table gains
`"CODEX_CHATGPT_ACCESS_TOKEN" => %{cred: :codex_chatgpt_access_token, hosts: ["chatgpt.com"]}`,
so `split_inference/2` brokers it exactly like the Claude OAuth token.
The library is not taught a second login. `Fountain.Conversations.CodexChatGPT`
exports `CODEX_CHATGPT_ACCESS_TOKEN` beside the runtime's own `default_env/2`
(`SpriteEnv.build/4`), and at provisioning
`Provisioning.prepare_runtime_sprite/5` asks it first: a codex spawn carrying
that variable gets the file below written by Fountain (`mkdir -p` and a
`0600` write of `$CODEX_HOME/auth.json`) and the library's
`prepare_sandbox/3` never runs; any other spawn takes the library path as
today. The account id and the claims come from the stored row, so no second
variable is needed. The `id_token` is synthesised by Fountain from the stored
claims with an unsigned header and a placeholder signature segment, so the
admin's real identity token and email never enter the sandbox. This
credential is offered to brokered tenants only; a self-hosted runner refuses
brokering, so a runner conversation on the codex runtime sees no ChatGPT
credential and takes the API-key path.

```json
{
  "auth_mode": "chatgptAuthTokens",
  "tokens": {
    "id_token": "eyJhbGciOiJub25lIn0.<claims: chatgpt_account_id, chatgpt_user_id, chatgpt_plan_type>.x",
    "access_token": "__codex_chatgpt_access_token__",
    "refresh_token": "",
    "account_id": "<real account id>"
  },
  "last_refresh": "<now, ISO 8601>"
}
```

**The ACP peer must not authenticate.** codex-acp advertises an `api-key`
method whose `authenticate` reads a key from the env and runs
`accountLogin({type: "apiKey"})`, rewriting the file above, and
`Managoat.ACP.Peer` authenticated with the first api-key method an agent
advertised. So the peer gained `:auth` (`managoat_acp` 0.4.1 on `main`, published as
the 0.3.1 backport Fountain pins because `managoat_runtimes` 0.3.x holds
`managoat_acp` at 0.3; the one library change this ADR needs): `Fountain.Conversations.CodexChatGPT.peer_auth/2`
answers `:none` for a codex spawn carrying the grant and `:api_key` for
everything else, and both peer-start sites (`TurnMachine.start_acp_peer/5`
and `Reattachment.acp_peer/3`) pass it. With no `authenticate` call codex-acp
reads the file, reports the account as a ChatGPT login, and opens the
session on it (measured 2026-09-08).

**Transport.** `CodexTransport` keeps its provider swap and gains a second
shape. When the spawn env carries `CODEX_CHATGPT_ACCESS_TOKEN` and no
`OPENAI_API_KEY`, the declared provider is the one below. Codex then
resolves the ambient auth from `auth.json`, sends the placeholder as the
bearer with the real `chatgpt-account-id`, and never opens the websocket
that stalls behind the broker. What it gives up is the built-in-only
routes (guardian endpoint, remote compaction, token budget), none of which
a Fountain turn depends on. The `OPENAI_BASE_URL` rule for the API-key
shape is untouched.

```json
{
  "model_provider": "fountain_openai_http",
  "model_providers": {
    "fountain_openai_http": {
      "name": "OpenAI",
      "base_url": "https://chatgpt.com/backend-api/codex",
      "wire_api": "responses",
      "requires_openai_auth": true,
      "supports_websockets": false
    }
  },
  "features": { "respect_system_proxy": true }
}
```

### 5. Rotation reaches a running conversation through the broker, never through the sandbox

`Egress.refresh_before_turn/1` gains one more source in `reread_secrets/1`:
read `PlatformChatGPT.access_token/0`, swap it into
`brokered["CODEX_CHATGPT_ACCESS_TOKEN"]`, and let the existing
changed-then-rewrite path through `Broker.refresh/4` carry it. The sandbox
file never changes, the session token never changes, and an idle codex-acp
peer picks up the new bearer on its next request without a spawn. A turn
that outlives the token fails at the proxy with a 401 from `chatgpt.com` on
the transcript, the same failure shape a lapsed Connection has today.

### 6. Selection: tenant credential first, then the subscription for codex, then the platform API key

`InferenceCredentials.select/3` keeps its rule that a tenant's own key
always wins. For provider `openai` with no tenant credential, it takes the
ChatGPT grant when the agent's runtime is `codex` and the grant is `active`
and refreshable, else the platform `OPENAI_API_KEY`. The runtime is the
third argument, threaded from `SpriteEnv.select_inference/2` and the
verified-landing banner; `credentials_for_provider/1` is untouched, because
it names what a *tenant* may hold and no tenant holds this.
`PlatformInference.gate/3` counts the grant as platform-served
(`serves?/2`), so the daily ceiling applies. The origin stays `:platform`, so the ledger prices the turn and the daily
ceiling counts it (0038 decision 3). The ceiling measures turn-hours, not
the subscription's own five-hour and weekly windows; those are shared by
every tenant on the grant, and when they trip codex reports it on the
transcript. No automatic fallback within a turn.

### 7. Audit records the grant's life, never a token

`admin.platform_chatgpt.connected` (method, account id, email, plan),
`admin.platform_chatgpt.disconnected`, `admin.platform_chatgpt.revoked`
(the server's reason code) and `admin.platform_chatgpt.expired`. These are
`admin_audit_events` rows, the privilege trail the platform keys use, which
has no actor column: the two system events carry `"actor" =>
"system:platform_chatgpt"` in their metadata and a nil `actor_user_id`. Routine
refreshes are not audited, the same as Connections. Never a token, never a
claim that is a secret, never inside a transaction (0013).

### 8. The same slot accepts a workspace access token, and it is the preferred one

A deployment on ChatGPT Business or Enterprise pastes a `CODEX_ACCESS_TOKEN`
instead. It is stored in the same row with no refresh token, `status`
flips to `expired` on its admin-set expiry, and the sandbox and broker path
is identical. This is OpenAI's sanctioned non-interactive credential, and
where it is available it is the one to use.

## Lifecycle

| Event | What Fountain does | What the admin sees |
|---|---|---|
| Connect | Paste or device flow. Stores tokens, decodes claims, records `connected`. | "Connected as jake@… (Pro). Token renews automatically." |
| Conversation start | `select/2` picks the grant, `access_token/0` refreshes if within margin, broker gets the value, sandbox gets the placeholder file. | Nothing. |
| Before each turn | `refresh_before_turn/1` re-reads the access token and rewrites the live session's rules if it rotated. | Nothing. |
| Idle week | Keepalive worker refreshes so the grant does not lapse. | "Last renewed 3 days ago." |
| Refresh refused | Row marked `revoked` with the reason code; codex falls through to the platform API key or `:no_credential`. | "Sign-in lost: refresh token was already used. Reconnect." with a Connect button. |
| Subscription rate limit | Nothing server-side; codex reports the reset time on the transcript. | Optional later: the usage window from codex's rate-limit response. |
| Disconnect | Deletes the row, records `disconnected`. Running conversations keep their session until the next turn's re-read. | Row returns to "Not connected". |

## Measured

Run on 2026-09-08 by the maintainer and the agent together, on the
maintainer's ChatGPT Pro account, with two throwaway `CODEX_HOME` sign-ins
from codex-cli 0.153.4 (the version production sandboxes run). Measurement 2
ran on a dev server on the maintainer's laptop with the broker listener on,
`BROKER_TENANTS=*` (the ratchet has since retired; brokerage is now
deployment-wide), and a `fountain runner` inside a container built from
`images/e2b/e2b.Dockerfile` (the production sandbox image, arm64), so the
sandbox dialled the broker over the container's host gateway.

| # | Measurement | Decides | Result |
|---|---|---|---|
| 1 | **Access token lifetime.** Decoded `exp - iat` from both fresh sign-ins and from every refresh response. | The refresh margin in decision 3. | **864,000 s, ten days**, on every token seen. The 15-minute margin and the 6-day keepalive are comfortable; no turn runs near expiry. |
| 2 | **Placeholder end to end, on the custom provider.** `chatgptAuthTokens` file with `__codex_chatgpt_access_token__`, the transport's `fountain_openai_http` provider (`requires_openai_auth`, no `env_key`, backend base URL), broker session minted by hand, codex-acp 1.10.0 (bundling codex 0.153.4) driven over stdio with no `authenticate` call, a prompt that writes a file and runs `cat`. | Whether decision 4 is viable at all. | **Passes.** codex-acp reported the account as "ChatGPT Pro" from the placeholder file; the turn made two tool calls (one "Guardian Review", which the built-in-only claim said would not run) and answered `pong` in 16 s; `broker_requests` shows 40 requests to `chatgpt.com`, all `injected` (39 × 200, 1 × 204) and nothing to any other host; the sandbox file was unchanged afterwards. |
| 3 | **Rotation.** Refresh with `curl`, reuse the old token, refresh again with the new one, refresh a garbage token, refresh a mangled one. | Decision 5, and the whole premise. | **Refresh tokens rotate but are not single-use.** Every refresh returns a new refresh token, `expires_in: 864000`, and `earliest_refresh_at` about nine days out (advisory: an immediate second refresh succeeded). **Reusing the old token returned 200 and forked a second chain**, and both chains kept working. The terminal shapes are a 401 with `error.code = refresh_token_reused` (which the server also answers a garbage token with) and a 400 `invalid_refresh_token_ciphertext_integrity` for a corrupted one; `Fountain.PlatformChatGPT.OAuth` treats both as terminal. The brief's "first sandbox to refresh kills every other copy" did not reproduce today; the design stands on its other merits (the refresh token never leaves the server). |
| 4 | **Device flow from a non-CLI caller.** The three calls from Elixir with Req and Codex's client id, the code approved on `auth.openai.com/codex/device`. | Whether G3's Connect is real. | **Passes.** The server issued a code with a 5 s interval, approval landed 20 s later, and the exchange returned a refresh token, an id_token with the account id and plan, and a ten-day access token. The account had device-code login switched on in ChatGPT security settings first. |
| 5 | **Idle lifetime.** The second sign-in is left untouched; refresh it on day 9 (2026-09-17) and day 30 (2026-10-08). | The keepalive interval in decision 3. | **Pending.** Nothing before 2026-09-17 can settle it. |

Three things the measurements found that the reading of the source had not:

- **The ChatGPT backend serves a different model list from the API.** With
  the grant, `session/new` listed `gpt-6-astra` at six reasoning tiers and
  nothing else; the agent's `openai/gpt-5.3-codex`, which the API-key path
  accepts, failed the model stage ("Choose a model available in this
  runtime"). An agent that may run on the grant needs a model the backend
  lists, and the catalog (`Fountain.Agents.ModelCatalog`) has no way to say
  which credential a suggestion is for yet. Left for a follow-up; the
  transcript names the failure plainly.

- **codex-acp authenticates before the session, and its API-key method
  rewrites `auth.json`.** The ACP peer (`Managoat.ACP.Peer`) authenticates
  eagerly with the first API-key method an agent advertises, for good
  reasons of its own. codex-acp advertises `api-key` (which reads a key from
  the env and runs `accountLogin({type: "apiKey"})`, replacing the grant
  file) and `chat-gpt` (which reads the account and returns true when it is
  already a ChatGPT login). A grant spawn must therefore skip the API-key
  method; that is an option on the peer, in `managoat_acp` (0.4.1 on
  `main`, backported as 0.3.1 for the `managoat_runtimes` 0.3.x pin), and
  the one library change this ADR needs after all.
- **The custom provider is a "gateway" to codex-acp**, which reports it as
  such in `_auth/status_update`; nothing downstream minded.

## Consequences

- **A tenant with no OpenAI key can run codex on the hosted deployment**,
  and the turn is priced at `:platform` like any other platform inference.
  The subscription's own rate windows are shared across every tenant on the
  grant and are not something Fountain can meter.
- **A second credential lifecycle joins the platform surface.** Platform
  API keys are static; this one rotates, idles out and can be revoked from
  the far side. The admin page, the audit trail and the docs all gain a
  stateful row, and `system:platform_chatgpt` joins the closed actor
  vocabulary in 0013.
- **The `@inference` contract (0019 decision 4) grows by one entry**, and
  Fountain, not the library, now writes a codex `auth.json`. The library's
  API-key login is untouched, so no release and no pin bump; the cost is
  that `Fountain.Conversations.CodexChatGPT` and
  `Managoat.Runtimes.Layout` must agree on where `$CODEX_HOME` is.
- **A shared sandbox holds one `auth.json`.** Several conversations share a
  persistent sandbox (0023). One on the API-key path rewrites the file with
  `codex login --with-api-key`; one on the grant rewrites it with the
  placeholder file. The API-key provider reads its key from the env
  (`env_key`) and is unaffected either way; the grant's provider reads the
  file, so a grant conversation provisioned before an API-key one on the
  same sandbox fails at the backend until its next provision. Measurement 2
  is where this is first seen live.
- **Codex gives up its built-in-only routes** on this path: guardian
  endpoint, remote compaction, token budget, and the encrypted function-call
  args a non-openai provider strips. Measurement 2 is what tells us whether
  the backend still accepts the request.
- **Terms and risk.** OpenAI's docs position ChatGPT sign-in for the Codex
  client and route programmatic use to API keys and workspace access
  tokens. This design runs the real `codex` binary against its own
  `auth.json`, which is the sanctioned client, and it does not call
  `backend-api` from the server the way the opencode plugins do. It does put
  many tenants on one consumer subscription, which is the pattern behind
  the reported account bans, and it uses the Codex OAuth client id from a
  server that is not Codex. Anthropic banned the equivalent for Claude
  consumer plans in April 2026. Treat that as the likely direction: the
  workspace access token (decision 8) is the first-class path, and the
  personal-subscription path is an operator option with this caveat written
  down in `docs/configuration.md`, not a product feature.

## Build order

One PR per gate was the plan. #1755 landed the ADR with G1, G2 and G3 built
and tested, and G0 not run; the done-when evidence for G2 (a real sandbox, a
real egress log row, a real ledger row) is therefore still owed, and so is
G0's.

| Gate | Builds | Done when |
|---|---|---|
| **G0** | The five measurements above, in a throwaway `CODEX_HOME` and a dev broker. Fills the Measured block. | A codex turn completes with the placeholder in the sandbox and the bearer only at the proxy, and the lifetimes are written into this record. |
| **G1** (built, #1755) | Migration and schema, `Fountain.PlatformChatGPT` (`connect_from_auth_json/2`, `access_token/0`, `disconnect/1`, `status/0`), the keepalive worker, the paste-to-connect row on `/admin/inference`, the audit events, a section in `docs/configuration.md`. | A pasted grant survives a forced refresh and the keepalive, `admin_inference_chatgpt_live_test.exs` covers all four row states, and a deliberately reused refresh token flips the row to `revoked` with `refresh_token_reused`. All three hold in the suite against a stubbed auth server. |
| **G2** (built, #1755; measured 2026-09-08) | The `@inference` entry, the runtime-aware `select/4` (grant for brokered conversations only), the extra source in `reread_secrets/1`, the second provider shape in `CodexTransport`, `Fountain.Conversations.CodexChatGPT` writing the sandbox file, and the peer's `:auth` option (`managoat_acp` 0.3.1, a backport of 0.4.1). | A tenant with no OpenAI key runs a codex agent on the grant in a real sandbox, the transcript shows a reply to a tool-calling prompt, the egress log shows only `chatgpt.com` injected for that conversation, and the ledger row for the turn says `:platform`. **Held on the dev rig through the API**: the tenant held no credential, the turn completed (`end_turn`, usage input 247 / output 5 / cache read 14,848), the sandbox file it wrote read `pong`, the egress log for the conversation showed 49 injected requests to `chatgpt.com` (one of them a 101 websocket upgrade) and nothing injected anywhere else, and the file still held the placeholder. **Held in production too, 2026-09-08:** a tenant with no OpenAI key ran codex-probe (`openai/gpt-6-astra`) on Sprites; the reply was `pong`, the egress log showed 33 injected requests to `chatgpt.com` and none injected elsewhere, the turn's usage row said `inference: platform`, and at the pricer's next tick the ledger took a `burn_inference` debit of one cent for it. The daily ceiling and the balance both counted it. **Decision 5 held too**, on the published pin: with the grant's expiry forced inside the refresh margin between two prompts on one conversation, the row rotated (new refresh and access tokens, renewed ten days) and the second prompt's requests to `chatgpt.com` were injected on the same session, the sandbox file untouched. |
| **G3** (built, #1755) | Device-code Connect in a supervised task (`Task.Supervisor.start_child(Fountain.TaskSupervisor, ...)`, never `Task.async`), workspace-token paste (decision 8), revocation UX on the row. | An admin connects with no laptop-side codex install. Holds in the suite against a stubbed device flow; measurement 4 is whether the real server accepts it. |

## Alternatives considered

- **Copy `auth.json` into each sandbox, like the Claude token.** The refresh
  token rotates, OpenAI's guidance says one file per runner, and the issue
  tracker has the copy flow breaking; measurement 3 found reuse forking
  rather than revoking today, which is not a contract, and either way the
  refresh token would sit in every sandbox.
- **Let codex refresh inside the sandbox and read the rotated token back.**
  Concurrent sandboxes race on one grant, and the sandbox would hold the
  refresh token, which is the one secret worth stealing.
- **Call `chatgpt.com/backend-api` from the server and expose an
  OpenAI-compatible endpoint (0035).** Reverse-engineered, not the Codex
  client, and the clearest terms violation of the options.
- **Per-tenant ChatGPT connections instead of a platform grant.** The same
  row with an owner, and where this should go if consumer subscriptions
  turn out to be allowed. The platform grant is the smallest version and
  the one the hosted deployment needs first; decision 1's nullable `user_id`
  keeps the door open.
- **Wait for OpenAI to publish a static token for consumer plans.** Nothing
  suggests one is coming; workspace access tokens are the answer they
  shipped, for Business and Enterprise.
- **The built-in `openai` provider over codex's explicit proxy route.**
  Opt-in in 0.153 and the subject of upstream #13103. It keeps the
  built-in-only routes but reintroduces the websocket stall #1674 removed.
  It is the fallback if measurement 2 fails, not the first choice.

## Sources

- [Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Maintain Codex account auth in CI/CD](https://learn.chatgpt.com/docs/auth/ci-cd-auth)
- [Codex access tokens (Business/Enterprise)](https://learn.chatgpt.com/docs/enterprise/access-tokens)
- [codex-rs/login/src/auth/manager.rs](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs)
- [codex-rs/login/src/token_data.rs](https://github.com/openai/codex/blob/main/codex-rs/login/src/token_data.rs)
- [codex-rs/login/src/device_code_auth.rs](https://github.com/openai/codex/blob/main/codex-rs/login/src/device_code_auth.rs)
- [codex-rs/model-provider-info/src/lib.rs](https://github.com/openai/codex/blob/main/codex-rs/model-provider-info/src/lib.rs)
- [openai/codex #15502](https://github.com/openai/codex/issues/15502),
  [#15410](https://github.com/openai/codex/issues/15410),
  [#13103](https://github.com/openai/codex/issues/13103)
- [7shi/codex-oauth](https://github.com/7shi/codex-oauth),
  [mostlyuseful/codex-access-token](https://github.com/mostlyuseful/codex-access-token),
  [codex-lb OAuth configuration](https://mintlify.wiki/Soju06/codex-lb/configuration/oauth)
- [Anthropic bans subscription auth in third-party tools](https://alternativeto.net/news/2026/2/anthropic-officially-bans-using-subscription-authentication-for-third-party-claude-use)
- [ChatGPT and Codex account ban risk guide](https://blog.4sapi.com/blog/chatgpt-codex-account-ban-api-guide)
