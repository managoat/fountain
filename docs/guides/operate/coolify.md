# Deploy on Coolify

[Coolify](https://coolify.io) runs on a server you own, and it deploys a
Docker Compose file from a git repository. Fountain ships one, so Coolify
needs no file of its own here. This guide shows you which five values to set
in the Coolify interface. It then shows you the two compose defaults that a
public server must not keep.

[Dokploy](https://dokploy.com) works the same way. The values below apply
there too.

For a plain Docker host with no interface in front of it, read
[Deploy an instance](deploy.md). Coolify runs the same
[`docker-compose.yml`](https://github.com/managoat/fountain/blob/main/docker-compose.yml),
so the two paths differ in the interface and not in the result.

## Before you start

You need a Coolify server, and a domain that points at it.

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

## Create the resource

In Coolify, select **New**, then **Docker Compose**. Point it at
`https://github.com/managoat/fountain`, on the `main` branch, with
`docker-compose.yml` as the compose file.

Coolify reads the file and lists the environment variables in it. Every
variable has a default that works, except the ones below.

## Set the five values

| | |
|---|---|
| `SECRET_KEY_BASE` | The first key above. |
| `MASTER_SECRETS_KEY` | The second key above. |
| `SPRITES_TOKEN` | Your sandbox provider token. The app starts without one, and every conversation then fails. |
| `POSTGRES_PASSWORD` | A long random string. The default is `postgres`, and the next section says why that matters. |
| `PUBLIC_URL` | The address you gave the app service, with the scheme. |

`PUBLIC_URL` is the one that catches people. Its compose default is
`http://localhost:4000`, and that default is a value, not an absence. The app
starts, and every verification email and every sandbox then holds a localhost
address. Set it to the domain in the app service's **Domains** field, and
include `https://`.

The compose file does not use Coolify's `SERVICE_FQDN_` variables, which fill
a domain in for you. Docker Compose on its own resolves an unset variable to
an empty string, and an empty `PUBLIC_URL` is a value that a production boot
refuses. One file serves both paths, so you type the domain twice.

## Close the two ports

The compose file publishes two ports on the host. That suits a laptop. It
does not suit a server on the internet.

```yaml
ports:
  - "${POSTGRES_HOST_PORT:-5432}:5432"   # postgres
  - "${PORT:-4000}:4000"                 # app
```

Postgres is the one that matters. A server with an open firewall offers
Postgres to the internet on 5432, and the compose default password is
`postgres`. Set `POSTGRES_PASSWORD`, and block 5432 at the firewall. Coolify
does not manage the host firewall for you.

The app port needs no host publication either. Coolify's proxy reaches the
container over the compose network, and the **Domains** field is what routes
traffic to it.

## Trust the proxy

Coolify puts a proxy in front of the app, so the app sees the proxy and not
the caller. Left unset, Fountain falls back to cluster ranges that match
nothing here. Every per-IP rate-limit bucket then collapses into one, and
every audit row records the proxy's address.

```
TRUSTED_PROXIES=172.16.0.0/12
```

That range covers the Docker bridge networks Coolify creates. Narrow it when
you confirm the address that the proxy forwards from.

## Deploy

Select **Deploy**. The first deploy takes a few minutes, because the app
applies the database migrations before it opens a listener.

The app service carries a health check, so Coolify reports the container as
healthy only after the migrations finish.

## Register the first account

Open your domain and register. The compose defaults are `EMAIL_DELIVERY=none`
and `FIRST_USER_ADMIN=true`, so your account self-verifies and becomes the
admin.

Register **before** you give the URL to anybody. While no admin exists, the
first verified account takes the role.

Registration then closes on its own: unset, `REGISTRATION_ENABLED` is open
only until the instance has an admin.

## What Coolify does not do for you

- **It runs one instance.** Fountain runs as one node, and the compose file
  describes a single container. A second replica is a second node that knows
  nothing of the first, and two schedulers then race over the same sandboxes.
  Read [Architecture](../../architecture.md#one-node).
- **It takes no database backup.** The compose file has a `backup` profile
  that dumps Postgres nightly, and Coolify does not start a profile. Use
  Coolify's own scheduled backups for the Postgres service instead. Read
  [Back up and restore](back-up-and-restore.md) for what a restore needs, and
  remember that a dump alone cannot decrypt itself.
- **It does not pin the version for you.** The compose file pins a release
  tag, and a redeploy from `main` picks up whatever tag the branch holds.
  Fork the repository, or set `FOUNTAIN_IMAGE_TAG`, and read
  [Upgrade an instance](upgrade.md) before you move it. Migrations run at
  boot, and Fountain does not support a downgrade.
