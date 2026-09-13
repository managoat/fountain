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
| `PUBLIC_URL` | — | prod | The base URL that the outside world sees, with the scheme. A prod instance refuses to boot without it, or without the deprecated `FOUNTAIN_DOMAIN`. The old `http://localhost:4000` fallback quietly put localhost links in each verification email. This variable builds each link that leaves the app, which is the verification and reset emails and `llms.txt`. Fountain passes it to each sandbox as `FOUNTAIN_BASE_URL`. An `https://` value also starts the HTTPS redirect, HSTS and the secure cookie flag, and Fountain derives all three from the scheme. |
| `PHX_HOST` | The host of `PUBLIC_URL`. | — | The bare host for the endpoint URL and for the LiveView origin check. Set it only when it differs from the host in `PUBLIC_URL`. |
| `FOUNTAIN_DOMAIN` | — | deprecated | The old combined variable. Fountain still honours it as a fallback for both of the two above. Prefer `PUBLIC_URL` and `PHX_HOST`. |
| `RENDER_EXTERNAL_URL` | — | — | Render sets this on each web service. Fountain reads it as the last fallback for `PUBLIC_URL`, after the deprecated `FOUNTAIN_DOMAIN`. The first deploy from `render.yaml` needs it, because the hostname does not exist before that deploy. An explicit `PUBLIC_URL` has precedence. Set `PUBLIC_URL` when you add a custom domain. |
| `FLY_APP_NAME` | — | — | Fly sets this on each machine. Fountain builds `https://<app>.fly.dev` from it, and reads that as the last fallback for `PUBLIC_URL`. A deploy from `fly.toml` needs it, because that file ships with an app name that `fly launch` replaces. An explicit `PUBLIC_URL` has precedence. Set `PUBLIC_URL` when you add a custom domain. |
| `PHX_SERVER` | `true` in the shipped image. | — | A `1`, `true` or `yes` starts the web listener. A release task runs with `PHX_SERVER=false … eval '…'`. That boots the app, and binds no port. |
| `PORT` | `4000` | — | The HTTP port to listen on. |

## Database

