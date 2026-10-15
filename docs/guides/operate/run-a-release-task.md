# Run a release task

Every operator action that touches data uses the same pattern.

## The pattern

Compose:

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.verify_email("you@example.com")'
```

Kubernetes:

```bash
kubectl exec -n fountain deploy/fountain -- \
  sh -c "PHX_SERVER=false bin/fountain_server eval 'Fountain.Release.verify_email(\"you@example.com\")'"
```

`eval` starts the database connection and nothing else, never the app, so a
task cannot compete with the live server for ports, background jobs or
conversation processes. `PHX_SERVER=false` says so out loud in a container
that sets it `true`; include it, and the pattern is always safe to paste.

## The tasks

| Task | What it does |
|---|---|
| `Fountain.Release.verify_email("a@b.c")` | Marks an account's email verified, and sends nothing. The escape hatch for a mail provider that broke; with mail off, accounts self-verify at registration (ADR 0011). |
| `Fountain.Release.backfill_turn_replies()` | Fills the reply column on each turn that closed before the column existed. Safe to rerun. |
| `Fountain.Release.migrate()` | Runs the migrations that are due; it is what `bin/migrate` runs. They already run at each boot unless `MIGRATE_ON_BOOT=false`, and then this, in a Job before the rollout, is how they run at all. |
| `Fountain.Release.rollback(Fountain.Repo, version)` | Rolls migrations back to a version. A last resort for one migration you understand, never a whole release's on production data. Read [Upgrade an instance](upgrade.md) first. |
