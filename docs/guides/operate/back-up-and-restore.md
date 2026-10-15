# Back up and restore

A backup here is two things. It is a `pg_dump` of Postgres **and the
`MASTER_SECRETS_KEY` that was live when you took it**. The key wraps each
tenant's encryption key. Restore a dump without that key and nothing will ever
decrypt its secrets. Which key was live at the moment of the dump is part of
that backup's identity.

## Back `MASTER_SECRETS_KEY` up

Fountain encrypts each environment and vault secret with a key for that
tenant, and it wraps that key with `MASTER_SECRETS_KEY`. **Lose that key and
you lose each stored secret. Change it without re-wrapping and you lose them
too.**

By design, Fountain does not store it in the database. A database backup alone
does not protect you.

Keep it somewhere apart from your database backups. Treat a rotation of it as
a migration, and not as a config change: the next section is the procedure.

## Rotate `MASTER_SECRETS_KEY`

A rotation changes the wrap and nothing else. Each tenant's key stays the
same, so no secret is re-encrypted; each row of `user_data_keys` is unwrapped
under the old master and wrapped again under the new one. Changing the
variable without that step leaves every tenant key unreadable, and every
conversation start and egress request fails with `unwrap_failed`.

1. Take a backup, and keep it with the **old** key.
2. Generate the new key the way you generated the first one.
3. Run the re-wrap below in the app container, with both keys in its
   environment as `OLD_MASTER_SECRETS_KEY` and `NEW_MASTER_SECRETS_KEY`. It
   runs in one transaction, and skips a row that already unwraps under the new
   key, so it is safe to run again.
4. Set `MASTER_SECRETS_KEY` to the new key in your deploy and restart.
5. Run the re-wrap once more. The live server held the old key until the
   restart, so an account created in between got a key wrapped under the old
   one; the second run re-wraps it.

```elixir
decode = &Base.url_decode64!(System.fetch_env!(&1), padding: false)
old = decode.("OLD_MASTER_SECRETS_KEY")
new = decode.("NEW_MASTER_SECRETS_KEY")
use_key = &Application.put_env(:fountain, :master_secrets_key, &1)
Application.ensure_all_started(:ssl)
Application.ensure_loaded(:fountain)

{:ok, _, _} =
  Ecto.Migrator.with_repo(Fountain.Repo, fn repo ->
    repo.transaction(fn ->
      for udk <- repo.all(Fountain.Accounts.UserDataKey) do
        use_key.(new)

        with {:error, :unwrap_failed} <- Fountain.Crypto.load_tenant_key(udk.user_id) do
          use_key.(old)
          {:ok, dek} = Fountain.Crypto.load_tenant_key(udk.user_id)
          use_key.(new)

          udk
          |> Ecto.Changeset.change(wrapped_key: Fountain.Crypto.wrap_dek(dek))
          |> repo.update!()
        end
      end
    end)
  end)
```

Save it as `rewrap.exs` in the container, and run it with
`bin/fountain_server eval 'Code.eval_file("rewrap.exs")'`, the way
[Run a release task](run-a-release-task.md) runs a task. A row that unwraps
under neither key stops the run, and the transaction writes nothing.

Old backups still need the old key. Keep it for as long as you keep a backup
taken before the rotation.

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

## Erase an account

A user deletes their own account from `/account`, or with
`DELETE /api/account`. An admin deletes someone else's with
`DELETE /api/admin/users/{id}`. Both destroy the account's sandboxes, write an
`account.deleted` audit event that names the email, and delete the user. The
delete cascades to the account's agents, environments, vaults, conversations,
keys and credentials. Usage, audit and sandbox rows keep their history with
the user removed from them. ADR 0009 records the design.

The delete also removes the account's wrapped key, so a stray copy of its
ciphertext can never be decrypted. **That does not reach your backups.** A dump
taken before the deletion holds both the ciphertext and the wrapped key, and
your retention window is what erases them. When a request asks for erasure from
backups, that window is the honest answer.

## Trim the audit log

`audit_events` is append-only. A daily job deletes rows older than 365 days,
the default in `config :fountain, :retention_days`. To keep less, delete the
older rows yourself, and remember that your backups keep them until they
expire. `admin_audit_events`, what admins did, is never pruned.

```bash
psql "$DATABASE_URL" -c "SELECT count(*) FROM audit_events"
psql "$DATABASE_URL" -c \
  "DELETE FROM audit_events WHERE inserted_at < NOW() - INTERVAL '180 days'"
```

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
