# Configuration reference

Here is each environment variable that the server reads at runtime, in groups.
The server reads them at boot. To change one, restart the app.

This list is complete by construction. A test fails the build when
`config/runtime.exs` reads a variable that this page does not document. So the
reference cannot drift from the code without a sound.

A few variables **refuse to boot on an invalid value**. They fall back to no
default, and each row says so.

That is deliberate. A typo that quietly turned a bound or a key off would
otherwise surface as a bill or a breach. It would not surface as an error
message.

---

## Core

| Variable | Default | Required | Effect |
|---|---|---|---|
| `DATABASE_URL` | — | prod | The Postgres connection string. Boot fails without it. |
| `SECRET_KEY_BASE` | — | prod, to serve | Signs and encrypts the session cookies and the tokens. Generate one with `openssl rand -base64 48`. |
| `MASTER_SECRETS_KEY` | — | prod | Wraps each tenant's data-encryption key. Read [the secrets model](architecture.md#the-secrets-model). It is 32 bytes, url-safe base64, with no pad character: `openssl rand 32 \| base64 \| tr '+/' '-_' \| tr -d '='`. **Lose it and you lose each stored secret.** Boot refuses a malformed value. |
| `PUBLIC_URL` | — | prod | The base URL that the outside world sees, with the scheme. A prod instance requires this variable or the platform fallback from `FLY_APP_NAME`. The old `http://localhost:4000` fallback quietly put localhost links in each verification email. This variable builds each link that leaves the app, which is the verification and reset emails and `llms.txt`. Fountain passes it to each sandbox as `FOUNTAIN_BASE_URL`. An `https://` value also starts the HTTPS redirect, HSTS and the secure cookie flag, and Fountain derives all three from the scheme. |
| `FORCE_SSL_EXCLUDE_HOSTS` | — | — | Comma-separated hosts that the HTTPS redirect and HSTS leave alone, for callers inside the deployment's own network that reach the app over plain HTTP at its service name, such as a Kubernetes Service (`fountain.fountain.svc.cluster.local`). Without it they get a 301 to `https://` on a host that serves nothing there. `localhost` is always excluded. |
| `PHX_HOST` | The host of `PUBLIC_URL`. | — | The bare host for the endpoint URL and for the LiveView origin check. Set it only when it differs from the host in `PUBLIC_URL`. |
| `FLY_APP_NAME` | — | — | Fly sets this on each machine. Fountain builds `https://<app>.fly.dev` from it, and reads that as the fallback for `PUBLIC_URL`. A deploy from `fly.toml` needs it, because that file ships with an app name that `fly launch` replaces. An explicit `PUBLIC_URL` has precedence. Set `PUBLIC_URL` when you add a custom domain. |
| `PHX_SERVER` | `true` in the shipped image. | — | A `1`, `true` or `yes` starts the web listener. A release task runs with `PHX_SERVER=false … eval '…'`. That boots the app, and binds no port. |
| `PORT` | `4000` | — | The HTTP port to listen on. |

## Database

