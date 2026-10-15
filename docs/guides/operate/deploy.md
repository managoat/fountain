# Deploy an instance

This guide takes a Managoat instance from first boot to its first successful
conversation with Docker Compose. It then covers what a public instance
needs: TLS and a public URL, a database you manage, and email. For Kubernetes,
Fly.io or Coolify, read [Deploy on another host](hosts.md) as well.

## Before you start

You need Docker Engine with Compose v2, `openssl`, and a sandbox provider
token ([Self-host Managoat](../../self-hosting.md#what-you-must-have) says
where one comes from). Managoat requires Postgres 16 or newer; the compose
file runs one for you.

Your machine must reach `ghcr.io`, which holds the published image. If your
network blocks it, comment the `image:` line in `docker-compose.yml` and
uncomment the `build: .` line under it, and compose builds the image from
this checkout.

## Bring it up

```bash
git clone https://github.com/managoat/fountain
cd fountain

cp .env.compose.example .env
echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')" >> .env
echo "MASTER_SECRETS_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')" >> .env
# add your SPRITES_TOKEN to .env

docker compose up -d
```

Back `MASTER_SECRETS_KEY` up now, before you have data. It is not in the
database, so a database backup alone does not protect you. Read
[Back up and restore](back-up-and-restore.md).

The [configuration reference](../../configuration.md) lists every variable,
including the deploy-level ones the compose file never mentions.

## Verify the instance is ready

The app applies database migrations before it opens a listener, so a cold
start takes up to a minute, and connections are refused until then.

```bash
docker compose ps
# wait for the app to report healthy, then:
curl -sS localhost:4000/health/ready
# {"checks":{"database":"ok"},"status":"ok"}
```

If the app still refuses connections after a minute, read
`docker compose logs -f app`. A container that never opens a listener usually
has migrations that cannot reach the database; read
[Pods restart or never go ready](../../troubleshooting/pods-restarting.md).

## Register the first account

Open <http://localhost:4000> and create your account. The compose defaults
leave mail off (no `SMTP_HOST`), so your account self-verifies, and Managoat
promotes it to admin because it is the first verified account on an instance
that has never had an admin. The audit trail records the grant (ADR 0011).
There is no setting for this.

Register **before** you expose the instance to a network you do not trust.
While no admin has ever existed, the first verified account takes the role.

Registration is open until the instance has an admin, and closed after. To
let other people register, set `REGISTRATION_ENABLED=true`, or keep it closed
and open their accounts yourself (`POST /api/admin/users`). Somebody will
find a public instance that has registration open.

## Point the apps at it

Managoat's own UI is a console for the account, its keys, the audit trail and
the admin pages. To create agents, environments and vaults, and to watch a
conversation turn by turn, use
[Conversations](https://fountain-conversations.demo.managoat.com/), a static
single-page app with no server of its own, or the [CLI](../../cli.md). You type your Managoat's
URL in, so the hosted copy works against your deployment once it admits the
origin:

```bash
echo "API_CORS_ORIGINS=https://fountain-conversations.demo.managoat.com" >> .env
```

To offer "Sign in with Managoat" instead of a pasted API key, register the app
in `OAUTH_CLIENTS`. The console links to whatever `CONVERSATIONS_APP_URL`
says; point it at your own build, or set it to `""` to stop the offer.

## Prove the whole path

Readiness checks Postgres only. In the console, add a model credential under
Settings, then Inference credentials. Open Conversations and start a run. A
first turn proves that Managoat can read Postgres, decrypt the credential,
reach the model provider and start a sandbox. If the app serves while a
sandbox fails to start, the provider is the usual cause; read
[Sandbox errors](../../troubleshooting/sandbox-errors.md).

To start over, `docker compose down -v` deletes the database volume and every
account in it. Keep the same `MASTER_SECRETS_KEY` whenever you keep the
volume: a new key cannot unwrap what the old key wrapped.

## Put it on the internet

The compose file publishes port 4000 with no TLS. Terminate TLS in front of it
with Caddy, nginx or a tunnel, and set two variables.

- `PUBLIC_URL`, the external URL with its scheme. It defaults to
  `http://localhost:4000`. It builds the links in verification emails, and
  every sandbox reads it as `FOUNTAIN_BASE_URL`.
- `TRUSTED_PROXIES`, your proxy's address range. Without it, every per-IP
  rate-limit bucket collapses into one keyed on the proxy, and audit rows
  record the proxy's address.

An `https://` `PUBLIC_URL` also turns on the HTTPS redirect, HSTS (one year,
with subdomains, not preloaded) and the `secure` flag on the session cookie.
Managoat derives all three from the scheme, and none can be on for an
`http://` instance. The redirect reads `X-Forwarded-Proto`, so your proxy must
set it, or every request looks like plain http and the redirect loops.
`/health` and `/health/ready` are exempt from the redirect, because probes
reach the app over plain http.

`CHECK_ORIGIN_EXTRA` adds origins that can open a LiveView websocket, as a
comma-separated list. Managoat always includes its own host; add to it only
for something like a preview environment on another domain.

```bash
curl -sSI https://your-fountain.example.com/health/ready | head -1
```

Then sign in through the public URL. A redirect loop in the browser means the
proxy does not set `X-Forwarded-Proto`.

## Connect a database

`DATABASE_URL` is the connection. `DATABASE_SSL` defaults to on; the compose
file sets it to `false` because a stock `postgres` image does not serve TLS.
Point Managoat at a managed database and remove that line. To verify the
server certificate, and not merely encrypt to it:

```bash
DATABASE_SSL_VERIFY=true
# optional, otherwise the OS trust store is used
DATABASE_SSL_CA_FILE=/etc/ssl/certs/rds-ca.pem
```

A 503 from `/health/ready` means the instance cannot reach its database.

### Run migrations in a Job

The app migrates at boot, under a Postgres advisory lock, so even a first
boot against an empty database does not race. To make migrations a step of
their own, set `MIGRATE_ON_BOOT=false`; the release then starts and migrates
nothing. Run the migration entrypoint once, before the new version serves:

```bash
bin/migrate     # in the image; the same as
                # bin/fountain_server eval 'Fountain.Release.migrate()'
```

`bin/migrate` ignores `MIGRATE_ON_BOOT`. In Kubernetes it is a Job ordered
before the rollout, and
[`deploy/k8s/README.md`](https://github.com/managoat/fountain/blob/main/deploy/k8s/README.md)
holds the manifest. What it buys you: migrations become a step somebody can
review, and the app can run under a database role that cannot `ALTER`.

**Nothing verifies that the Job ran.** A pod with the switch off boots
against a database nobody migrated, then fails on the first query that needs
the new column. Ordering the Job ahead of the rollout is your job.

## Configure email

Mail is off until you set `SMTP_HOST`. With it off, an account self-verifies
at registration (ADR 0011) and Managoat says so at boot. A password reset has
no mail either, so the one route back into a locked-out account is a release
task. That is usually the right trade for a one-operator instance; set SMTP
before you invite anyone.

| Setting | Effect |
|---|---|
| `SMTP_HOST` (with `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`) | Mail on, through any SMTP server. The port defaults to 587 with STARTTLS. Omit the username for a relay that wants no authentication. |
| `EMAIL_FROM` | The sender, on a domain your provider verified. Required with `SMTP_HOST`. |

A hosted provider works through its SMTP endpoint. For Resend, that is
`smtp.resend.com` on port 587, the username `resend`, and an API key as the
password. An unverified sending domain fails SPF, DKIM and DMARC downstream,
and the receiver rejects the message or files it as spam. The
[mail integration guide](../../integrations/mail.md) covers the provider side.

To check delivery, request a password reset for your own account and watch
for the mail. If none arrives, read
[Nobody can log in](../../troubleshooting/nobody-can-log-in.md). You can verify
an account by hand, but treat that as a mail setup that failed, not as a fix:

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.verify_email("them@example.com")'
```
