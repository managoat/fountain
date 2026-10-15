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
| `MASTER_SECRETS_KEY` | — | prod | Wraps each account's data-encryption key. Read [the secrets model](architecture.md#the-secrets-model). It is 32 bytes, url-safe base64, with no pad character: `openssl rand 32 \| base64 \| tr '+/' '-_' \| tr -d '='`. **Lose it and you lose each stored secret.** Boot refuses a malformed value. |
| `PUBLIC_URL` | — | prod | The base URL that the outside world sees, with the scheme. A prod instance requires this variable or the platform fallback from `FLY_APP_NAME`. The old `http://localhost:4000` fallback quietly put localhost links in each verification email. This variable builds each link that leaves the app, such as the links in the verification and reset emails. Fountain passes it to each sandbox as `FOUNTAIN_BASE_URL`. An `https://` value also starts the HTTPS redirect, HSTS and the secure cookie flag, and Fountain derives all three from the scheme. |
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
| `MIGRATE_ON_BOOT` | `true` | — | Whether a release runs the migrations that are due before it serves. A `false`, and also `0` or `no`, makes the pod serve and no more. Use that for a deployment that runs the migrations once, in a Job. Read [migrations in a Job](guides/operate/deploy.md#run-migrations-in-a-job). `bin/migrate` always migrates, whatever you set here. **Nothing checks that the Job ran.** A pod that skips the migrations boots against a database nobody migrated. It then fails on the first query. |
| `RELEASE_NAME` | Set by the release. | — | The release script sets this, and a process with it set is a release. Only a release migrates at boot; `mix` in development and test manages its own schema. Leave it alone. |

## Sandboxes

| Variable | Default | Required | Effect |
|---|---|---|---|
| `SPRITES_TOKEN` | — | For conversations. | The platform token for [sprites.dev](https://sprites.dev). The app boots without it, and each conversation then fails. Never show it to another account, because it pays for each sandbox. |
| `SPRITES_BASE_URL` | `https://api.sprites.dev` | — | Repoints the sandbox API. Whatever you point it at must implement the same contract, and Fountain bundles no alternative. |
| `SPRITES_TIMEOUT_MS` | `30000` | — | Bounds each HTTP call to the Sprites API. A long command, such as a package install or a clone, sets its own timeout for that call. Boot refuses a value that is not positive. |
| `SANDBOX_PROVIDER` | `sprites` | — | Which backend a new sandbox runs on. One of `sprites` and `e2b`. A provider turns on when its credential is there. Boot refuses an explicit default whose credential is absent. A sandbox that already exists stays on the provider Fountain made it on. |
| `BROKER_LISTEN_PORT` | — | — | A port number, for example `14322`. This turns on credential brokerage (ADR 0019): Fountain runs the egress proxy itself, from the `managoat_broker` library, on this port. Each conversation's proxy session goes in the `broker_sessions` table. Set it, and boot also requires `BROKER_PROXY_URL`. Point your ingress at this port. The proxy speaks plain HTTP, and TLS towards the sandbox is the job of the ingress. Blank leaves brokerage off, and each conversation provisions as before. Set it, and Fountain brokers every account on the deployment. |
| `BROKER_PROXY_URL` | — | With `BROKER_LISTEN_PORT`. | The proxy address a sandbox dials, for example `https://broker.example.com:443`. It is not the same as the listen port when the sandboxes are on a different network from Fountain. Its host is the one host a brokered sandbox may reach. |
| `BROKER_TENANTS` | — | — | **Retired.** It was the operator ratchet of ADR 0019 §9, and it named the accounts to broker. A deployment with `BROKER_LISTEN_PORT` brokers every account, so a list of ids has no answer left, and boot refuses one. A `*` on its own stays valid, and it keeps one job. It asserts that this deployment brokers egress, so boot refuses a `*` with no `BROKER_LISTEN_PORT`. Without that assertion a lost listener disables brokerage for every account, each sandbox holds plaintext credentials, and no other signal reports it. |
| `BROKER_LOG_RETENTION_HOURS` | `168` | — | How long the egress request log keeps a row. `GET /api/conversations/:id/egress` reads it, and `/admin/broker` sums it. A daily job deletes older rows. New request rows store `/[REDACTED]` as the path; the API also hides paths in older rows. Existing database paths remain until this sweep removes them. Historical server logs follow the log storage system's retention policy. |
| `E2B_API_KEY` | — | For the `e2b` provider. | The [E2B](https://e2b.dev) API key. Its presence turns the provider on. |
| `E2B_BASE_URL` | `https://api.e2b.app` | — | Repoints the E2B control plane. |
| `E2B_TEMPLATE` | `base` | — | The template that Fountain creates a new E2B sandbox from. The stock `base` template has no agent CLI, so build one from `images/e2b/` for real use. |
| `E2B_USER` | `sprite` | — | The in-guest user that envd runs a command as. An `images/e2b/` template creates `sprite`. Set it to `user` when you point at the stock `base` template. |
| `SANDBOX_IDLE_TIMEOUT_MINUTES` | `60` | — | No turn activity for this long, and Fountain parks the sandbox. A provider without `:suspend` destroys it instead. The conversation stays [resumable](guides/operate/sandbox-lifetime.md) either way. A `0` turns the bound off, and boot refuses whatever is not a non-negative integer. |
| `SANDBOX_MAX_LIFETIME_HOURS` | `0` (off) | — | A ceiling on one continuous run, whatever the activity. Off by default: nothing stops a sandbox that stays busy. Set it to destroy a sandbox after this many hours. The same boot refusal applies. |

## Registration and accounts

| Variable | Default | Required | Effect |
|---|---|---|---|
| `REGISTRATION_ENABLED` | `auto` | — | `auto` (or unset) leaves signup open only until the instance has an admin, then closes it: the first account can be created, and strangers can't follow. `true` keeps signup open for everyone, for good. `false` closes it from the start. Any other value refuses to boot. Admins open accounts through `POST /api/admin/users` whatever this says. |
| `FIRST_USER_ADMIN` | `false` | — | A `true` promotes the first account that becomes verified to admin, if the instance has never had one. Once any admin has existed it never promotes again, even after that admin is demoted or deleted. The audit trail records it (ADR 0011). Leave it off on an instance that is open to sign-ups, because it hands admin to whoever verifies first. |

## Email

Mail goes out over SMTP. Set `SMTP_HOST` and it is on; leave it unset and it
is off. With mail off, an account self-verifies at registration (ADR 0011),
and nothing can deliver a password-reset email, so a password that somebody
forgets stays forgotten. Read [Configure email](guides/operate/deploy.md#configure-email).

| Variable | Default | Required | Effect |
|---|---|---|---|
| `SMTP_HOST` | — | — | Turns mail on, through this SMTP server. Unset or blank, mail is off. |
| `SMTP_PORT` | `587` | — | The SMTP port. |
| `SMTP_USERNAME` | — | — | Omit it for a relay that wants no authentication. |
| `SMTP_PASSWORD` | — | — | |
| `SMTP_TLS` | `always` | — | STARTTLS by default. Use `never` for a relay on a trusted network that does not offer it. |
| `EMAIL_FROM` | — | With `SMTP_HOST`. | The From address. A prod instance with `SMTP_HOST` refuses to boot without it, because a receiver rejects mail from a domain nobody verified anyway. With mail off it is unused. |
| `SUPPORT_EMAIL` | — | — | Where "contact support" in an account email points. That is the account-deleted email. Unset, the copy names no address. |

`RESEND_API_KEY` and `EMAIL_DELIVERY` are no longer read. Fountain warns at
boot when `RESEND_API_KEY` is set; Resend's SMTP endpoint replaces it.
Leaving `SMTP_HOST` unset replaces `EMAIL_DELIVERY=none`.

## Authentication

| Variable | Default | Required | Effect |
|---|---|---|---|
| `GITHUB_OAUTH_CLIENT_ID` | — | — | Turns the GitHub sign-in button on. Unset, Fountain hides the button, and email and password auth still works. |
| `GITHUB_OAUTH_CLIENT_SECRET` | — | — | |

## Sandbox capacity

| Variable | Default | Required | Effect |
|---|---|---|---|
| `SANDBOX_FLEET_CEILING` | `20` | No. | The default for each provider's ceiling below. Each provider's live sandboxes, across every account, are counted on their own against that provider's ceiling; there is no per-account cap. A start or wake beyond the ceiling of the provider it runs on gets `503 fleet_full` with `Retry-After: 60`; nothing queues. |
| `SANDBOX_FLEET_CEILING_SPRITES` | `SANDBOX_FLEET_CEILING` | No. | The most live Sprites sandboxes. Set it to what your Sprites plan allows (the $20 plan allows about 20). |
| `SANDBOX_FLEET_CEILING_E2B` | `SANDBOX_FLEET_CEILING` | No. | The most live E2B sandboxes. Set it to what your E2B plan allows. |

A full Sprites fleet does not refuse a conversation whose agent runs on E2B,
nor the reverse. A parked sandbox holds no slot; waking it takes a slot on the
provider that holds it.

## Inference

Fountain holds no inference keys of its own and pays for no inference. Each
account runs on its own credentials: its inference credentials, an
environment or vault variable that names one, or its own ChatGPT
subscription for the codex runtime. An account with none for an agent's
provider has nothing to run that agent on. See
[Integrations](integrations/index.md#the-inference-providers).

The `PLATFORM_ANTHROPIC_API_KEY`, `PLATFORM_OPENAI_API_KEY` and
`PLATFORM_GEMINI_API_KEY` variables, the keys set at `/admin/inference`, and
the deployment's ChatGPT subscription were removed. Fountain no longer reads
the variables, and warns at boot when one is still set. Unset them.

## Brand

`/` sends a visitor to the console, and on to sign-in when they are signed
out. The server does not serve the manual: its `/docs` paths redirect to the
published manual (`DOCS_URL`). These variables change what the console calls
the deployment, and where it sends a reader of the manual.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `PRODUCT_NAME` | `Fountain` | — | The name the console, the sign-in page, the OAuth consent screen and each email subject use for this deployment. The CLI, the API and this manual keep the name Fountain, because that is the name of the engine. |
| `BRAND_ASSETS_URL` | unset | — | The URL of the directory with the brand's image files. The directory must contain five files. They are `app-icon.png`, `apple-touch-icon.png`, `favicon-32x32.png`, `favicon-16x16.png` and `favicon.ico`. Unset, the pages use the files in the release image. Set, the pages link the files in this directory, and the CSP permits images from its origin. The value must be an absolute URL. |
| `DOCS_URL` | `https://managoat.com` | — | Where the manual is published. The server does not serve it. A request for `/docs`, a page under `/docs/`, `/llms.txt`, `/llms-full.txt`, `/skill` or `/skills/fountain/SKILL.md` gets a permanent redirect (301) to the same path at this URL. The published manual describes `main`, so it can be ahead of your release. To publish the manual for your own version, run `mix site.build` in `site/` at that release's tag, serve `dist/` from a static host, and set this variable to that host. The value must be an absolute http(s) URL; a trailing slash is ignored. A value on the instance's own host makes those paths answer 404, not redirect to themselves. |

## Proxies and origins

| Variable | Default | Required | Effect |
|---|---|---|---|
| `TRUSTED_PROXIES` | — | Behind a proxy. | Comma-separated CIDRs that Fountain steps over as it resolves the client IP from `X-Forwarded-For`. Without it, the rate limit for each IP collapses into one bucket keyed on the proxy. Set it too broad, and a client can spoof its way past the rate limit. |
| `CHECK_ORIGIN_EXTRA` | — | — | Comma-separated extra origins that can open a LiveView websocket. Fountain always includes your own host. |
| `OAUTH_CLIENTS` | — | — | A JSON array of `{id, name, redirect_uris}`. It names the browser apps that can "Sign in with Fountain". That is OAuth code with PKCE, for a public client, and `decisions/0021` covers it. A redirect URI must match exactly. Unset means none. |
| `API_CORS_ORIGINS` | — | — | Comma-separated browser origins, or a `*`, that can call `/api` with a bearer key from another site. A standalone client such as the conversations app needs that. It is off when unset, and a cookie never crosses an origin either way. |
| `CONVERSATIONS_APP_URL` | `https://fountain-conversations.demo.managoat.com/` | — | Where the console sends a person to watch a conversation. The default is a static build that takes *your* Fountain's URL as input. So it works for a self-hosted server as soon as `API_CORS_ORIGINS` admits `https://fountain-conversations.demo.managoat.com`. Point it at your own copy instead, or set it to `""` to say this deployment has no such app. |

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