| Variable | Default | Required | Effect |
|---|---|---|---|
| `DATABASE_SSL` | `true` | — | TLS to Postgres. Set `false` for a stock `postgres` container, which serves no TLS. |
| `DATABASE_SSL_VERIFY` | off. | — | Unset, the driver encrypts the connection and verifies no server certificate. `true` verifies it, against the OS trust store, unless you give a CA file. |
| `DATABASE_SSL_CA_FILE` | The OS trust store. | — | The CA bundle to use when `DATABASE_SSL_VERIFY=true`. |
| `POOL_SIZE` | `10` | — | The size of the database connection pool. |
| `MIGRATE_ON_BOOT` | `true` | — | Whether a release runs the migrations that are due before it serves. A `false`, and also `0` or `no`, makes the pod serve and no more. Use that for a deployment that runs the migrations once, in a Job. Read [migrations in a Job](guides/operate/database.md#run-migrations-in-a-job). `bin/migrate` always migrates, whatever you set here. **Nothing checks that the Job ran.** A pod that skips the migrations boots against a database nobody migrated. It then fails on the first query. |

## Sandboxes

| Variable | Default | Required | Effect |
|---|---|---|---|
| `SPRITES_TOKEN` | — | For conversations. | The platform token for [sprites.dev](https://sprites.dev). The app boots without it, and each conversation then fails. Never show it to a tenant, because it pays for each sandbox. |
| `SPRITES_BASE_URL` | `https://api.sprites.dev` | — | Repoints the sandbox API. Whatever you point it at must implement the same contract, and Fountain bundles no alternative. |
| `SPRITES_TIMEOUT_MS` | `30000` | — | Bounds each HTTP call to the Sprites API. A long command, such as a package install or a clone, sets its own timeout for that call. Boot refuses a value that is not positive. |
| `SANDBOX_PROVIDER` | `sprites` | — | Which backend a new sandbox runs on. One of `sprites`, `e2b`, `daytona` and `runner`. A hosted provider turns on when its credential is there. Boot refuses an explicit default whose credential is absent. A sandbox that already exists stays on the provider Fountain made it on. |
| `SANDBOX_RUNNERS_ENABLED` | `true` | — | A [self-hosted runner](integrations/runners.md) needs no credential. A `false` hides the `runner` provider, and refuses a `fountain runner` connection. |
| `BROKER_LISTEN_PORT` | — | — | A port number, for example `14322`. This turns on credential brokerage (ADR 0019): Fountain runs the egress proxy itself, from the `managoat_broker` library, on this port on every replica. Each conversation's proxy session goes in the `broker_sessions` table, so any replica can serve a sandbox. Set it, and boot also requires `BROKER_PROXY_URL`. Point your ingress at this port. The proxy speaks plain HTTP, and TLS towards the sandbox is the job of the ingress. Blank leaves brokerage off, and each conversation provisions as before. Set it, and Fountain brokers every account on the deployment. |
| `BROKER_PROXY_URL` | — | With `BROKER_LISTEN_PORT`. | The proxy address a sandbox dials, for example `https://broker.example.com:443`. It is not the same as the listen port when the sandboxes are on a different network from Fountain. Its host is the one host a brokered sandbox may reach. |
| `BROKER_TENANTS` | — | — | **Retired.** It was the operator ratchet of ADR 0019 §9, and it named the tenants to broker. A deployment with `BROKER_LISTEN_PORT` brokers every account, so a list of ids has no answer left, and boot refuses one. A `*` on its own stays valid, and it keeps one job. It asserts that this deployment brokers egress, so boot refuses a `*` with no `BROKER_LISTEN_PORT`. Without that assertion a lost listener disables brokerage for every tenant, each sandbox holds plaintext credentials, and no other signal reports it. |
| `BROKER_SESSION_TTL_SECONDS` | `21600` | — | How long a proxy session token lives. Fountain mints a new one on each provision and each reattach, and again before a turn when the current one is near its end. Both backends accept 300 to 604800. |
| `BROKER_LOG_RETENTION_HOURS` | `168` | — | How long the egress request log keeps a row. `GET /api/conversations/:id/egress` reads it, and `/admin/broker` sums it. A daily job deletes older rows. |
| `BROKER_ALLOW_UNENFORCED` | `false` | — | A `true` lets a brokered conversation run on a provider that has no network policy, for example a self-hosted runner. The sandbox then holds placeholders and a proxy address, but nothing stops a process from a direct connection that avoids the proxy. For development only. |
| `BROKER_URL` | — | — | **Retired.** It selected the Agent Vault backend. Fountain now runs the proxy itself, so this backend no longer exists. Boot refuses it, because a deployment that still sets it would otherwise broker nothing and say nothing. Remove it, and set `BROKER_LISTEN_PORT`. |
| `BROKER_TOKEN` | — | — | **Retired.** It was the credential `BROKER_URL` used. Boot warns and ignores it. Remove it from your secret store: it is a credential for a service that no longer exists. |
| `E2B_API_KEY` | — | For the `e2b` provider. | The [E2B](https://e2b.dev) API key. Its presence turns the provider on. |
| `E2B_BASE_URL` | `https://api.e2b.app` | — | Repoints the E2B control plane. |
| `E2B_TEMPLATE` | `base` | — | The template that Fountain creates a new E2B sandbox from. The stock `base` template has no agent CLI, so build one from `images/e2b/` for real use. |
| `E2B_USER` | `sprite` | — | The in-guest user that envd runs a command as. An `images/e2b/` template creates `sprite`. Set it to `user` when you point at the stock `base` template. |
| `DAYTONA_API_KEY` | — | For the `daytona` provider. | The [Daytona](https://daytona.io) API key. Its presence turns the provider on. |
| `DAYTONA_API_URL` | `https://app.daytona.io/api` | — | Repoints the Daytona API, for a Daytona you host yourself. |
| `DAYTONA_SNAPSHOT` | The org default. | — | The snapshot, which is an image, that Fountain creates a new Daytona sandbox from. The organization must hold it. The default image has no agent CLI, so build one from `images/daytona/` for real use. |
| `SANDBOX_IDLE_TIMEOUT_MINUTES` | `60` | — | No turn activity for this long, and Fountain parks the sandbox. A provider without `:suspend` destroys it instead. The conversation stays [resumable](guides/operate/sandbox-lifetime.md) either way. A `0` turns the bound off, and boot refuses whatever is not a non-negative integer. |
| `SANDBOX_MAX_LIFETIME_HOURS` | `0` (off) | — | A ceiling on one continuous run, whatever the activity. Off by default: nothing stops a sandbox that stays busy. Set it to park a persistent home, or destroy an ephemeral sandbox, after this many hours. The same boot refusal applies. |
| `CHECKPOINT_CREATION_ENABLED` | `false` | — | Set to `true`, and Fountain takes a checkpoint of each persistent home when it parks, on a provider that has checkpoints (Sprites). The checkpoint belongs to that one machine. It can roll the machine back, and it cannot rebuild a machine that the provider lost. Each park adds one checkpoint, and Fountain does not delete old ones. The same flag also makes Fountain checkpoint each environment after it provisions a sandbox, which Sprites cannot restore into a new sandbox. |
| `LOG_OUTPUT_BUDGET_MB` | `50` | — | The durable log volume for one conversation. Once a conversation has persisted this much sandbox output, Fountain writes one truncation marker and discards the rest. Retention bounds age, and this bounds rate. The same `0` rule and the same boot refusal apply. |

## Deployed ACP fixture

Use these only on an isolated test instance. The fixed fixture runtime exercises
the real sandbox/ACP path without model inference. It does not enable arbitrary
custom harnesses. See [Test the deployed ACP path](integrations/acp.md#test-the-deployed-acp-path).

| Variable | Default | Required | Meaning |
|---|---|---|---|
| `DEPLOYED_ACP_FIXTURE_ENABLED` | `false` | — | Set exactly `true` to offer the fixed `fountain-fixture` runtime on a test deployment. The account UUID below is also required. |
| `DEPLOYED_ACP_FIXTURE_USER_ID` | — | With the fixture enabled | UUID of the dedicated verified test account allowed to create and launch fixture agents. Other accounts are refused. |

## Webhooks

| Variable | Default | Required | Effect |
|---|---|---|---|
| `WEBHOOKS_ENABLED` | `true` | — | A `false` stops every outbound [webhook](reference/webhooks.md). An endpoint stays saved and gets nothing. Use it on a deployment with no outbound egress. |
| `WEBHOOK_ALLOW_HTTP` | `false` | — | A `true` lets an endpoint URL use plain `http://`, for a receiver on your own network. It relaxes the scheme rule alone. Fountain refuses a loopback, link local or RFC1918 target either way, at every request. |

## Registration and accounts

| Variable | Default | Required | Effect |
|---|---|---|---|
| `REGISTRATION_ENABLED` | `true` | — | A `false` closes signup entirely. Somebody will find an open instance on the public internet. |
| `REGISTRATION_ALLOWED_EMAIL_DOMAINS` | any | — | A comma-separated list. Fountain refuses a signup outside these domains. Empty means no restriction. |
| `UNVERIFIED_PRUNE_AFTER_DAYS` | `30` | — | Fountain deletes an account that never verified its email after this many days. Such an account can sign in and reach nothing, so it is a row and not a user. A `0` turns the sweep off. |
| `UNVERIFIED_PRUNE_EXEMPT` | — | — | Comma-separated email substrings that the sweep never prunes. Use it for an operator or test account that stays unverified on purpose. |
| `SECRET_EXPIRY_NOTICE_DAYS` | `7` | — | Days before a vault secret's recorded expiry that Fountain emails the owner. The vault page shows an amber badge for the same window. A `0` turns the notice off. |
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
| `SUPPORT_EMAIL` | — | — | Where "contact support" in an account email points. Those are the suspension and deletion emails. Fountain also mails a `POST /api/support/reports` report there. Unset, the copy names no address, and Fountain mails no report. |
| `SUPPORT_GITHUB_REPO` | — | — | An `owner/repo`. Each support report also becomes a GitHub issue there, with the labels `support` and the category. It needs `SUPPORT_GITHUB_TOKEN`. |
| `SUPPORT_GITHUB_TOKEN` | — | — | A token with `issues:write` on `SUPPORT_GITHUB_REPO`. |

## Authentication

| Variable | Default | Required | Effect |
|---|---|---|---|
| `GITHUB_OAUTH_CLIENT_ID` | — | — | Turns the GitHub sign-in button on. Unset, Fountain hides the button, and email and password auth still works. |
| `GITHUB_OAUTH_CLIENT_SECRET` | — | — | |
| `GOOGLE_OAUTH_CLIENT_ID` | — | — | Turns the Google connection on, where the deployment runs the egress broker. A tenant connects Gmail and Google Calendar once on the Connections page, and Fountain keeps the refresh token. Register a Web client in Google Cloud with the redirect URI `<PUBLIC_URL>/connections/google/callback`, and enable the Gmail and Calendar APIs. Unset, the page says the feature is not configured. |
| `GOOGLE_OAUTH_CLIENT_SECRET` | — | — | |
| `GOOGLE_OAUTH_SCOPES` | the defaults in the catalog | — | The scopes the Google provider asks for, space-separated. Use it when your app verification does not cover a default scope. A scope you do not request is a product that does not light up, not an error. |
| `MICROSOFT_OAUTH_CLIENT_ID` | — | — | Turns the Microsoft connection on: Outlook mail, calendar and Teams chat through one sign-in, brokered to `graph.microsoft.com`. Register a web app in Microsoft Entra on the `common` endpoint, with the redirect URI `<PUBLIC_URL>/connections/microsoft/callback`. Unset, the page says the provider is not configured. |
| `MICROSOFT_OAUTH_CLIENT_SECRET` | — | — | |
| `MICROSOFT_OAUTH_SCOPES` | the defaults in the catalog | — | The scopes the Microsoft provider asks for, space-separated. Keep `offline_access` in the list: without it, Microsoft issues no refresh token. |
| `SLACK_OAUTH_CLIENT_ID` | — | — | Turns the Slack connection on: a user token per workspace, brokered to `slack.com`. Create a Slack app with the redirect URL `<PUBLIC_URL>/connections/slack/callback`. Unset, the page says the provider is not configured. |
| `SLACK_OAUTH_CLIENT_SECRET` | — | — | |
| `SLACK_OAUTH_USER_SCOPES` | the defaults in the catalog | — | The user scopes the Slack provider asks for, space-separated. These are `user_scope` values, not bot scopes. |

## Payment

<!-- "billing" is a Technical Name here: CREDITS_ENABLED is the flag, and the
     Elixir context carries the word. STE exempts a Technical Name from Rule
     3.4, and the linter has no vocabulary hook for that rule. -->
<!-- vale STE.IngForms = NO -->

| Variable | Default | Required | Effect |
|---|---|---|---|
| `CREDITS_ENABLED` | `false` | — | Credits on. Off by default: on a self-hosted instance there is nothing to sell. On, every account holds a credit balance, turns and contacts burn it, and a zero balance refuses new work. |
| `BILLING_ENABLED` | — | — | The old name of `CREDITS_ENABLED`. Fountain reads it for one release and writes a warning at boot. `CREDITS_ENABLED` wins when you set both. |
| `STRIPE_SECRET_KEY` | — | For billing. | The Stripe API key. |
| `STRIPE_WEBHOOK_SECRET` | — | For billing. | Verifies the signature on a `POST /api/stripe/webhook`. |
| `PROVIDER_HOURLY_CENTS` | — | No. | What you pay each sandbox provider, in cents per sandbox hour, as `sprites=10.76,e2b=5.45`. Rates can be fractional. A provider you leave out stays unpriced. |
| `PROVIDER_COST_BASIS` | `active` | No. | Which hours the provider rate multiplies. An `active` counts every hour a sandbox was awake. A `turn` counts only the hours with a prompt in flight. Use `turn` where the provider drops to near-zero between prompts. |
| `AGENTMAIL_INBOX_CENTS` | — | No. | What AgentMail charges for one inbox each month, in cents. |
| `AGENTPHONE_NUMBER_CENTS` | — | No. | What AgentPhone charges for one number each month, in cents. |
| `AGENTMAIL_MESSAGE_CENTS` | — | No. | What AgentMail charges for one email, in cents. Give the fraction, such as `0.2` for $2 per 1,000 emails. A whole number rounds this rate to zero. |
| `AGENTPHONE_MESSAGE_CENTS` | — | No. | What AgentPhone charges for one SMS, in cents. Fountain counts an inbound message too, because AgentPhone charges for it. |
| `SANDBOX_RESERVE_CENTS` | `200` | No. | The credit one live sandbox needs in the balance. A tenant may run `balance / reserve` sandboxes at once, between the floor and the ceiling. |
| `SANDBOX_CAP_FLOOR` | `2` | No. | The fewest sandboxes a tenant with a positive balance may run at once. |
| `SANDBOX_CAP_CEILING` | `20` | No. | The most sandboxes one tenant may run at once, unless an admin override raises it. |
| `SANDBOX_FLEET_CEILING` | `20` | No. | The most live sandboxes across every tenant. Set it to what your sandbox provider plan allows. A start beyond it gets `503 fleet_full`. |
| `SANDBOX_QUEUE_MAX_DEPTH` | `10` | No. | The most sandbox requests one tenant holds at once. A request beyond it keeps the immediate capacity error. |
| `SANDBOX_QUEUE_MAX_WAIT_SECONDS` | `3600` | No. | How long a sandbox request waits for capacity before Fountain expires it. |
| `FOUNTAIN_EXECUTION_LIMITS` | `{}` | No. | JSON per-turn host ceiling: `wall_time_seconds`, `max_model_turns`, `max_estimated_cost_usd`. Each configured value must be positive; time and turns must be integers. Read at boot; invalid input refuses startup. Requests inherit the stricter host/account ceiling. Keep unset until runtime enforcement and later-turn/recovery checks are integrated: nonempty effective limits currently refuse launch with `422 execution_limits_unsupported`. This is not an aggregate spend cap. |
| `FOUNTAIN_EXECUTION_DEADLINE_WORKER` | on when `FOUNTAIN_EXECUTION_LIMITS` gives a ceiling | No. | If this node runs the deadline coordinator. The coordinator polls `turn_executions`, so it stays off where no host ceiling applies. Set `true` if you give an account a ceiling but no host ceiling. Set `false` to stop the poll on any node. A change needs a restart. |
| `FOUNTAIN_EXECUTION_DEADLINE_INTERVAL_MS` | `5000` | No. | The interval at which the coordinator looks for due deadlines. Each deadline is absolute and durable, so a larger value costs precision and not safety. |
| `CREDIT_OPENING_CENTS` | `500` | No. | The credit a new account starts with, in cents. |
| `CREDIT_OPENING_DAYS` | `14` | No. | How many days the opening credit lasts. |
| `TEAM_CONTACT_CEILING` | `10` | No. | The most teammate contacts one account may hold at once. |
| `BUZZ_IDENTITY_CEILING` | `10` | No. | The most hosted Buzz agents one account may run at once. Each one is a permanent process on the Fountain pods. |
| `CREDIT_TURN_HOUR_CENTS` | `25` | No. | What a tenant pays for one hour of turn time, in whole cents, from their prepaid balance. |
| `CREDIT_NUMBER_CENTS` | — | No. | What a tenant pays for one phone number each month, in whole cents. Unset means the number burns nothing. |
| `CREDIT_INBOX_CENTS` | — | No. | What a tenant pays for one inbox each month, in whole cents. Unset means the inbox burns nothing. |
| `CREDIT_EMAIL_MESSAGE_CENTS` | — | No. | What a tenant pays for one email, in whole cents. Unset means an email burns nothing. |
| `CREDIT_SMS_MESSAGE_CENTS` | — | No. | What a tenant pays for one SMS, sent or received, in whole cents. Unset means an SMS burns nothing. |
| `CREDIT_PACKS_CENTS` | `1000,2500,10000` | No. | The credit packs a tenant can buy, in cents, as a list. |
| `PRINCIPAL_DEFAULT_TTL_SECONDS` | `86400` | No. | How long a claimable principal lasts when the application names no `expires_in`. |
| `PRINCIPAL_MAX_TTL_SECONDS` | `604800` | No. | The longest a claimable principal may last. Fountain clamps a longer `expires_in` to this. |
| `PRINCIPAL_MAX_GRANT_CENTS` | `500` | No. | The most an application may put into one principal, in cents. |
| `PRINCIPAL_MAX_OUTSTANDING` | `500` | No. | The most unclaimed principals one application may hold at once. |
| `PRINCIPAL_MAX_PER_HOUR` | `500` | No. | The most principals one application may open each hour. |
| `PRINCIPAL_PURGE_AFTER_DAYS` | `7` | No. | How long a closed grant stays readable before Fountain deletes the principal. |

<!-- vale STE.IngForms = YES -->

The rate variables are different from every other price here. They are what
**you pay**, not what a tenant pays, and no other part of Fountain knows them.
The admin finance panel at `/admin/finance` holds them next to your revenue,
per tenant. The panel switches between the two hour bases per view. Compare
both totals against a real invoice, then keep the basis that matches.

Each rate can be fractional. Per-message rates usually are, and a whole number
rounds them to zero.

Set none of them and the panel still works. It shows hours, inboxes, numbers
and message counts, and it shows `—` in each money column. A rate you do not
set stays `—` and never becomes `$0`, because a cost of zero and a cost nobody
told us about are different facts.

## Platform inference

Fountain can hold its own inference keys. A tenant with no credential of their
own then runs on a Fountain key, and the tokens burn their credit balance. The
tenant's own credential always wins. There is no per-agent switch.

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
| `PLATFORM_INFERENCE_DAILY_CENTS` | `5000` | No. | The most the keys above may cost in one UTC day, across every tenant. A conversation beyond it gets `503 platform_inference_unavailable`. It works only with `CREDITS_ENABLED=true`. |
| `PLATFORM_INFERENCE_RATES` | — | No. | Per-model prices, in cents per million tokens. See below. |

### The ChatGPT account for the codex runtime

Fountain can also hold one ChatGPT account for the `codex` runtime. A codex
agent whose tenant has no OpenAI key then runs on that account, before the
`PLATFORM_OPENAI_API_KEY` key. Opencode on an `openai/` model still needs a
key. The tenant's own key always wins.

Connect the account at `/admin/inference`. There are three ways in.

- **A device code.** Fountain requests a code, shows the code and a link, and
  waits for your approval on the ChatGPT page. The account must permit
  device-code login in its ChatGPT security settings.
- **A pasted `auth.json`.** Run `CODEX_HOME=$(mktemp -d) codex login` on a
  laptop and paste the file it writes. This is the recipe OpenAI documents
  for CI. After the paste, the file belongs to Fountain. Do not use it
  anywhere else, or both copies stop.
- **A workspace access token.** A ChatGPT Business or Enterprise workspace
  can mint a static token in its admin console. Paste the token and its
  expiry date. This is the credential OpenAI sanctions for servers, so use it
  where you have one.

Fountain keeps the refresh token, encrypted under `MASTER_SECRETS_KEY`, and
renews the access token itself. A sandbox never sees either token. The
sandbox holds a placeholder, and the egress broker puts the real token into
the request to `chatgpt.com`. Each connect and disconnect leaves an
`admin.platform_chatgpt` event on the admin activity page.

A personal subscription is one account for every tenant on the deployment.
That pattern is behind reported account bans, and it is an operator's own
risk. The page says so.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `PLATFORM_CHATGPT_REFRESH_MARGIN_SECONDS` | `900` | No. | How many seconds before its expiry Fountain renews the access token. Set it longer than your longest turn, because codex cannot renew the token itself. |
| `PLATFORM_CHATGPT_KEEPALIVE_DAYS` | `6` | No. | How many days an idle account may go without a renewal. A daily job renews it after that, so the account does not lapse while nobody runs codex. |

### What a tenant pays

Fountain prices these tokens at the provider's list price. There is no markup.
The margin on a conversation is the turn time (`CREDIT_TURN_HOUR_CENTS`), not
the tokens. A closed platform turn posts a `burn_inference` debit beside its
`burn_turn` debit. The account credits page names both, and the
finance panel at `/admin/finance` shows the two totals.

The gate stays the balance. An account at zero cannot start the next
conversation, and the answer is `402 insufficient_credits`. A comped account
pays nothing, here as everywhere.

### The daily ceiling

`PLATFORM_INFERENCE_DAILY_CENTS` is a circuit breaker for the whole
deployment. One bad day cannot cost more than this number. A refusal is a 503
and not a 402, because the limit belongs to you and not to the tenant. A
tenant with their own credential never meets this ceiling.

The ceiling trails the real spend, because Fountain writes the ledger rows on
a timer. The ceiling bounds a day. It does not bound a minute.

#### With credits off there is no ceiling

Fountain counts the day from the credit ledger. `CREDITS_ENABLED=false` prices
nothing and writes no ledger rows, so it also counts nothing.

**A deployment with credits off and a platform key set has no ceiling at all.**
Every tenant with no credential of their own runs on your key, and no limit
stops the spend. For a self-hoster that is the correct behaviour, because the
key is yours and the provider bill is yours. Do not set a platform key with
credits off unless you accept an unbounded bill.

### Rate overrides

Fountain ships a rate card for the models in the catalog. Each rate carries
the date somebody read it from the provider. A provider that moves a price
makes the card stale, and `PLATFORM_INFERENCE_RATES` corrects it without a new
release.

Give one entry per model, and separate the entries with a comma. Each entry
has five fields with a colon between them. The fields are the model, the input
price, the output price, the cached-read price and the cached-write price.
Prices are cents per million tokens, and a fraction is valid.

```bash
PLATFORM_INFERENCE_RATES="anthropic/claude-opus-5:500:2500:50:625,openai/*:500:3000:50:500"
```

A `provider/*` entry is the price for every model of that provider with no
entry of its own.


## Public pages

The `/` page is not the same page on every deployment. The Fountain project's
own site shows the product page, with the prices and the opening credit. Every other
deployment shows a plain front door: the name, a way in, and a link to this
manual.

Your deployment is not the Fountain project, so the front door is the default.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `PRODUCT_NAME` | `Fountain` | — | The name the console, the sign-in page, the OAuth consent screen and each email subject use for this deployment. Set it when you sell a hosted deployment under a different brand. The CLI, the API and this manual keep the name Fountain, because that is the name of the engine. When the two differ, each manual page opens with one line that says so. |
| `BRAND_ASSETS_URL` | unset | — | The URL of the directory with the brand's image files. The directory must contain seven files. They are `app-icon.png`, `apple-touch-icon.png`, `favicon-32x32.png`, `favicon-16x16.png`, `favicon.ico`, `og-card.png` (1200 by 630 pixels) and `mark-mono.png`. The last one is the mark in one colour on a transparent ground, for the public pages. Unset, the pages use the files in the release image. Set, the pages link the files in this directory, and the CSP permits images from its origin. The value must be an absolute URL. |
| `MARKETING_SITE` | `false` | — | A `true` serves the Fountain project's product page at `/` and its integrations page at `/integrations`. It also puts the project's copyright line in the footer. Turn it on only if you operate the project's own site. |

## Legal pages

These four variables carry the identity that `/terms` and `/privacy` render.
That is the operator's identity, and not the Fountain project's.

Set all four, or set none. A partial set refuses to boot. With none set, the
two pages return 404, and their links disappear from signup and the footer.

There is one exception. With payment turned on, the pages stay up and carry
loud `{{...}}` placeholders until you configure them. An instance that charges
money must publish terms.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `LEGAL_ENTITY` | — | No. | The legal entity that operates this instance, such as `Example Corp Inc.` |
| `LEGAL_CONTACT_EMAIL` | — | No. | The contact address that both pages show. |
| `LEGAL_JURISDICTION` | — | No. | The law and the venue that govern, such as `the State of Delaware, USA`. |
| `LEGAL_EFFECTIVE_DATE` | — | No. | The "Last updated" date on both pages. |

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
[Clustering](architecture.md#clustering) for what breaks without it. <!-- vale disable-line STE.IngForms -->

| Variable | Default | Required | Effect |
|---|---|---|---|
| `CLUSTER_DNS_QUERY` | — | Multi-replica. | The DNS name that Fountain polls to discover a peer. In Kubernetes that is a headless service. Empty or unset, the cluster is off. |
| `RELEASE_NAME` | Set by the release. | — | The node basename that peer discovery uses. It must match what each node registered as. The release sets it, so override it only when you know why. |
| `DNS_CLUSTER_QUERY` | — | — | A second, separate discovery mechanism, which is Phoenix's `DNSCluster`. Leave it unset when you use `CLUSTER_DNS_QUERY`. |

## Observability

| Variable | Default | Required | Effect |
|---|---|---|---|
| `METRICS_PORT` | `9568` in prod, off elsewhere. | — | The private Prometheus listener, which serves `/metrics` and `/health`. A `""` or a `0` turns it off. Keep it off the public internet. |
| `SENTRY_DSN` | — | — | Turns error reports on. Unset, the SDK is inert and nothing leaves the instance. It accepts sentry.io, or any endpoint that speaks the Sentry API, such as GlitchTip. |
| `SENTRY_ENVIRONMENT` | The build env. | — | The environment tag on a reported error. |
| `FOUNTAIN_BUILD_SHA` | Set by the image build for a release image, or by the deployment for a main-line image. | — | Matches an error and a trace to a deploy. The app footer shows it too. |
| `OTEL_SERVICE_NAME` | `fountain` | — | The service name on an exported trace. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `HONEYCOMB_ENDPOINT` | — | The OTLP target for a trace export, over HTTP with protobuf. |
| `OTEL_EXPORTER_OTLP_HEADERS` | — | — | The `key=val,key=val` headers on a trace export. |
| `HONEYCOMB_ENDPOINT` | `https://api.honeycomb.io` | — | The Honeycomb shortcut for the endpoint above. |
| `HONEYCOMB_API_KEY` | — | — | The Honeycomb shortcut that adds the `x-honeycomb-team` header. |

Fountain configures a trace export in production, while it serves, and nowhere
else. It is **off by default**. It exports a span only when you explicitly set
`OTEL_EXPORTER_OTLP_ENDPOINT`, `HONEYCOMB_ENDPOINT` or `HONEYCOMB_API_KEY`.

The OTel SDK also honours its own standard variables, and those win. Set
`OTEL_TRACES_EXPORTER=otlp` or `=none` to force the export on or off, whatever
the table above says.

## Hosted Buzz agents

Fountain can host the `buzz-acp` harness for a
[Buzz](https://github.com/block/buzz) agent (ADR 0020). A Buzz agent then
keeps a body on its relay, with no desktop up.

The image bakes the harness binary in, for both amd64 and arm64. These two
variables tune where it runs, and how its ACP child reaches back. An operator
rarely sets either one, because the defaults are correct for the packaged
image.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `BUZZ_ACP_BASE_URL` | The loopback endpoint, `http://127.0.0.1:$PORT`. | — | The base URL that the harness's ACP child, `fountain acp`, uses to reach this instance. It defaults to the loopback, so harness traffic never leaves the pod. Override it only to point the child at a different Fountain endpoint. |
| `FOUNTAIN_CLI_PATH` | `/usr/local/bin/fountain` | — | The path to the `fountain` CLI that the harness runs as its ACP child. The image bakes it at the default, so override it only for a layout that is not standard. |
| `BUZZ_ACP_PATH` | Wherever the bundled image installs it, `/usr/local/lib/fountain-buzz/buzz-acp`. | — | The path to the `buzz-acp` harness binary. Set it only for an installation that is not standard. The extension finds the bundled one by itself, and a core image has none, so an unset value is correct on both. The binary must report the version in `apps/fountain_buzz/buzz-acp.version`, or no harness starts. |

Upstream publishes `buzz-acp` for amd64 alone. So Fountain builds it for both
architectures from source, and bakes it in. Read
`.github/workflows/buzz-acp-publish.yml`.

## Feature flags

PostHog evaluates a per-user flag, `Fountain.FeatureFlags`, when you set a
project key. Fountain caches an answer for one minute for each user.

When PostHog is unreachable, Fountain reuses the last answer it gave. With no
answer at all, each flag reads off, so an outage never turns a feature on.
Without PostHog you can force a flag on for each user.

A flag over a feature that shipped is the exception. The `connections` flag
reads on where you set no `POSTHOG_PROJECT_API_KEY`. A deployment with no flag
service keeps the feature, and an upgrade does not take it away. Where you
configure PostHog, the answer from PostHog decides.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `POSTHOG_PROJECT_API_KEY` | — | — | The PostHog *project* API key. That is the public `phc_…` token, and not a personal key. Unset, Fountain looks up no flag remotely. |
| `POSTHOG_HOST` | `https://us.i.posthog.com` | — | The PostHog ingestion host. Use `https://eu.i.posthog.com` for EU Cloud, or an instance you host yourself. |
| `FEATURE_FLAGS_ON` | — | — | Comma-separated flag keys, forced on for each user, such as `team_comms` or `openai_compat`. It wins over PostHog. |

For a hosted Connections rollout, leave the global override unset. Enable
`connections` for the intended test accounts in PostHog, with evaluation
runtime set to `all`. Enable the credential broker too. The broker is the
switch that decides which accounts get the feature.

The flag holds only the doors that add a credential. Those doors connect an
account, define a provider and attach a secret to a host. An account that loses
the flag keeps what it has. The console and the API still list it, revoke it
and delete it.

## Product analytics

The same project key sends product events to PostHog. Fountain captures most
of them on the server.

Set no key and Fountain sends nothing. Set a key and the events go to your own
PostHog project.

Fountain captures an event at three points in the code. Each point is a
function that the operation must call, so Fountain captures a new action
without a new call site.

- Every audited change, under the name of its audit action. `agent.created`
  and `vault.secret.write` are examples.
- Every usage event that the meter records, with a `usage.` prefix.
  `usage.turn_started` is an example.
- The end of a conversation turn, as `conversation.turn.done`,
  `conversation.turn.failed` or `conversation.turn.interrupted`.

Each API write leaves a second audit row named after the request line. Fountain
sends these rows as one event, `api.request`. The route is a property, not part
of the name. A name per route makes an event type per route, and each event
type fills the list that every person on the project reads. A property keeps
the count of names at one, and PostHog can break down a property.

The `api.request` event carries `method`, `route`, `status` and `status_class`.
Together they answer which endpoints your callers use, and which of them fail.
A request that Fountain refuses before it knows the account has no person, so
Fountain sends no event for it. The audit trail keeps that row.

One kind of audited change stays out of PostHog. The audit trail keeps it. It
is an API key that Fountain issued to itself. A sandbox and a Buzz harness each
get a key, and an OAuth token is a key. These were 70 percent of the trail in
one day. Fountain keeps a key that a person makes in the console, or through
the API.

Fountain also captures `$pageview` for each console page, `$identify` when the
shape of an account changes, and `$feature_flag_called` when it reads a flag.
Each event carries the flags that Fountain already knows for that person, as
`$feature/<key>`.

## Web analytics

The public pages load the PostHog browser library. These pages are the home
page, the legal pages, the manual and the sign-in flow. The console loads no
browser library, and Fountain captures console pageviews on the server.

The split has a reason. A pageview from the server has no session, no referrer
and no device. Fountain also drops an event with no account, so a visitor with
no account is invisible to it. Only a browser knows these facts, and only the
public pages have visitors who are not yet accounts.

The browser library sends anonymous events. It makes no person profile for a
reader. A person profile appears when an account appears.

### PostHog records the public pages

PostHog session replay makes a record of each visit to a public page. The
record covers the home page, the legal pages, the manual and the sign-in flow.

PostHog does not record the console. This includes the dashboard, the agent and
vault pages, and the admin pages. The console loads no browser library, so
there is no recorder on those pages.

Fountain masks every input in the record. This matters on the sign-in and
sign-up pages, where the mask hides the email address. PostHog masks a password
field in all conditions.

The switch for replay is a PostHog project setting, not a Fountain setting. To
stop the records, turn replay off in your PostHog project. To stop the browser
library and the records together, set `POSTHOG_BROWSER_CAPTURE` to `false`.

Fountain joins the two halves at sign-in. It reads the anonymous id from the
PostHog cookie, and it tells PostHog to merge that visitor into the account.
The pages a person read before the account then belong to the account. Fountain
reads this cookie and writes nothing to it. A reader with no cookie signs in as
normal, and Fountain sends no merge.

Each browser event carries `surface: "public"`. Each console pageview carries
`surface: "console"`. Use this property to hold the two apart.

Fountain adds the PostHog origins to the Content Security Policy of the public
pages. The console keeps its own policy, which names no PostHog origin.
Fountain reads `POSTHOG_HOST` for both origins. PostHog Cloud serves the
library from a second origin, and Fountain derives that origin from the first.

Fountain sends no secret value, no environment variable value, no prompt and
no agent output. An event holds the name of the action, the type of the
resource, and counts or sizes.

Delivery is best-effort. Events go to a queue and leave in batches. Fountain
drops them if the queue is full or if PostHog answers with an error, and it
counts each drop on the `fountain.analytics.dropped` telemetry event. An
analytics failure cannot fail the operation it measures.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `POSTHOG_CAPTURE` | `true` | — | Set it to `false` to stop product events. Flag evaluation continues. |
| `POSTHOG_BROWSER_CAPTURE` | `true` | — | Set it to `false` to keep the PostHog browser library off the public pages. This also stops the session recordings. Server capture continues. |
| `POSTHOG_PERSON_PII` | `true` | — | Set it to `false` to keep the account email out of PostHog. The person is then known by user id alone. |
| `POSTHOG_INSTANCE` | `PHX_HOST` | — | The name of this deployment. Each event is a member of this PostHog group, so two deployments that report to one project stay apart. |

## Teammate email and phone

Behind the `team_comms` flag, you can give a teammate an email address, from
[AgentMail](https://agentmail.to), and a phone number, from
[AgentPhone](https://agentphone.ai). The teammate then gets MCP tools to send
and read on both.

Fountain holds the provider keys and serves the tools itself, so a key never
enters a sandbox. With either key unset, the feature reports itself
unavailable, even where the flag is on. `GET /api/team/comms` reports that
state, and `POST /api/team/:agent_id/contact` provisions a contact. Read
[Team](api.md#team).

| Variable | Default | Required | Effect |
|---|---|---|---|
| `AGENTMAIL_API_KEY` | — | — | The AgentMail API key. Fountain creates a teammate inbox under it. |
| `AGENTMAIL_BASE_URL` | `https://api.agentmail.to` | — | The AgentMail API host. Use `https://api.agentmail.eu` for the EU region. |
| `AGENTMAIL_DOMAIN` | — | — | A custom domain that you verified, for a teammate address. Unset, Fountain uses AgentMail's shared domain. |
| `AGENTPHONE_API_KEY` | — | — | The AgentPhone API key. Fountain provisions a teammate number under it. |
| `AGENTPHONE_BASE_URL` | `https://api.agentphone.ai` | — | The AgentPhone API host. |
| `AGENTPHONE_WEBHOOK_SECRET` | — | — | The secret that AgentPhone returned when somebody pointed the account's master webhook at `POST /api/webhooks/agentphone` on this instance. It verifies an inbound delivery. A text to a teammate's `prompt_from_number` then becomes a prompt in its conversation. Unset, the endpoint answers 503 and processes nothing inbound. |
