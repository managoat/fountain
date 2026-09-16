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

## Two distributions

Each tag above names the **bundled** image: the server plus the first-party
extensions, which is what this project has always published. Each release also
publishes the same version with a `-core` suffix.

| Tag | Contains |
|---|---|
| `vX.Y.Z` and `vX.Y` | The server with Buzz, Support, Google/Gmail, Microsoft and Slack extensions, plus the Buzz executables. |
| `vX.Y.Z-core` and `vX.Y-core` | The server. No extension, no extension route, no extension migration and no extension executable. |

Use the bundled image unless you know you want the other one. The hosted
deployment runs it, and we triage a bug report against it.

The core image is smaller and has less surface to attack. It is also what to
build an extension of your own against. The cost: hosted Buzz agents
(`/api/buzz/agents` and the Nostr harness) and the problem-report endpoint
answer `404`, because the code that serves them is not installed. The Gmail
MCP route is also absent. Core lists no Google, Microsoft or Slack platform
connection provider; their OAuth environment variables are inert. You can
revoke or delete retained connections locally. They contribute no token while
their extension is absent.

To move between them, pull the other tag and restart. Extension tables stay in
the database. A core image does not create them. It also does not drop the ones
a bundled image made, so a move back finds your rows where you left them.

Releases v0.2.1 and earlier are older than the image tags. They exist as
`sha-` tags alone.

## Build your own image

`BUNDLE_EXTENSIONS` is a build argument, defaulting to `true`. It selects the
release's applications and extension executables when Docker builds the image.
Setting it on a running container does not change its distribution.

```bash
# Bundled: Fountain with all first-party extensions.
docker build --build-arg BUNDLE_EXTENSIONS=true -t fountain:bundled .

# Core: Fountain without first-party extensions.
docker build --build-arg BUNDLE_EXTENSIONS=false -t fountain:core .
```

For a release built directly from the source tree, use
`BUNDLE_EXTENSIONS=false MIX_ENV=prod mix release fountain_server` to select
core. Omit the variable, or set it to `true`, to bundle the extensions.

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

## Principal credential expiry

Every unrevoked key with `principal` scope must have an expiry. The database
CHECK enforces this independently of the issuer. Full and sprite keys can
still omit expiry. Existing deadlines and revoked keys remain unchanged.

Principal issuance, create replay, claim, claim replay and owner renewal all
supply an explicit deadline through `Principals.principal_key_opts/2` starting
with [commit af1178dd](https://github.com/managoat/fountain/commit/af1178dd2b3462eb7a26e9d655ff3fe09681a0ed).
Anonymous credentials use their grant deadline; claimed credentials get 30 days
from issuance. The shared `Accounts.build_api_key/3` and `create_api_key/3`
changeset also rejects missing principal expiry starting with
[commit 1a005023](https://github.com/managoat/fountain/commit/1a005023d49556405d18dabc8cd11fed33a51db2).
The console, API key, login-token and OAuth issuers create full credentials;
sandbox callback issuers create sprite credentials. Those lifetimes are
unaffected. Principal inference-credential writes change provider secrets,
not the principal API key.

Migration `20260913125930` removes the old-writer trigger and its function.
Missing expiry then fails the CHECK rather than receiving an implicit 30-day
deadline. The migration first requires the permanent CHECK to be validated;
it never updates keys. Lock waits are bounded to five seconds and statements
to 30 seconds. A failure rolls back the retirement and leaves it pending.

**Finish the writer rollout before applying this migration.** Deploy a revision
containing both commits above, but preceding the retirement migration, to
every serving replica, worker and release-task process. Complete migrations
through `20260913111350`, then drain and stop every older process. Inventory
external database writers too: they must supply deadlines for principal keys.
Only after that boundary is verified may a deployment containing the retirement
migration start. Boot migrations run before replacement replicas serve requests,
so a direct rolling upgrade from older writers is unsupported. A fresh database
with no older processes can run the full migration sequence.

Record each writer's deployed revision and the completed drain before removal.
An image build, a published release or a validated CHECK alone does not prove
that old writers have stopped.

The hosted service's 2026-09-13 audit observed both ready replicas at commit
`31a74cc9`, with no older pods or active replica sets. The CHECK was validated,
and database clients belonged only to those replicas. No other Fountain writer
workloads or jobs were inventoried. That establishes the hosted rollout boundary;
self-hosted operators must establish it for their own processes and external
writers. The required bridge revision predates v0.17.0. There is no earlier release
tag containing the writer floor; use a reviewed bridge commit for this rollout.

To check the database prerequisite, this query must return one row with
`convalidated = true`:

```text
SELECT convalidated
FROM pg_constraint
WHERE conrelid = 'api_keys'::regclass
  AND conname = 'api_keys_active_principal_expiry_required';
```

A controlled rollback of this migration alone restores the 30-day default
trigger, retaining the CHECK and every assigned deadline. It restores only
this writer accommodation; it does not establish whole-release downgrade
support. Any older writer would require that accommodation before restarting:
an application-only rollback would reject its missing-expiry writes. Follow
[the recovery policy](#when-an-upgrade-goes-wrong) for a failed release.
Do not roll back the invariant or clear deadlines.

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
