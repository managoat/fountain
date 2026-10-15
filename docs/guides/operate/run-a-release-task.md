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
| `Fountain.Release.verify_email("a@b.c")` | Marks an account's email verified, and sends nothing. The escape hatch for a mail provider that broke; with `EMAIL_DELIVERY=none`, accounts self-verify at registration (ADR 0011). |
| `Fountain.Release.promote_admin("a@b.c")` | Grants the admin role, recorded in the admin audit trail under a system actor. The manual alternative to `FIRST_USER_ADMIN=true` (ADR 0011). |
| `Fountain.Release.inventory_sandbox_metadata()` | Prints retained sandbox IDs and counts of absent skill metadata. Read-only. |
| `Fountain.Release.backfill_turn_replies()` | Fills the reply column on each turn that closed before the column existed. Safe to rerun. |
| `Fountain.Release.migrate()` | Runs the migrations that are due; it is what `bin/migrate` runs. They already run at each boot unless `MIGRATE_ON_BOOT=false`, and then this, in a Job before the rollout, is how they run at all. |
| `Fountain.Release.rollback(Fountain.Repo, version)` | Rolls migrations back to a version. A last resort for one migration you understand, never a whole release's on production data. Read [Upgrade an instance](upgrade.md) first. |

## Inventory older sandbox metadata

`inventory_sandbox_metadata/0` reports every sandbox row that is not
`terminated`, with its owner, status, provider, mode and whether a skills
selection is recorded. It reads the database only: it makes no provider
request, wakes no sandbox and changes no row, so it cannot say whether a
manifest still exists on disk (`disk_skill_manifests` is always
`unverified`).

An ordinary wake upgrades an older disk's skill manifest on its own. A wake
that cannot establish which skills Fountain owns stops with
`legacy_skill_ownership_unknown`, `invalid_skill_manifest` or
`skill_installation_incomplete` and changes nothing. Do not delete or replace
the manifest; start a new conversation, which gets a fresh sandbox. To inspect
or upgrade one retained disk by hand, follow the
[skill-manifest recovery procedure](https://github.com/managoat/fountain/blob/main/contributing/skill-manifest-recovery.md)
in the repo.
