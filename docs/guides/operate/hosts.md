# Deploy on another host

[Deploy an instance](deploy.md) is the Docker Compose path, and the rest of
that page (TLS, the database, email) applies on every host. This page covers
what differs on Kubernetes, Fly.io and Coolify.

Whatever the host, three rules hold.

- **Run exactly one instance**, and deploy with a strategy that stops the old
  one before it starts the new one. Fountain runs as one node, so a second
  replica runs its own schedulers over the same sandboxes, and a stream breaks
  for a viewer whose connection lands on the other one. Read
  [Architecture](../../architecture.md#one-node). Each deploy therefore has a
  short gap, about 30 seconds, in which the API answers nothing; at boot the
  new instance starts a server again for each conversation that had one.
- **Generate the two keys and back `MASTER_SECRETS_KEY` up** before you have
  data. Keep both, and your sandbox provider token, out of any file in git.

  ```bash
  openssl rand -base64 48 | tr -d '\n'                    # SECRET_KEY_BASE
  openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n'   # MASTER_SECRETS_KEY
  ```

- **Register your own account before you share the URL.** Each path below
  defaults to `EMAIL_DELIVERY=none` and `FIRST_USER_ADMIN=true`, so the first
  account self-verifies and becomes the admin, and registration then closes
  on its own. Read [Configure email](deploy.md#configure-email) for a real
  provider.

## Kubernetes

[`deploy/k8s/`](https://github.com/managoat/fountain/tree/main/deploy/k8s)
is a portable baseline of plain manifests, applied with `kubectl apply -k`.
It assumes no operators and no CRDs. You bring a Postgres, an ingress
controller and the `fountain-secrets` Secret; its README walks you through the
rest, and the manifests explain their probe and strategy choices in comments.

The baseline runs one replica with the `Recreate` strategy. Keep both.

**Track `main` with Flux.** Every merge to `main` publishes `deploy/` as an
OCI artifact at `ghcr.io/managoat/fountain-manifests`, with the image tag
built from that commit in place of the release pin. The maintainer's instance
runs from it. A Flux `OCIRepository` on the tag `latest` and a `Kustomization`
on the path `./deploy/k8s` give you the same, and Flux `patches` hold your
changes. Batch your merges, because each one is a deploy.

**Decide two things.** Migrations run at boot; to run them as a Job instead,
read [Run migrations in a Job](deploy.md#run-migrations-in-a-job). Backups:
`deploy/k8s/backup-cronjob.yaml` sits commented out of the kustomization
until you create its secret; read [Back up and restore](back-up-and-restore.md).
The alert rules are optional too; read [Observability](observability.md).

```bash
kubectl rollout status deployment/fountain -n fountain
kubectl exec -n fountain deploy/fountain -- curl -sS localhost:4000/health/ready
```

Most symptoms that look like a Kubernetes fault are the probe layout at work;
read [Pods restart or never go ready](../../troubleshooting/pods-restarting.md).

## Fly.io

[`fly.toml`](https://github.com/managoat/fountain/blob/main/fly.toml) declares
an app on a pinned release image, with one machine. Fly gives you no
database, so you create one. Install
[flyctl](https://fly.io/docs/flyctl/install/), sign in, and run these from a
clone of the repo.

```bash
fly launch --no-deploy --copy-config     # keep fly.toml, name the app
fly mpg create
fly mpg attach <cluster-name>            # sets DATABASE_URL
fly secrets set SECRET_KEY_BASE=... MASTER_SECRETS_KEY=... SPRITES_TOKEN=...
fly deploy --ha=false
fly open                                 # register the first account
```

- `--no-deploy` stops Fly before it starts a machine with no database and no
  keys. Fly stages the secrets, and the first deploy picks them up.
- Managed Postgres serves TLS, and its host resolves to a private IPv6 address
  only, so `fly.toml` sets `DATABASE_IPV6 = "true"`; without it the app exits
  at boot with `:nxdomain`. The older `fly pg create` serves no TLS: set
  `DATABASE_SSL = "false"` against one of those.
- `--ha=false` keeps the app at one machine; Fly's default starts two. If it
  already runs two, `fly scale count 1`.
- The first deploy takes a few minutes, because migrations run before the
  listener opens; the health check waits 60 seconds for that.
- `PUBLIC_URL` is absent on purpose. Fountain builds `https://<app>.fly.dev`
  from Fly's `FLY_APP_NAME`. For a custom domain, run
  `fly certs add fountain.example.com` and
  `fly secrets set PUBLIC_URL=https://fountain.example.com`, or every email
  and sandbox keeps the `fly.dev` address.

What the file sets, and why:

- **The machine never parks.** `auto_stop_machines` and `auto_start_machines`
  are off and `min_machines_running` is 1, because the reaper and the
  retention pruner run inside the process.
- **The `rolling` strategy.** On one machine, Fly stops it, updates it and
  starts it again, so two releases never run at once. `canary` and
  `bluegreen` start a second machine beside the first.
- **A wide `TRUSTED_PROXIES`**, the 6PN range and a private IPv4 range. Only
  Fly's proxy reaches the machine, so this is safe; narrow it once you confirm
  the address Fly forwards from.
- **No backup.** Managed Postgres takes its own snapshots; a dump alone cannot
  decrypt itself without the key.

To upgrade, edit the pinned tag under `[build]` and deploy again. To run your
own fork, delete the `image` line, and Fly builds the `Dockerfile` in your
checkout (15 to 25 minutes on Fly's builders).

## Coolify

[Coolify](https://coolify.io) deploys a Docker Compose file from a git
repository, so it runs Fountain's own
[`docker-compose.yml`](https://github.com/managoat/fountain/blob/main/docker-compose.yml).
[Dokploy](https://dokploy.com) works the same way. You need a server and a
domain that points at it.

Select **New**, then **Docker Compose**, and point it at
`https://github.com/managoat/fountain` on `main` with `docker-compose.yml`.
Every variable Coolify lists has a working default except these five.

| | |
|---|---|
| `SECRET_KEY_BASE` | The first key above. |
| `MASTER_SECRETS_KEY` | The second key above. |
| `SPRITES_TOKEN` | Your sandbox provider token. |
| `POSTGRES_PASSWORD` | A long random string. The default is `postgres`. |
| `PUBLIC_URL` | The app service's domain from its **Domains** field, with `https://`. |

`PUBLIC_URL` catches people: its compose default `http://localhost:4000` is a
value, so the app starts and every email and sandbox holds a localhost
address. The compose file does not use Coolify's `SERVICE_FQDN_` variables,
so you type the domain twice.

**Close the two ports.** The compose file publishes 5432 and 4000 on the host.
Block 5432 at the firewall (Coolify does not manage it), because an open
Postgres with the default password is on the internet. The app port needs no
host publication either; Coolify's proxy reaches the container over the
compose network.

**Trust the proxy.** Set `TRUSTED_PROXIES=172.16.0.0/12`, which covers the
Docker bridge networks Coolify creates, and narrow it once you confirm the
address the proxy forwards from.

Select **Deploy**. The app's health check reports healthy only after
migrations finish. Then:

- **Back the database up with Coolify's scheduled backups.** Coolify does not
  start the compose file's `backup` profile.
- **Pin the version.** A redeploy from `main` picks up whatever tag the branch
  holds. Fork the repository or set `FOUNTAIN_IMAGE_TAG`, and read
  [Upgrade an instance](upgrade.md) before you move it.