| Variable | Default | Required | Effect |
|---|---|---|---|
| `DATABASE_SSL` | `true` | — | TLS to Postgres. Set `false` for a stock `postgres` container, which serves no TLS. |
| `DATABASE_SSL_VERIFY` | off. | — | Unset, the driver encrypts the connection and verifies no server certificate. `true` verifies it, against the OS trust store, unless you give a CA file. |
| `DATABASE_SSL_CA_FILE` | The OS trust store. | — | The CA bundle to use when `DATABASE_SSL_VERIFY=true`. |
| `DATABASE_IPV6` | off. | — | `true` connects to Postgres over IPv6. Fly Managed Postgres needs it: its `*.flympg.net` host resolves to a private IPv6 address only, and without this the app cannot find the database and exits at boot with `:nxdomain`. |
| `POOL_SIZE` | `10` | — | The size of the database connection pool. |
| `MIGRATE_ON_BOOT` | `true` | — | Whether a release runs the migrations that are due before it serves. A `false`, and also `0` or `no`, makes the pod serve and no more. Use that for a deployment that runs the migrations once, in a Job. Read [migrations in a Job](guides/operate/database.md#run-migrations-in-a-job). `bin/migrate` always migrates, whatever you set here. **Nothing checks that the Job ran.** A pod that skips the migrations boots against a database nobody migrated. It then fails on the first query. |

## Sandboxes

| Variable | Default | Required | Effect |
|---|---|---|---|
| `SPRITES_TOKEN` | — | For conversations. | The platform token for [sprites.dev](https://sprites.dev). The app boots without it, and each conversation then fails. Never show it to a tenant, because it pays for each sandbox. |
| `SPRITES_BASE_URL` | `https://api.sprites.dev` | — | Repoints the sandbox API. Whatever you point it at must implement the same contract, and Fountain bundles no alternative. |
| `SPRITES_TIMEOUT_MS` | `30000` | — | Bounds each HTTP call to the Sprites API. A long command, such as a package install or a clone, sets its own timeout for that call. Boot refuses a value that is not positive. |
| `SANDBOX_PROVIDER` | `sprites` | — | Which backend a new sandbox runs on. One of `sprites`, `e2b` and `runner`. A hosted provider turns on when its credential is there. Boot refuses an explicit default whose credential is absent. A sandbox that already exists stays on the provider Fountain made it on. |
| `SANDBOX_RUNNERS_ENABLED` | `true` | — | A [self-hosted runner](integrations/runners.md) needs no credential. A `false` hides the `runner` provider, and refuses a `fountain runner` connection. |
| `BROKER_LISTEN_PORT` | — | — | A port number, for example `14322`. This turns on credential brokerage (ADR 0019): Fountain runs the egress proxy itself, from the `managoat_broker` library, on this port on every replica. Each conversation's proxy session goes in the `broker_sessions` table, so any replica can serve a sandbox. Set it, and boot also requires `BROKER_PROXY_URL`. Point your ingress at this port. The proxy speaks plain HTTP, and TLS towards the sandbox is the job of the ingress. Blank leaves brokerage off, and each conversation provisions as before. Set it, and Fountain brokers every account on the deployment. |
| `BROKER_PROXY_URL` | — | With `BROKER_LISTEN_PORT`. | The proxy address a sandbox dials, for example `https://broker.example.com:443`. It is not the same as the listen port when the sandboxes are on a different network from Fountain. Its host is the one host a brokered sandbox may reach. |
| `BROKER_TENANTS` | — | — | **Retired.** It was the operator ratchet of ADR 0019 §9, and it named the tenants to broker. A deployment with `BROKER_LISTEN_PORT` brokers every account, so a list of ids has no answer left, and boot refuses one. A `*` on its own stays valid, and it keeps one job. It asserts that this deployment brokers egress, so boot refuses a `*` with no `BROKER_LISTEN_PORT`. Without that assertion a lost listener disables brokerage for every tenant, each sandbox holds plaintext credentials, and no other signal reports it. |
| `BROKER_LOG_RETENTION_HOURS` | `168` | — | How long the egress request log keeps a row. `GET /api/conversations/:id/egress` reads it, and `/admin/broker` sums it. A daily job deletes older rows. New request rows store `/[REDACTED]` as the path; the API also hides paths in older rows. Existing database paths remain until this sweep removes them. Historical server logs follow the log storage system's retention policy. |
| `BROKER_ALLOW_UNENFORCED` | `false` | — | A `true` lets a brokered conversation run on a provider that has no network policy, for example a self-hosted runner. The sandbox then holds placeholders and a proxy address, but nothing stops a process from a direct connection that avoids the proxy. For development only. |
| `E2B_API_KEY` | — | For the `e2b` provider. | The [E2B](https://e2b.dev) API key. Its presence turns the provider on. |
| `E2B_BASE_URL` | `https://api.e2b.app` | — | Repoints the E2B control plane. |
| `E2B_TEMPLATE` | `base` | — | The template that Fountain creates a new E2B sandbox from. The stock `base` template has no agent CLI, so build one from `images/e2b/` for real use. |
| `E2B_USER` | `sprite` | — | The in-guest user that envd runs a command as. An `images/e2b/` template creates `sprite`. Set it to `user` when you point at the stock `base` template. |
| `SANDBOX_IDLE_TIMEOUT_MINUTES` | `60` | — | No turn activity for this long, and Fountain parks the sandbox. A provider without `:suspend` destroys it instead. The conversation stays [resumable](guides/operate/sandbox-lifetime.md) either way. A `0` turns the bound off, and boot refuses whatever is not a non-negative integer. |
| `SANDBOX_MAX_LIFETIME_HOURS` | `0` (off) | — | A ceiling on one continuous run, whatever the activity. Off by default: nothing stops a sandbox that stays busy. Set it to park a persistent home, or destroy an ephemeral sandbox, after this many hours. The same boot refusal applies. |
| `CHECKPOINT_CREATION_ENABLED` | `false` | — | Set to `true`, and Fountain takes a checkpoint of each persistent home when it parks, on a provider that has checkpoints (Sprites). The checkpoint belongs to that one machine. It can roll the machine back, and it cannot rebuild a machine that the provider lost. Each park adds one checkpoint, and Fountain does not delete old ones. The same flag also makes Fountain checkpoint each environment after it provisions a sandbox, which Sprites cannot restore into a new sandbox. |
| `SANDBOX_SNAPSHOTS_ENABLED` | `true` | — | When a sandbox parks, Fountain saves a snapshot of the git work trees under its working directory, so the files API can answer while the sandbox is parked. Set it to `false` to turn this off. A parked sandbox's file reads then return `409 sandbox_not_ready`. |

## Registration and accounts

| Variable | Default | Required | Effect |
|---|---|---|---|
| `REGISTRATION_ENABLED` | `true` | — | A `false` closes signup entirely. Somebody will find an open instance on the public internet. |
| `REGISTRATION_ALLOWED_EMAIL_DOMAINS` | any | — | A comma-separated list. Fountain refuses a signup outside these domains. Empty means no restriction. |
| `REGISTRATION_ACCESS_CODE` | — | — | A shared code that every signup must give: in the sign-up form, as `access_code` to `POST /api/auth/register` (`--access-code` on `fountain auth register`), and before a first GitHub sign-in. Existing accounts sign in without it. Empty means no code. |
| `FIRST_USER_ADMIN` | `false` | — | A `true` promotes the first account that becomes verified to admin, while the instance has no admin. The audit trail records it (ADR 0011). Leave it off on a multi-tenant deployment, because it hands admin to whoever verifies first. |

## Email

Production **refuses to boot** unless you configured exactly one of the three
delivery options. A verification email that Fountain throws away leaves signup
at a dead end, with no error to see. Read [Email](guides/operate/email.md).

| Variable | Default | Required | Effect |
|---|---|---|---|
| `RESEND_API_KEY` | — | One of three. | Resend delivers the mail. |
| `SMTP_HOST` | — | One of three. | Any SMTP server delivers the mail. |
| `SMTP_PORT` | `587` | — | The SMTP port. |
| `SMTP_USERNAME` | — | — | Omit it for a relay that wants no authentication. |
| `SMTP_PASSWORD` | — | — | |
| `SMTP_TLS` | `always` | — | STARTTLS by default. Use `never` for a relay on a trusted network that does not offer it. |
| `EMAIL_DELIVERY` | — | One of three. | A `none` turns email off, on purpose. An account then self-verifies at registration (ADR 0011). Nothing can deliver a password-reset email. So in this mode, a password that somebody forgets stays forgotten. |
| `EMAIL_FROM` | — | When mail is on. | The From address. A real delivery provider needs it. A prod instance refuses to boot without it, because a receiver rejects mail from a domain nobody verified anyway. `EMAIL_DELIVERY=none` uses it for nothing. |
| `SUPPORT_EMAIL` | — | — | Where "contact support" in an account email points. Those are the suspension and deletion emails. Unset, the copy names no address. |

## Authentication

| Variable | Default | Required | Effect |
|---|---|---|---|
| `GITHUB_OAUTH_CLIENT_ID` | — | — | Turns the GitHub sign-in button on. Unset, Fountain hides the button, and email and password auth still works. |
| `GITHUB_OAUTH_CLIENT_SECRET` | — | — | |

## Sandbox capacity

| Variable | Default | Required | Effect |
|---|---|---|---|
| `SANDBOX_CAP_CEILING` | `20` | No. | The most sandboxes one tenant may run at once. An admin override for one account replaces it for that account. |
| `SANDBOX_FLEET_CEILING` | `20` | No. | The most live sandboxes across every tenant. Set it to what your sandbox provider plan allows. A start beyond it gets `503 fleet_full`. |
| `SANDBOX_QUEUE_MAX_DEPTH` | `10` | No. | The most sandbox requests one tenant holds at once. A request beyond it keeps the immediate capacity error. |
| `SANDBOX_QUEUE_MAX_WAIT_SECONDS` | `3600` | No. | How long a sandbox request waits for capacity before Fountain expires it. |
| `FOUNTAIN_EXECUTION_LIMITS` | `{}` | No. | JSON per-turn host ceiling: `wall_time_seconds`, `max_model_turns`, `max_estimated_cost_usd`. Each configured value must be positive; time and turns must be integers. Read at boot; invalid input refuses startup. Requests inherit the stricter host/account ceiling. Keep unset until runtime enforcement and later-turn/recovery checks are integrated: nonempty effective limits currently refuse launch with `422 execution_limits_unsupported`. This is not an aggregate spend cap. |
| `FOUNTAIN_EXECUTION_DEADLINE_WORKER` | on when `FOUNTAIN_EXECUTION_LIMITS` gives a ceiling | No. | If this node runs the deadline coordinator. The coordinator polls `turn_executions`, so it stays off where no host ceiling applies. Set `true` if you give an account a ceiling but no host ceiling. Set `false` to stop the poll on any node. A change needs a restart. |
| `FOUNTAIN_EXECUTION_DEADLINE_INTERVAL_MS` | `5000` | No. | The interval at which the coordinator looks for due deadlines. Each deadline is absolute and durable, so a larger value costs precision and not safety. |
| `CHATGPT_GRANT_CEILING` | `5` | No. | The most ChatGPT subscriptions one account may link. A disconnected subscription keeps its place until the account removes it. A link beyond it gets `409 chatgpt_grant_limit_reached`. A lower value refuses new links only, and `0` refuses each new link. |

## Platform inference

Fountain can hold its own inference keys. A tenant with no credential of their
own then runs on a Fountain key. The tenant's own credential always wins.
There is no per-agent switch.

**Usage on a platform key has no limit.** You pay the provider for the tokens
of every account that runs on your key. Fountain does not charge the tenant,
and no daily ceiling stops the spend. Set a platform key only if you accept
that bill, for example on a deployment where you trust each account.

Every variable here is blank by default. A deployment with no platform key
behaves as it always did, and each tenant supplies a credential of their own.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `PLATFORM_ANTHROPIC_API_KEY` | — | No. | The Anthropic key Fountain runs a tenant on when that tenant has none. This is the first key to set. The default agent uses the claude runtime. |
| `PLATFORM_OPENAI_API_KEY` | — | No. | The same, for an agent on an `openai/` model. |
| `PLATFORM_GEMINI_API_KEY` | — | No. | The same, for an agent on a `google/` model. |

### Set a key from the admin panel

An admin can also set each key at `/admin/inference`. Fountain stores that
key in the database, encrypted under `MASTER_SECRETS_KEY`, and uses it from
the next conversation on. No restart is necessary.

A key set in the panel wins over the variable. Clear the key in the panel to
go back to the variable. The page shows the source of each provider's live
key, the last four characters of that key, and who set it. Each save and each
clear leaves an `admin.platform_inference_key` event on the admin activity
page.

Use the variable to seed a new deployment. Use the panel to rotate a key on a
deployment that already runs.

### The ChatGPT account for the codex runtime

Fountain can also hold one ChatGPT account for the `codex` runtime. A codex
agent whose tenant has no OpenAI key then runs on that account, before the
`PLATFORM_OPENAI_API_KEY` key. The tenant's own key always wins.

Connect the account at `/admin/inference`. There are three ways in.

- **A device code.** Fountain requests a code, shows the code and a link, and
  waits for your approval on the ChatGPT page. The account must permit
  device-code login in its ChatGPT security settings.
- **A pasted `auth.json`.** Use Codex 0.93.0 or newer on a laptop.
  The file must contain `"auth_mode": "chatgpt"` and a refresh token.
  Missing, null and other modes are refused. Follow the export steps below.
  After the paste, the file belongs to Fountain. Do not use it anywhere
  else, or both copies stop.
- **A workspace access token.** A ChatGPT Business or Enterprise workspace
  can mint a static token in its admin console. Paste the token and its
  expiry date. This is the credential OpenAI sanctions for servers, so use it
  where you have one.

For a fresh file export, run these commands and complete the ChatGPT sign-in.

```bash
FOUNTAIN_CODEX_HOME=$(mktemp -d)
CODEX_HOME="$FOUNTAIN_CODEX_HOME" codex -c 'cli_auth_credentials_store="file"' login
```

Paste `auth.json` from that temporary directory into Fountain.
For an older file, upgrade Codex and repeat these steps. Do not add a mode
field to an old file. Stored Fountain grants continue to refresh without
another import.

The [Codex 0.93.0 login writer](https://github.com/openai/codex/blob/rust-v0.93.0/codex-rs/login/src/server.rs#L562)
sets the explicit mode. This is the supported producer floor; Fountain
checks the file format because `auth.json` contains no producer version.

Fountain keeps the refresh token, encrypted under `MASTER_SECRETS_KEY`, and
renews the access token itself. A sandbox never sees either token. The
sandbox holds a placeholder, and the egress broker puts the real token into
the request to `chatgpt.com`. Each connect and disconnect leaves an
`admin.platform_chatgpt` event on the admin activity page.

The broker asks Fountain for the token on every request, and only for the
two routes Codex uses: `POST https://chatgpt.com/backend-api/codex/responses`,
and `GET https://chatgpt.com/backend-api/codex/models` with only the
`client_version` query parameter.
So a disconnect or a reconnect takes effect on the next request, including
in a conversation that is mid-turn. A secret binding or a custom header
template cannot send the token anywhere else. If a binding of yours matches
either route, a codex conversation on the account fails to provision until you
remove it. A codex conversation on the account cannot open a WebSocket, or
any other protocol upgrade, through the broker to any host. Plain HTTP
requests and streamed responses work as before. Fountain sets `CODEX_HOME`
for such a conversation, and ignores a `CODEX_HOME` from its environment or
vault.

The broker also allows two more routes for such a conversation:

- **The model list:** `GET https://chatgpt.com/backend-api/codex/models`,
  with only the `client_version` query parameter.
- **Analytics:** `POST https://chatgpt.com/backend-api/codex/analytics-events/events`.
  Fountain turns Codex's analytics off by default in the conversation's
  `CODEX_HOME`, so these requests arrive only if a `config.toml` turns
  analytics on.

Codex also asks `chatgpt.com` for plugin lists, an MCP surface and settings.
The broker refuses those requests, and `/admin/broker` lists them as denied.
This is expected. Most of the refusals come once, when a sandbox starts, and
each turn after that adds a few more. On a subscription Fountain turns off
Codex's remote plugin catalog, so fewer of them arrive. A refused request
that has no body leaves its connection open. We observed this in production on
2026-09-21 with codex-acp 1.10.0 and Codex CLI 0.153.4, and the turns
completed without those requests.

A ChatGPT account has Codex usage limits. When a codex turn on the account
fails because the account is at its limit, that turn fails. Fountain does
not retry it. The error comes from the sandbox, and a tenant can change what
runs in the sandbox, so Fountain does not trust the error. Fountain asks
ChatGPT for the account's usage itself, with the account's own token. It
asks at most once every five minutes.

If ChatGPT confirms the limit, Fountain records the reset time that ChatGPT
gives and shows it at `/admin/inference`. It also records an
`admin.platform_chatgpt.exhausted` event. Until the reset time, new codex
conversations use `PLATFORM_OPENAI_API_KEY` instead of the account. Those
turns use the API key, which has no limit. If no OpenAI
platform key is set, codex conversations continue to use the account.
After the reset time, the account is used again. If ChatGPT does not confirm
the limit, or the check fails, Fountain records nothing.

The limit belongs to the ChatGPT account, not to its token. If you reconnect
the same account, the reset time stays. If you connect a different account,
Fountain clears it. If ChatGPT confirms the limit but gives no reset time,
Fountain skips the account for one hour.

The switch applies to new selections only. A codex sandbox stays bound to
the credential it started on, and Fountain does not move it. A new
conversation is not always a new sandbox: with `sandbox_mode: persistent`, it
lands on the agent's persistent home. So each switch has the same effects:

- **When the limit is confirmed.** A persistent home that started on the
  account refuses new persistent conversations with
  `409 codex_inference_conflict`. A conversation that runs on the account
  stays on it. Its turns fail until the reset time. If its sandbox parks,
  wake and provision fail with `409 inference_source_changed` until the reset
  time.
- **When the reset time passes.** The same happens in reverse. A persistent
  home that started on `PLATFORM_OPENAI_API_KEY` refuses new persistent
  conversations with `409 codex_inference_conflict`. A conversation that runs
  on the key fails wake and provision with `409 inference_source_changed`.

To run on the new selection, use a sandbox that is not bound to the old
credential. Start the conversation with `sandbox_mode: ephemeral`, or reset
the persistent home with `DELETE /api/sandboxes/{id}`. The next persistent
conversation then builds a new home. A reset replaces the home's disk. See
[Sandboxes](api.md#sandboxes).

These effects belong to the deployment's account and key, which share one
Codex sign-in file on a sandbox. A ChatGPT subscription that a tenant links
and a credential set names is different. Codex keeps that sign-in in a home
of its own, so it shares a sandbox with each other source and gets no
`409 codex_inference_conflict`. A sandbox that was first bound before Fountain
prepared such homes keeps the old rule for each source.

A personal subscription is one account for every tenant on the deployment.
That pattern is behind reported account bans, and it is an operator's own
risk. The page says so.

## Brand

`/` sends a visitor to the console, and on to sign-in when they are signed
out. The manual at `/docs` is the only public page. These variables change
what the console and the manual's chrome call the deployment.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `PRODUCT_NAME` | `Fountain` | — | The name the console, the sign-in page, the OAuth consent screen and each email subject use for this deployment. The CLI, the API and this manual keep the name Fountain, because that is the name of the engine. |
| `BRAND_ASSETS_URL` | unset | — | The URL of the directory with the brand's image files. The directory must contain six files. They are `app-icon.png`, `apple-touch-icon.png`, `favicon-32x32.png`, `favicon-16x16.png`, `favicon.ico` and `og-card.png` (1200 by 630 pixels). Unset, the pages use the files in the release image. Set, the pages link the files in this directory, and the CSP permits images from its origin. The value must be an absolute URL. |

## Proxies and origins

| Variable | Default | Required | Effect |
|---|---|---|---|
| `TRUSTED_PROXIES` | — | Behind a proxy. | Comma-separated CIDRs that Fountain steps over as it resolves the client IP from `X-Forwarded-For`. Without it, the rate limit for each IP collapses into one bucket keyed on the proxy. Set it too broad, and a client can spoof its way past the rate limit. |
| `CHECK_ORIGIN_EXTRA` | — | — | Comma-separated extra origins that can open a LiveView websocket. Fountain always includes your own host. |
| `OAUTH_CLIENTS` | — | — | A JSON array of `{id, name, redirect_uris}`. It names the browser apps that can "Sign in with Fountain". That is OAuth code with PKCE, for a public client, and `decisions/0021` covers it. A redirect URI must match exactly. Unset means none. |
| `API_CORS_ORIGINS` | — | — | Comma-separated browser origins, or a `*`, that can call `/api` with a bearer key from another site. A standalone client such as the team app needs that. It is off when unset, and a cookie never crosses an origin either way. |
| `CONVERSATIONS_APP_URL` | `https://fountain-conversations.demo.managoat.com/` | — | Where the console sends a person to watch a conversation. The default is a static build that takes *your* Fountain's URL as input. So it works for a self-hosted server as soon as `API_CORS_ORIGINS` admits `https://fountain-conversations.demo.managoat.com`. Point it at your own copy instead, or set it to `""` to say this deployment has no such app. |
| `TEAM_APP_URL` | `https://fountain-team.demo.managoat.com/` | — | The same, for the team roster. |

## Clustering

You need this for more than one replica, and for nothing else. Read
[Clustering](architecture.md#clustering) for what breaks without it.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `CLUSTER_DNS_QUERY` | `<app>.internal` on Fly with `RELEASE_COOKIE` set, otherwise unset. | Multi-replica. | The DNS name that Fountain polls to discover a peer. In Kubernetes that is a headless service. On Fly the release sets it for you, from `FLY_APP_NAME`. Empty or unset, the cluster is off, and an empty value turns it off on Fly too. On Fly, a value without `RELEASE_COOKIE` **refuses to boot**. |
| `RELEASE_COOKIE` | A random value baked into each image. | Multi-replica. | The shared secret that lets two nodes connect. Use the same value on every node, and keep it secret, because a node that holds it can run code on every other. Each image build bakes its own cookie, so without this variable the old and the new nodes of a rolling deploy never connect. On Fly, setting it turns the cluster on. Generate it with `openssl rand -hex 32`. |
| `RELEASE_NAME` | Set by the release. | — | The node basename that peer discovery uses. It must match what each node registered as. The release sets it, so override it only when you know why. |
| `FLY_PRIVATE_IP` | — | — | Fly sets this on each machine to its private IPv6 address. With `RELEASE_COOKIE` set, the release names the node `fountain_server@<FLY_PRIVATE_IP>` and runs distribution over IPv6. An explicit `RELEASE_NODE` has precedence. |

## Observability

| Variable | Default | Required | Effect |
|---|---|---|---|
| `METRICS_PORT` | `9568` in prod, off elsewhere. | — | The private Prometheus listener, which serves `/metrics` and `/health`. A `""` or a `0` turns it off. Keep it off the public internet. |
| `SENTRY_DSN` | — | — | Turns error reports on. Unset, the SDK is inert and nothing leaves the instance. It accepts sentry.io, or any endpoint that speaks the Sentry API, such as GlitchTip. |
| `SENTRY_ENVIRONMENT` | The build env. | — | The environment tag on a reported error. |
| `FOUNTAIN_BUILD_SHA` | Set by the image build for a release image, or by the deployment for a main-line image. | — | Matches an error and a trace to a deploy. The app footer shows it too. |
| `OTEL_SERVICE_NAME` | `fountain` | — | The service name on an exported trace. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | — | — | The OTLP target for a trace export, over HTTP with protobuf. Unset, nothing is exported. |
| `OTEL_EXPORTER_OTLP_HEADERS` | — | — | The `key=val,key=val` headers on a trace export. A vendor that authenticates by header takes its key here, for example `x-honeycomb-team=<key>` for Honeycomb. |

Fountain configures a trace export in production, while it serves, and nowhere
else. It is **off by default**. It exports a span only when you explicitly set
`OTEL_EXPORTER_OTLP_ENDPOINT`. Headers alone do not turn it on.

The OTel SDK also honours its own standard variables, and those win. Set
`OTEL_TRACES_EXPORTER=otlp` or `=none` to force the export on or off, whatever
the table above says.

## Feature flags

`Fountain.FeatureFlags` reads configuration and nothing else. A flag is on or
off for the whole deployment, and the same answer applies to each account.

The one flag is `chatgpt_subscriptions`. It holds the door that links a new ChatGPT subscription to an account, and that feature is in
development. The flag reads off until you add `chatgpt_subscriptions` to
`FEATURE_FLAGS_ON`. It needs the credential broker too. Read
[feature status](reference/feature-status.md) first, and do not turn the flag
on for an instance that serves people you do not trust. An account that loses
the flag keeps each subscription it linked. The API still lists, renames,
reconnects, disconnects and removes them.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `FEATURE_FLAGS_ON` | — | — | Comma-separated flag keys, turned on for each account. ChatGPT subscriptions are off unless `chatgpt_subscriptions` is here, and the feature is not proven on the real service. See [feature status](reference/feature-status.md). |

A flag that gates a shipped feature would read on by default, so that an
upgrade adding it does not take the feature away. None does today.
