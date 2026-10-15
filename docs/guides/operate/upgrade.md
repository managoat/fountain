# Upgrade an instance

This guide shows you how to move an instance to a newer Managoat release, and
what to do when an upgrade goes wrong. Take a backup first: an upgrade is the
one moment where the supported path back needs one. Read
[Back up and restore](back-up-and-restore.md).

## How versions work

Managoat follows [SemVer](https://semver.org/), before 1.0. A patch release,
`v0.3.0` to `v0.3.1`, is always safe to take. A minor release, `v0.3` to
`v0.4`, can break something, and its
[release notes](https://github.com/managoat/fountain/releases) call each
break out under **Upgrade notes**. Read them before a minor bump, including
those of every minor you skip. Releases up to 0.23.0 carry theirs in the
[changelog](../../changelog.md).

Each release publishes the server image to `ghcr.io/managoat/fountain`.

| Tag | Moves? | Use it for |
|---|---|---|
| `vX.Y.Z` | Never. | To pin a known version. This is the default we suggest. |
| `vX.Y` | To the newest patch in the line. | To take patches on their own. |
| `latest` | On each merge to `main`. | Nothing you keep in production. |
| `sha-<commit>` | Never. | To reproduce exactly what one commit built. |

Older releases also published a `-core` variant of each tag. A pinned `-core`
tag keeps working, but no new version is published under one; move to the tag
without the suffix. Releases v0.2.1 and earlier exist as `sha-` tags alone.

## Build your own image

```bash
docker build -t fountain .
```

For a release built directly from the source tree, use
`MIX_ENV=prod mix release fountain_server`.

## Take a new version

The compose file reads `MANAGOAT_IMAGE_TAG` from `.env`, and
`.env.compose.example` ships it set to a pinned release; unset, the compose
file still falls back to a pinned release, not `latest`. To upgrade, edit that
value, then pull:

```bash
docker compose pull && docker compose up -d
```

On Kubernetes or Fly, change the pinned tag in your manifest or `fly.toml`
the same way. [Deploy on another host](hosts.md) has the details.

Migrations run on their own at boot. They are idempotent, and a Postgres
advisory lock serializes them. You run no manual step unless a release's
upgrade notes say to. If you moved migrations into a Job with
`MIGRATE_ON_BOOT=false`, the Job is the upgrade step; read
[Run migrations in a Job](deploy.md#run-migrations-in-a-job).

## Managoat runs as one node

Since v0.23.0, Managoat runs as exactly one node. It no longer clusters over
Erlang distribution, `CLUSTER_DNS_QUERY` is not read, and `RELEASE_COOKIE` no
longer joins machines. Run one replica and deploy with a strategy that stops
the old instance before it starts the new one: `strategy: Recreate` with
`replicas: 1` on Kubernetes (what `deploy/k8s/` ships), one machine with the
`rolling` strategy on Fly. Docker Compose already runs one container. A
rolling deploy with surge would run two schedulers over the same sandboxes.

Each deploy has a short gap, about 30 seconds, in which the API answers
nothing; at boot the new node starts a server again for each conversation that
had one. Read [Architecture](../../architecture.md#one-node).

Because the old instance always stops before the new one migrates, you can
skip releases: the "take release N fully rolled out before N+1" ordering in
older upgrade notes applies only to rolling deploys. Do any **action** those
notes ask for, such as re-entering a key, before or after you upgrade.

## Match the CLI to the server

The CLI and the server come from the same tag, and a matching pair is what we
test. The CLI's built-in default `base_url` is `https://managoat.com`, the
maintainer's own instance, which has signup closed. Point the CLI at yours
before you export an API key, or the first command sends that key to the
maintainer's domain:

```bash
MANAGOAT_BASE_URL=https://your-fountain.example.com managoat auth login
```

`auth login` records the URL in the saved profile, so you do this once.

## Watch a deploy land

```bash
kubectl rollout status deployment/fountain -n fountain   # k8s
docker compose logs -f app                               # compose
```

A rollout that never completes usually means the startup probe fails, which
means migrations that cannot finish. A failing readiness probe can also be a
database problem older than the deploy. Read
[Pods restart or never go ready](../../troubleshooting/pods-restarting.md).

## When an upgrade goes wrong

1. **Roll forward.** Pin `vX.Y.Z` tags, read **Upgrade notes** before a minor
   bump, and fix forward when something breaks.
2. **Do not downgrade once a newer version's migrations have run.** It is not
   supported. The path back is to restore the pre-upgrade backup and run the
   previous image, losing the writes since the backup. If a restore crosses
   an upgrade boundary, run the image version that matches the dump.
3. `Fountain.Release.rollback/2` reverses one migration that you understand.
   Do not use it to reverse a whole release's migrations on production data.

## Older upgrade notes

The per-release notes live under each version's **Upgrade notes**: in the
[changelog](../../changelog.md) up to 0.23.0, and in the
[release notes](https://github.com/managoat/fountain/releases) after it. The
headings below keep the links from older
changelog entries working, and say where each note's detail is.

### Vault policy migration

v0.17.0, migration `20260913180000`. Adds the `vault_access` columns to agents
and agent versions; `allowed_vault_ids` stays the API input. It rewrites both
tables under exclusive locks, with a five-second lock wait and a 30-second
limit, so schedule a window on a large database.

### Environment policy migration

v0.20.0, migration `20260915220000`. The same for `allowed_environment_ids`,
under the same bounds.

### Credential set policy migration

v0.20.0, migration `20260915230000`. The same for credential sets, which
v0.23.0 later removed; see below.

### Principal credential expiry

Claimable principals and their keys are gone; see the next note.

### Claimable principals removed

v0.22.0, migration `20261012120000`. Deletes every principal account with its
rows. A migration cannot reach a sandbox provider, so release each open
principal with the previous release before you upgrade.

### Billing and principal columns dropped

v0.22.0, migration `20261012210000`. Drops the credit and principal columns
that the release before it left unread.

### Credential sets collapsed to one record

v0.23.0, migrations `20261014120000` and `20261014140000`. Each account keeps
its default credential set and loses the others, with their keys. Re-enter any
key you still need at `/account/inference-credentials`. A conversation bound
to a deleted set gets `409 inference_source_changed`; start a new one.

### Conversation message compatibility

v0.17.0 changed the messages between conversation processes, which mattered
only while Managoat ran as a cluster: stop every old process before starting
the new release. The single-node deploy shape always does.
