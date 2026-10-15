# Back up and restore

A backup here is two things. It is a `pg_dump` of Postgres **and the
`MASTER_SECRETS_KEY` that was live when you took it**. The key wraps each
tenant's encryption key. Restore a dump without that key and nothing will ever
decrypt its secrets. Which key was live at the moment of the dump is part of
that backup's identity.

## Back `MASTER_SECRETS_KEY` up

Fountain encrypts each environment and vault secret with a key for that
tenant, and it wraps that key with `MASTER_SECRETS_KEY`. **Lose that key and
you lose each stored secret. Change it and you lose them too.**

By design, Fountain does not store it in the database. A database backup alone
does not protect you.

Keep it somewhere apart from your database backups. Treat a rotation of it as
a migration, and not as a config change.

## Take backups

**Compose.** The bundled service, which is off unless you opt in.

```bash
docker compose --profile backup up -d
```

Dumps land in the `backup_data` volume. The service prunes them after
`BACKUP_RETENTION_DAYS`, which is 14 by default.
`BACKUP_INTERVAL_SECONDS` sets the cadence.

**That volume sits on the same host as the database.** It protects you from a
bad migration and from fat fingers. It does not protect you from a dead
machine. Copy the dumps off the host on a schedule.

**Kubernetes.** `deploy/k8s/backup-cronjob.yaml` applies the same discipline
against any S3-compatible bucket. It dumps, checks the size, uploads,
verifies, then prunes. It sits commented out of the kustomization until you
create its secret, and the setup notes are at the top of the file.

## Run the restore drill

A backup nobody restored is a hypothesis. Restore the newest dump into a
scratch database and look at it. Do this from time to time, and always before
an upgrade.

Compose:

```bash
docker compose --profile backup exec backup ls -lh /backups
docker compose exec postgres createdb -U postgres fountain_drill
docker compose --profile backup exec backup \
  pg_restore --no-owner -d "dbname=fountain_drill" /backups/fountain-<ts>.dump

# Does it hold what production holds?
docker compose exec postgres psql -U postgres -d fountain_drill -c \
  "SELECT (SELECT count(*) FROM users) AS users,
          (SELECT count(*) FROM conversations) AS conversations,
          (SELECT max(inserted_at) FROM audit_events) AS newest_audit_row"

docker compose exec postgres dropdb -U postgres fountain_drill
```

Kubernetes. Fetch the dump from the bucket, then do the same against a scratch
database on your Postgres.

```bash
aws s3 cp s3://<bucket>/pg_dump/fountain-<ts>.dump .
createdb -h <host> -U <user> fountain_drill
pg_restore --no-owner -h <host> -U <user> -d fountain_drill fountain-<ts>.dump
```

The drill passes when the counts look like production, and the newest rows
come from the night of the dump. It does not pass because `pg_restore` exited
zero.

## Restore for real

Stop the app first, so that nothing writes in the middle of the restore. Use
`docker compose stop app`, or scale the deployment to zero. Then replace the
live database, and start the app again.

```bash
pg_restore --clean --if-exists --no-owner -d "$DATABASE_URL" fountain-<ts>.dump
```

Two rules decide whether this works.

- The restored data decrypts under one key only, the `MASTER_SECRETS_KEY` that
  was live when you took the dump. If you rotated the key since, you need the
  old one.
- If the restore crosses an upgrade boundary, run the image version that
  matches the dump. Read [Upgrade an instance](upgrade.md).

## Know that the job still runs

A backup job that stops without a sound is the classic way backups rot.

The Kubernetes CronJob has the
[Sentry Crons check-in](../../integrations/sentry.md#crons-an-alert-when-a-scheduled-job-stops)
built in. Set `SENTRY_DSN`, then arm the monitor's schedule.

The portable alerts cover the dump CronJob. If you use CNPG for point-in-time
recovery, add the separate base-backup and WAL alerts described in
[Which alerts you get](observability.md#which-alerts-you-get).

On compose, read the dates on the service's log lines.

```bash
docker compose --profile backup logs backup | tail -5
```
