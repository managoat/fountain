# Connect a database

This guide shows you three things. How to point Fountain at a Postgres you
manage. How to turn TLS verification on. How to move migrations out of boot,
into a step of their own.

## Before you start

Fountain needs Postgres 16 or newer. The compose file runs one for you. This
guide is for how to replace that one with a managed database, and for how to
run migrations separately.

## Point it at your database

`DATABASE_URL` is the connection. The app runs its migrations at boot, so an
upgrade is `docker compose pull && docker compose up -d`.

`DATABASE_SSL` defaults to on. The compose file sets it to `false`, because a
stock `postgres` image does not serve TLS. Point Fountain at a managed
database and you can remove that line.

To verify the server certificate, and not merely encrypt to it, set two more.

```bash
DATABASE_SSL_VERIFY=true
# optional, otherwise the OS trust store is used
DATABASE_SSL_CA_FILE=/etc/ssl/certs/rds-ca.pem
```

## Run migrations in a Job

A migration at boot is right for one replica, and it is not the only shape.
Set `MIGRATE_ON_BOOT=false` and the release starts and migrates nothing. Run
the migration entrypoint yourself, once, before the new version serves.

```bash
bin/migrate     # in the image; equivalent to
                # bin/fountain_server eval 'Fountain.Release.migrate()'
```

`bin/migrate` ignores `MIGRATE_ON_BOOT`. It is the thing you run *to* migrate.
In Kubernetes that is a Job ordered before the rollout, and
[`deploy/k8s/README.md`](https://github.com/managoat/fountain/blob/main/deploy/k8s/README.md)
holds the manifest.

Three things matter before you turn boot migrations off.

- **Nothing verifies that the Job ran.** A pod with the switch off boots
  happily against a database nobody migrated, then fails on the first query
  that needs the new column. To order the Job ahead of the rollout is your
  job, and not the app's.
- **You do not need this to avoid a race.** A Postgres advisory lock
  serializes the boot migrations. Fountain takes the lock before it touches
  `schema_migrations`, so even a first boot against an empty database does not
  race.
- **What it buys you** is three things. Migrations become a step somebody can
  review. App pods can run under a database role that cannot `ALTER`. A pod
  starts faster on a scale-up.

## Verify it worked

```bash
curl -sS localhost:4000/health/ready
# {"checks":{"database":"ok"},"status":"ok"}
```

A 503 here means this instance cannot reach its database.

## Related

- [Back up and restore](back-up-and-restore.md).
- [Upgrade an instance](upgrade.md).
- [Configuration reference](../../configuration.md), for each `DATABASE_*`
  variable.
