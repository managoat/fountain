# Managoat on Kubernetes — portable baseline

Plain manifests, applied with `kubectl apply -k`. No operators, no CRDs, no
assumptions beyond a cluster and an ingress controller. The maintainer's own
cluster (CNPG, Traefik, Infisical, Flux) is this baseline plus a private
overlay that lives outside the repo (decisions/0032); there is no other
Kubernetes directory here.

The [compose path](https://managoat.com/docs/self-hosting) is
simpler if you don't already live on Kubernetes — start there.

## What this does not include

- **A database.** Bring a Postgres 16+ and hand its URL to the app. If it
  doesn't serve TLS, set `DATABASE_SSL: "false"` in the ConfigMap.
- **TLS / ingress specifics.** `ingress.yaml` is a standard Ingress with the
  contract documented inline; wire it to your controller and certificates.
- **Secret management.** The manifests reference a `fountain-secrets` Secret;
  creating it is on you (plain Secret below, or your ESO/Vault/sealed-secrets
  machinery pointed at the same name).

## Quick start

```bash
# 1. The secrets. MASTER_SECRETS_KEY encrypts every stored secret — lose it
#    and they are unrecoverable, so back it up somewhere that is not the
#    cluster. See "Back up MASTER_SECRETS_KEY" in the self-hosting guide.
kubectl create namespace fountain
kubectl create secret generic fountain-secrets -n fountain \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')" \
  --from-literal=MASTER_SECRETS_KEY="$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')" \
  --from-literal=DATABASE_URL="postgres://user:pass@your-postgres:5432/fountain" \
  --from-literal=SPRITES_TOKEN="your-sprites-token"

# 2. Edit configmap.yaml (PUBLIC_URL and BROKER_PROXY_URL at minimum) and the
#    image pin in kustomization.yaml, route BROKER_PROXY_URL's host to the
#    Service's `broker` port with a TCP route (configmap.yaml says why), then:
kubectl apply -k deploy/k8s

# 3. Watch it come up. Migrations run at boot under an advisory lock.
kubectl rollout status deployment/fountain -n fountain

# 4. Register. With mail off (no SMTP_HOST in configmap.yaml) the account
#    verifies itself at registration (ADR 0011).
```

Images after v0.25.0 make the first verified account the admin on their
own, audit-recorded, and with `REGISTRATION_ENABLED: "auto"` (the configmap's
value) registration closes the moment it does. On v0.25.0, the pin above,
make yourself admin with a release task:

```bash
kubectl exec -n fountain deploy/fountain -- \
  sh -c "PHX_SERVER=false bin/fountain_server eval 'Fountain.Release.promote_admin(\"you@example.com\")'"
```

## Upgrades

Edit the tag in `kustomization.yaml`'s `images:` block and re-apply. `vX.Y.Z`
tags are immutable; `vX.Y` follows patches. Patch releases are always safe;
pre-1.0 minor bumps may carry **Upgrade notes** in the
[changelog](https://managoat.com/docs/changelog). Migrations
run at boot, idempotently, under an advisory lock. Downgrades are not
supported once a newer version's migrations have run — restore from a backup.

## Migrations in a Job

The pod migrates at boot by default, under a Postgres advisory lock taken
before `schema_migrations` exists, so a Job and a booting pod against an empty
database do not race.

If you want the other shape — migrations as an explicit, reviewable step, app
pods that only serve — set `MIGRATE_ON_BOOT: "false"` in the ConfigMap and run
the migration entrypoint as a Job. `bin/migrate` ignores the switch; it is
what you run *to* migrate.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  # Version the name. A completed Job's pod template is immutable, so
  # re-applying under the same name after a tag bump fails instead of
  # migrating — and a failure that looks like a no-op is the bad kind.
  name: fountain-migrate-v0-6-1
  namespace: fountain
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: ghcr.io/managoat/managoat:v0.6.1 # match the Deployment
          command: ["/app/bin/migrate"]
          envFrom:
            - configMapRef:
                name: fountain-config
            - secretRef:
                name: fountain-secrets
```

Run it to completion **before** the rollout that needs it. Nothing in the app
checks that you did: a pod with `MIGRATE_ON_BOOT=false` boots against an
un-migrated database without complaint and fails on the first query that
needs the new column.

## Operational notes

- **Probes**: liveness checks only the process (a Postgres blip must not
  restart the app tier); readiness checks the database and gates traffic; the
  startup probe allows 150s for boot-time migrations. Reasons are inline in
  `deployment.yaml`.
- **Client IPs / rate limiting**: set `TRUSTED_PROXIES` in the ConfigMap to
  your ingress-controller and pod CIDRs. The app's built-in default trusts the
  k3s networks (`10.42.0.0/16`, `10.43.0.0/16`); on a cluster with different
  CIDRs the `X-Forwarded-For` chain is never stepped over, every request
  resolves to the ingress pod's IP, and per-IP rate limits collapse into one
  shared bucket. See the commented entry in `configmap.yaml`.
- **Metrics**: Prometheus format on port 9568 (`metrics`). Scrape in-cluster;
  never expose it. `prometheusrule.yaml` ships generic alerts (commented out
  of `kustomization.yaml`; needs the PrometheusRule CRD), and
  `../grafana/fountain-dashboard.json` is a starter dashboard for the same
  metrics.
- **Scaling**: one replica, deployed with the `Recreate` strategy. Managoat
  runs as a single node, so a second replica is unsupported, and a deploy has
  a short gap while the old pod stops and the new one starts. See the comment
  atop `deployment.yaml`.
- **Backups**: `backup-cronjob.yaml` ships a nightly `pg_dump` to any
  S3-compatible bucket — commented out of `kustomization.yaml` until you
  create its secret; setup is at the top of the file, the restore drill in
  [the docs](https://managoat.com/docs/guides/operate/back-up-and-restore).
  `MASTER_SECRETS_KEY` must still be backed up separately — a database backup
  alone cannot decrypt itself.
