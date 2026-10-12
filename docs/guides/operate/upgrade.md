# Upgrade an instance

This guide shows you how to move an instance to a newer Fountain release, and
what to do when an upgrade goes wrong.

## Before you start

Take a backup. An upgrade is the one moment where the supported path back
needs one. Read [Back up and restore](back-up-and-restore.md).

Read **Upgrade notes** in the [changelog](../../changelog.md) before a minor
bump.

## How versions work

Fountain follows [SemVer](https://semver.org/), before 1.0. A patch release,
`v0.3.0` to `v0.3.1`, is always safe to take. A minor release, `v0.3` to
`v0.4`, can break something. The changelog calls each break out under
**Upgrade notes**.

Each release publishes the server image to `ghcr.io/managoat/fountain`
under two tags, next to the tags that track development.

| Tag | Moves? | Use it for |
|---|---|---|
| `vX.Y.Z` | Never. | To pin a known version. This is the default we suggest. |
| `vX.Y` | To the newest patch in the line. | To take patches on their own, with no risk of a minor that breaks something. |
| `latest` | On each merge to `main`. | Nothing you keep in production, because it moves under you. |
| `sha-<commit>` | Never. | To reproduce exactly what one commit built. |

## The `-core` tags

Earlier releases also published each version with a `-core` suffix, an image
without the first-party extensions. Fountain no longer has extensions, so a
release publishes one image under the tags above. A `-core` tag you pinned
keeps working, but no new version is published under one. To take a newer
release, move to the tag without the suffix.

Releases v0.2.1 and earlier are older than the image tags. They exist as
`sha-` tags alone.

## Build your own image

```bash
docker build -t fountain .
```

For a release built directly from the source tree, use
`MIX_ENV=prod mix release fountain_server`.

## Take a new version

The compose file reads `FOUNTAIN_IMAGE_TAG` from `.env`, and
`.env.compose.example` ships it set to a pinned release. A fresh install is
therefore pinned by construction. Leave the variable unset and the compose
file still falls back to a pinned release, and not to `latest`.

To upgrade, edit that value, then pull.

```bash
docker compose pull && docker compose up -d
```

Migrations run on their own at boot. They are idempotent, and a Postgres
advisory lock serializes them. Replicas that roll do not race each other. You
run no manual migration step, unless a release's upgrade notes say to.

A migration that builds an index concurrently opts out of that lock by design.
Fountain writes such a migration so that a second run is safe.

Did you move migrations into a Job with `MIGRATE_ON_BOOT=false`? Then the Job
is the upgrade step. Read
[Run migrations in a Job](database.md#run-migrations-in-a-job).

## Vault policy migration

Migration `20260913180000` adds generated `vault_access` columns to agents and
saved agent versions. New authorization readers use the explicit mode. Existing
clients keep sending `allowed_vault_ids`: `null` permits all current and future
vaults owned by the tenant, `[]` denies vault attachments, and a non-empty list
permits only those IDs within the tenant. SDK payloads and saved configs keep
their existing shape. A historical version with no vault key leaves the current
policy unchanged on restore; an explicit `null` restores unrestricted access.

Run this migration before starting the new server code. PostgreSQL derives the
mode on every write, so old and new servers can continue writing the existing
field during the rollout. No client upgrade or list of current vaults is needed.
`allowed_vault_ids` stays the API input: the explicit mode is internal and is
not part of the wire contract.

These stored columns rewrite both tables and hold exclusive locks until the
migration commits. Each statement has a five-second lock wait and a 30-second
execution limit; failure rolls back the whole migration. Schedule a maintenance
window for busy or large tables and verify the migration completes before
rolling the application. If it exceeds these bounds, keep the existing server
running and plan a separate migration approach for that database size.

## Environment policy migration

Migration `20260915220000` does the same for the per-launch environment
allowlist: it adds generated `environment_access` columns to agents and saved
agent versions. Existing clients keep sending `allowed_environment_ids`: `null`
permits all current and future environments owned by the tenant, `[]` permits
no override, and a non-empty list permits only those IDs within the tenant.
Naming the agent's own environment is not an override, so it stays permitted
under every policy. SDK payloads and saved configs keep their existing shape,
and a historical version behaves the way the vault one does — no environment
key leaves the current policy unchanged, an explicit `null` restores
unrestricted access.

Everything said above about running the vault migration applies here: run it
before starting the new server code, both old and new servers can keep writing
the existing field during the rollout, and the same lock and timeout bounds and
maintenance-window advice hold.

## Credential set policy migration

Migration `20260915230000` is the last of the three. It adds generated
`inference_credential_access` columns to agents and saved agent versions.
Existing clients keep sending `allowed_inference_credential_ids`: `null`
permits all current and future credential sets owned by the tenant, `[]`
permits no override, and a non-empty list permits only those IDs within the
tenant. Naming the set the agent already runs on is not an override, so it
stays permitted under every policy. Saved configs, SDK payloads and historical
restores behave exactly as they do for vaults and environments.

Run it the same way and under the same bounds as the two above. After this
migration no allowlist on an agent relies on a null to mean "anything the
tenant owns"; the policy is readable from the record.

## Claimable principals removed

Claimable principals (`/api/claimable-users`) are gone, along with the
`principal` API-key scope. Migration `20261012120000` drops the
`claimable_users` and `principal_owners` tables and the
`api_keys_active_principal_expiry_required` CHECK. It deletes every remaining
principal account, and with it that account's agents, conversations and keys.
It then makes `users.email` required again.

A migration cannot reach a sandbox provider, so it leaves a principal's
sandboxes running. Release each open principal with the previous release
before you upgrade. This query must return `0`:

```text
SELECT count(*) FROM users WHERE principal;
```

The `users.principal` column stays for one release, so replicas from the
previous release keep working during a rolling upgrade. A later migration
drops it.

## Conversation message compatibility

The server uses the `managoat_acp` peer from its own release. The audited peer
floor is version `0.4.2`, pinned in `mix.lock`. It reports model refusal as
`{:failed, {:model_selection_failed, requested, detail}}` before it sends a prompt.
The retired `model_rejected` event has no receiver.

Each conversation starts its peer locally. The peer monitors its owner and
stops when that owner exits. Replace the server process during upgrades;
hot code replacement across peer versions is not a supported upgrade path.
Sandbox adapters send ACP protocol messages, not these internal peer events.

Conversation servers accept only `{:terminate_conv, opts}` and
`{:machine_gone, sandbox_id, event, reason, message}`. Termination options carry
`actor` and `request_ip` across nodes. A sandbox-loss notification for a different
sandbox leaves the current actor and its turn alone. The old atom and unqualified
notification are unsupported.

### Required cluster floor

Do not deploy this removal directly into a cluster with older nodes. Complete a
bridge rollout first. The bridge must contain both of these commits.

| Change | Required commit |
|---|---|
| Attributed termination sender and receiver | [aecaf345](https://github.com/managoat/fountain/commit/aecaf345b0ef4e31edb466fe603dcf5537cde1cc) |
| Sandbox-qualified lifecycle senders | [da27fb2c](https://github.com/managoat/fountain/commit/da27fb2cec2b9f3ae5df655d54ec4c5d4b0cfc9a) |

Commit `da27fb2c` includes both changes and the qualified receiver. This is the
source floor for cluster messages, not a claim about deployed images. The peer
floor above applies separately. A bridge built from
[f7706e01](https://github.com/managoat/fountain/commit/f7706e013714dc0ca4e279aee59e785ab8760163) contains both floors
and retains the compatibility handlers.

1. Deploy the bridge with full server-process replacement. Include workers and
   other cluster members outside the web deployment.
2. Wait for every older node and conversation owner to exit. Hot code replacement
   does not drain old actors or their mailboxes.
3. Record each connected node's image digest and source revision, completed
   rollout status, and evidence that older processes cannot reconnect. Check
   scaled-down workloads and rollback automation as well as current replicas.
4. Deploy the removal only after that record establishes the floor everywhere.
   Bridge and removal nodes can coexist. Nodes below the floor cannot rejoin.

For a direct upgrade without a bridge, stop every old cluster process before
starting any removal process. This requires an outage. The normal backup and
migration rules still apply.

A rollback must also preserve the floor. Use the bridge only where the migration
rules permit it. Never reintroduce a pre-floor node into the upgraded cluster.
The retirement work in [issue #2099](https://github.com/managoat/fountain/issues/2099)
requires an operator to record this evidence before release. Source inspection
and tests alone cannot establish that a rollout or actor drain has completed.

On 2026-09-13, read-only hosted checks found two ready replicas at
[31a74cc9](https://github.com/managoat/fountain/commit/31a74cc998ec43c8d4ec17ff5739e7e6dd962643),
a descendant of the bridge. All older ReplicaSets had zero replicas and no old
pods remained. Each node saw only its counterpart and its temporary inspection
client. This establishes the hosted process floor at that observation. It does
not establish the floor for another deployment or permit older nodes to return.

## Match the CLI to the server

The CLI and the server come from the same tag. The two versions that match are
the pair we test.

The CLI's built-in default `base_url` is the hosted instance,
`https://managoat.com`, and not yours. Point it at your instance
before you export an API key. Otherwise the first command you run without a
config sends that key to the hosted domain.

```bash
FOUNTAIN_BASE_URL=https://your-fountain.example.com fountain auth login
```

`auth login` records the URL in the saved profile, so you do this one time.

## Watch a deploy land

```bash
kubectl rollout status deployment/fountain -n fountain   # k8s
docker compose logs -f app                               # compose
```

A rollout that never completes usually means the startup probe fails, and that
means migrations that cannot finish. The readiness probe can also fail,
against a database problem that is older than the deploy. Read
[Pods restart or never go ready](../../troubleshooting/pods-restarting.md).

## When an upgrade goes wrong

Here are the rules, best first.

1. **Roll forward.** Pin `vX.Y.Z` tags, read **Upgrade notes** before a minor
   bump, and fix forward when something breaks.
2. **Do not downgrade once a newer version's migrations have run.** We do not
   support it. The supported path back is to restore the pre-upgrade database
   backup and run the previous image. You then lose the writes since the
   backup. That is why a backup before each upgrade is cheap insurance.
3. `Fountain.Release.rollback/2` exists to reverse one migration that you
   understand. Do not attempt to reverse a whole release's migrations on
   production data.

If a restore crosses an upgrade boundary, run the image version that matches
the dump.

## Related

- [Back up and restore](back-up-and-restore.md).
- [Run a release task](run-a-release-task.md), for `rollback/2` and
  `migrate/0`.
- [Changelog](../../changelog.md).
