# Deploy on Fly.io

This guide shows you how to bring up an instance on [Fly](https://fly.io) from
the `fly.toml` in this repository. It then shows you what to set after the
first deploy.

For a machine you control, read [Deploy an instance](deploy.md). That guide
uses Docker Compose, and it is the shorter path.

## What the file gives you

[`fly.toml`](https://github.com/managoat/fountain/blob/main/fly.toml)
declares one machine on the published image. The machine runs the published
image, not a build of your checkout. The file gives you an instance that runs.
It does not describe how the hosted service runs, which is Kubernetes.

Fly gives you no database. You create one in a separate step below.

## Before you start

Install [flyctl](https://fly.io/docs/flyctl/install/) and sign in. Then clone
this repository. Fly reads `fly.toml` from the directory you deploy from, so a
fork is optional here.

Generate the two keys now. You paste them in a later step.

```bash
openssl rand -base64 48 | tr -d '\n'                    # SECRET_KEY_BASE
openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n'   # MASTER_SECRETS_KEY
```

Back `MASTER_SECRETS_KEY` up before you have data. It is not in the database.
A database backup alone does not protect you. Read
[Back up and restore](back-up-and-restore.md).

You also need a sandbox provider token. Read
[Self-host Fountain](../../self-hosting.md) for what each provider needs.

## Create the app

```bash
fly launch --no-deploy --copy-config
```

`--copy-config` keeps the settings in `fly.toml`, and `--no-deploy` stops Fly
before it starts a machine with no database and no keys. Answer the prompts
with a name of your own. Fly writes that name back into `fly.toml`.

## Create the database

```bash
fly mpg create
fly mpg attach <cluster-name>
```

The attach step sets `DATABASE_URL` as a secret on the app. Managed Postgres
serves TLS, which the app expects. Its host resolves to a private IPv6
address only, so `fly.toml` sets `DATABASE_IPV6 = "true"`. Without it the app
exits at boot with `:nxdomain`.

The older `fly pg create` command makes an unmanaged Postgres app instead, and
that one serves no TLS. Against one of those, set `DATABASE_SSL = "false"` in
`fly.toml`. The file carries the line as a comment.

## Set the three secrets

```bash
fly secrets set \
  SECRET_KEY_BASE=... \
  MASTER_SECRETS_KEY=... \
  SPRITES_TOKEN=...
```

Fly stages a secret on an app that has no machine yet, and the first deploy
picks all three up.

| | |
|---|---|
| `SECRET_KEY_BASE` | The first key above. Phoenix signs the session cookie with it. |
| `MASTER_SECRETS_KEY` | The second key above. It wraps every tenant's data encryption key. |
| `SPRITES_TOKEN` | Your sandbox provider token. The app starts without one, and every conversation then fails. |

Keep all three out of `fly.toml`. That file is in a git repository, and a
guard test fails the build when one of these keys appears in it.

## Deploy

```bash
fly deploy
```

The first deploy takes a few minutes, because the app applies the database
migrations before it opens a listener. The health check waits 60 seconds for
that reason.

`PUBLIC_URL` is absent from `fly.toml` on purpose. The file ships with an app
name that `fly launch` replaces, so a base URL in it names the wrong app.
Fountain builds `https://<app>.fly.dev` from Fly's own `FLY_APP_NAME` instead,
so the first deploy has a correct base URL.

## Register the first account

```bash
fly open
```

Register on the page that opens. `fly.toml` sets `EMAIL_DELIVERY=none` and
`FIRST_USER_ADMIN=true`, so your account self-verifies and becomes the admin.

Register **before** you give the URL to anybody. While no admin exists, the
first verified account takes the role.

Then close registration.

```bash
fly secrets set REGISTRATION_ENABLED=false
```

A secret change restarts the machine on its own, so this needs no second
`fly deploy`.

## Add a custom domain

```bash
fly certs add fountain.example.com
fly secrets set PUBLIC_URL=https://fountain.example.com
```

Set the second one. The `FLY_APP_NAME` fallback still resolves to the
`fly.dev` address, and Fountain keeps that address in every verification email
and in every sandbox until you replace it.

## Run your own build

`fly.toml` runs the published image, which is the same image the compose quick
start runs. To run a fork with your own changes, delete the `image` line under
`[build]`. Fly then builds the `Dockerfile` in your checkout.

The build takes 15 to 25 minutes on Fly's builders. It compiles the umbrella,
it builds the Go CLI, and it fetches the pinned Buzz binaries.

## What the file does not do

- **It runs one machine.** Fountain clusters over Erlang distribution, and
  nothing on Fly discovers peers. A second machine is not a second node, and
  two schedulers then race over the same sandboxes. Read
  [Architecture](../../architecture.md#clustering). Scale the VM in `[[vm]]`
  instead of the machine count, and avoid `fly scale count`.
- **It never lets the machine park.** `auto_stop_machines` and
  `auto_start_machines` are off, and `min_machines_running` is 1. Fly's
  defaults park an idle machine and start it again on the next request, which
  suits a web app. It does not suit this one. The sandbox reaper, the credit
  pricer and every scheduled teammate run inside this process, so a parked
  machine is an instance that quietly stops the reaper and stops the pricer.
- **It deploys with the `rolling` strategy.** `canary` and `bluegreen` both
  start a second machine before they retire the first, which is the split
  brain above for the length of a deploy. `rolling` replaces the machine in
  place, and the instance is unreachable for a few seconds.
- **It sends no mail.** Accounts self-verify at registration in this mode
  (ADR 0011). Read [Configure email](email.md) for a real provider.
- **It trusts a wide proxy range.** Fly terminates TLS at its edge, so the app
  sees the proxy and not the caller. The file sets `TRUSTED_PROXIES` to the
  6PN range and a private IPv4 range. Only Fly's proxy reaches the machine, so
  this is safe. Narrow it when you confirm the address that Fly forwards from.
- **It does not back the database up.** Managed Postgres takes its own
  snapshots. Read [Back up and restore](back-up-and-restore.md) for what a
  restore needs, and remember that a dump alone cannot decrypt itself.

## Upgrade

The file pins a release tag. A push to your fork does not move the pin.

Edit the tag in `fly.toml`, then deploy again.

```toml
[build]
  image = "ghcr.io/managoat/fountain:vX.Y.Z"
```

Read [Upgrade an instance](upgrade.md) first. Migrations run at boot, and
Fountain does not support a downgrade.
