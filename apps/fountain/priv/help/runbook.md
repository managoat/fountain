# Operator runbook

What to do when something's wrong with a running Fountain instance.

## Emergency switches

### Revoke or rotate a user's API keys

API keys are minted per-user and SHA-256-hashed at rest. Either revoke a single leaked key, or revoke them all and have the user re-issue.

```bash
# Single key
fountain keys list                  # find the id
fountain keys revoke <id>

# Or via the API as the affected user
curl -s -X DELETE "$FOUNTAIN_BASE_URL/api/auth/api-keys/<id>" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY"
```

CLI sessions pick up the change on next request (401 on the revoked key). UI sessions are cookie-backed and continue until logout/timeout.

### Rotate `MASTER_SECRETS_KEY`

`MASTER_SECRETS_KEY` wraps each tenant's data encryption key (DEK), stored in `user_data_keys.wrapped_key`. The DEKs themselves never change on rotation — only the wrap does. **Updating the env var without re-wrapping** breaks every login (`load_tenant_key/1` returns `{:error, :unwrap_failed}` on every conversation start).

Re-wrapping procedure (manual — bin/server remote on the running node):

```elixir
old_master = "<old MASTER_SECRETS_KEY base64>" |> Base.url_decode64!(padding: false)
new_master = "<new MASTER_SECRETS_KEY base64>" |> Base.url_decode64!(padding: false)

# Restore the old master, unwrap every tenant DEK in memory
Application.put_env(:fountain, :master_secrets_key, old_master)

deks =
  Fountain.Repo.all(Fountain.Accounts.UserDataKey)
  |> Enum.map(fn udk ->
    {:ok, dek} = Fountain.Crypto.load_tenant_key(udk.user_id)
    {udk.id, dek}
  end)

# Switch to the new master, re-wrap and persist
Application.put_env(:fountain, :master_secrets_key, new_master)

for {id, dek} <- deks do
  udk = Fountain.Repo.get!(Fountain.Accounts.UserDataKey, id)
  udk
  |> Ecto.Changeset.change(wrapped_key: Fountain.Crypto.wrap_dek(dek))
  |> Fountain.Repo.update!()
end
```

Then update the `MASTER_SECRETS_KEY` env var in your deploy and restart. DEKs already loaded into running ConversationServers stay valid for the rest of those conversations — they're held in GenServer state, not re-fetched per request.

## Stuck conversation

Symptoms: conversation status shows `running` but no SSE events arrive.

```bash
fountain conv show <conv-id>          # see turn status, sandbox name
fountain conv interrupt <conv-id>     # stop the in-flight turn (sandbox lives)
fountain conv terminate <conv-id>     # destroy the sprite + mark conv terminated
```

If `interrupt` returns `no_turn_running`, the GenServer thinks no turn is in flight — most likely the sprite-side process exited and we missed the `:exit` message. Send a fresh prompt; `wake_conversation` will spin up a new sandbox, keeping the conversation history (claude `--resume` via persisted `runtime_session_id`).

## Orphaned sprites

`Fountain.Workers.SandboxReaper` runs hourly and handles this. Each run:

1. marks `pending`/`starting` sandboxes older than 60 minutes as `failed` when no `ConversationServer` is alive for them — this is what frees a tenant's concurrent-sandbox quota after a crash mid-provision;
2. destroys sprites whose sandbox row is already `terminated` or `failed`, up to 25 per run;
3. counts sprites with no sandbox row at all, and **touches none of them**.

Step 3 is deliberate. The same `SPRITES_TOKEN` may be in a developer's shell or another instance, and a sprite created seconds ago may not have committed its row yet — absence of a row is not evidence of a leak, and that is the one mistake here that cannot be undone.

Check what it is seeing:

```bash
kubectl logs -n fountain -l app=fountain --since=2h | grep 'reaper:'
# reaper: released=0 destroyed=2 untracked=102 live=114
```

A steady non-zero `destroyed` means sprite deletion is failing on the normal path — both `Sprites.destroy` call sites in `ConversationServer` discard their result, so the reaper is the only thing that notices.

### Cleaning up untracked sprites by hand

The reaper will never do this. Look at the list before deleting anything.

```bash
TOKEN=$(kubectl get secret fountain-secrets -n fountain \
  -o jsonpath='{.data.SPRITES_TOKEN}' | base64 -d)

# The response is an object, not an array, and it pages at 50 with
# has_more/next_continuation_token — a single unpaginated call sees a fraction
# of the account.
curl -sS https://api.sprites.dev/v1/sprites \
  -H "Authorization: Bearer $TOKEN" | jq -r '.sprites[].name'

kubectl exec -n fountain fountain-pg-1 -- \
  psql -U postgres -d fountain -At -c "SELECT sprite_name FROM sandboxes"

curl -sS -X DELETE https://api.sprites.dev/v1/sprites/<name> \
  -H "Authorization: Bearer $TOKEN"
```

As of 2026-08-01 the untracked set is 102 sprites named `aod-*`, all `cold`, created before the rename to `fountain-*`. They are safe to remove; nothing in the current schema references them.

## Account deletion / erasure request

Users close their own account at **/account → Delete account**, typing their email to confirm. For someone locked out, or a request that arrived by email, use **/admin → Delete** on their row.

Both run `Fountain.Accounts.Deletion.delete_user/2`, in this order:

1. cancel every non-terminal Stripe subscription — **if this fails nothing is deleted**, because an account that no longer exists but is still being charged leaves the person with nowhere to cancel from;
2. destroy the tenant's sprites (failures here are logged; `SandboxReaper` finishes the job);
3. write an `account.deleted` audit event carrying the email and user id in `metadata`, since `audit_events.user_id` nilifies on delete;
4. delete the user row — cascades take agents, api_keys, conversations, environments, vaults, oauth_identities, inference_credentials and `user_data_keys`.

Deleting `user_data_keys` destroys the per-tenant DEK, so any residual ciphertext is unrecoverable rather than merely unreferenced.

`usage_events`, `audit_events` and `sandboxes` nilify their `user_id` instead of cascading — operational and financial history survives without naming anybody.

**Backups still hold the data.** A `pg_dump` taken before the deletion contains both the ciphertext and the wrapped key. If a request requires erasure from backups, the honest answer is the retention window: state it, and let the backups expire.

The Stripe customer is deliberately *not* deleted. Invoices are financial records the business is required to retain, and Stripe is the system of record.

## Rate limit overflow

Symptoms: API returns `429 rate_limited` with a `Retry-After` header.

The default bucket is 600 req/min per IP. If a script is hot-looping, the response itself tells you when to retry. Don't drop the limit globally; instead bump it for that endpoint:

```elixir
# router.ex
plug FountainWeb.Plugs.RateLimit, bucket: "api", max: 1200
```

To clear the counter manually (e.g., in dev):

```elixir
# bin/server remote
:ets.delete_all_objects(FountainWeb.Plugs.RateLimit.table())
```

## Audit log overgrows

The `audit_events` table is append-only.

```bash
# How big?
psql "$DATABASE_URL" -c "SELECT count(*) FROM audit_events"

# Trim to last 30 days
psql "$DATABASE_URL" -c \
  "DELETE FROM audit_events WHERE inserted_at < NOW() - INTERVAL '30 days'"

# Reclaim space (Postgres handles this with autovacuum normally; force if needed)
psql "$DATABASE_URL" -c "VACUUM ANALYZE audit_events"
```

## What you have when it breaks

**Dashboards.** Five of them, three in Grafana and two in PostHog. The Grafana
JSON lives in `deploy/grafana/` and ships as ConfigMaps labelled
`grafana_dashboard: "1"` (generated by `deploy/grafana/kustomization.yaml`,
pulled in by `k8s/kustomization.yaml`); the sidecar watches every namespace, so
a deploy delivers them. Edit the JSON and open a PR — a change made in the
Grafana UI is overwritten on the next deploy. `docs/guides/operate/dashboards.md`
is the full description; the short version:

| Dashboard | Open it when |
|---|---|
| **Fountain / Ops** (Grafana) | Something is broken. Golden signals, provisioning by sub-step, Oban, and two Tempo panels |
| **Fountain / Product** (Grafana) | You want volume and latency. Lifecycle funnel, turn outcomes, time to first output |
| **Fountain / Finance** (Grafana) | You want cost drivers. Live sandboxes by provider, sandbox-minutes, untracked sprites, dropped usage events |
| **Fountain / Product** (PostHog) | You want *who*. Retention, activation funnel, per-account failures |
| **Fountain / Finance** (PostHog) | You want *which account*. Top accounts by provisions and turns, usage by subscription status |

Two traps live in those panels, and both bite silently:

- **Gauges are duplicated per replica.** Funnel, conversation, sandbox and Oban
  gauges are polled from the same database by every pod, so each one exports the
  same value. Use `max`, never `sum` — a `sum` reports two replicas as twice the
  work. Counters are the opposite: each pod counts its own events, so they want
  `sum`. Where both apply, collapse first and add second:
  `sum(max by (provider) (fountain_sandboxes_by_provider_count{...}))`.
- **A counter that has never fired has no series**, and a panel reading it says
  *No data*, not 0. Panels watching for rare failures end in `or vector(0)` for
  exactly this reason. `fountain_usage_dropped_count` is the one worth knowing:
  metering swallows its own failures by contract, so a broken meter and a quiet
  week look identical everywhere else.

```bash
# Is the sidecar serving them?
kubectl get cm -n fountain -l grafana_dashboard=1
kubectl logs -n monitoring deploy/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=20
```

**Metrics.** The app exposes Prometheus metrics on port 9568 (`FountainWeb.MetricsPlug`),
scraped every 30s by the cluster's kube-prometheus-stack and queryable in Grafana.
Deliberately *not* on the public endpoint — the IngressRoute matches on `Host`
with no path predicate, so anything mounted there is world-readable.

Useful series: `phoenix_router_dispatch_stop_count` (request rate, by route,
method and status), `phoenix_router_dispatch_stop_duration_bucket` (latency),
`phoenix_router_dispatch_exception_count` (unhandled errors),
`fountain_repo_query_queue_time_bucket` (connection-pool saturation),
`fountain_stage_count{stage="provision", status="done"|"failed"}` (sandbox
provisioning; `stage="turn"` for agent turns).

```bash
kubectl port-forward -n fountain svc/fountain 9568:9568
curl -s localhost:9568/metrics | head -40
```

**Logs.** Alloy ships all pod logs to Loki; query `{namespace="fountain"}` in
Grafana. Phoenix request logging is on — it was disabled in `config/prod.exs`,
which meant production kept no record of HTTP requests at all. Set
`PHOENIX_REQUEST_LOG=false` on the Deployment to mute it without a code change.

**Alerts.** `k8s/prometheusrule.yaml` routes through Alertmanager to ntfy
(warning = priority 3, critical = priority 4). Covers backup staleness and
failure, metrics target down, 5xx rate, unhandled exceptions, DB pool
saturation, and provisioning failures.

```bash
kubectl get prometheusrule -n fountain
# currently firing:
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
curl -s localhost:9090/api/v1/alerts | jq '.data.alerts[] | select(.labels.namespace=="fountain")'
```

**Traces.** Instrumented (`Fountain.Telemetry` spans, `traceparent` propagated
into sprites) and exported to Tempo, which runs in-cluster and keeps its blocks
in garage. The Deployment sets `OTEL_EXPORTER_OTLP_ENDPOINT` at
`tempo.tempo.svc.cluster.local:4318`; that alone turns the export on, since
`runtime.exs` treats "no target configured" as "export nothing". Query them in
Grafana under the **Tempo** datasource. A span carries `k8s.namespace.name` and
`k8s.pod.name`, so the Tempo → Loki jump lands on the logs for the same pod and
time window.

Retention is 72h, capped by a 5 GiB quota on the garage bucket. If traces stop
appearing, check the bucket first — garage refuses writes past the quota rather
than evicting:

```bash
kubectl exec -n garage garage-0 -- /garage bucket info tempo
kubectl logs -n tempo statefulset/tempo --tail=50
```

**Error tracking.** Sentry, wired in three places: `Sentry.LoggerHandler`
(attached by `Fountain.Application`, rate-limited to 20 events a minute),
`Sentry.PlugContext` on the endpoint for request context, and
`in_app_otp_apps: [:fountain]` so the SDK knows which frames are ours. Events
carry `release: FOUNTAIN_BUILD_SHA`, so a regression points at the deploy that
introduced it, and `environment_name` from `SENTRY_ENVIRONMENT`.

Nothing tenant-shaped rides along. `send_default_pii: false` keeps cookies,
user IPs and bodies out by default, and `FountainWeb.SentryScrubber` replaces
every string in a request body with a length tag (#402) — an allowlist of
shape, because Sentry's own scrubber is a three-name denylist that the
secret-write endpoints sailed straight through.

`SENTRY_DSN` arrives in the Infisical-materialized Secret. An instance without
one skips the handler entirely, and a *blank* one is deleted from the
environment rather than passed through, because the SDK reads the variable
itself and a blank value crashes the `:sentry` app at boot no matter what the
config says (#497, #513). The package is API-compatible with GlitchTip, so
re-pointing `SENTRY_DSN` is the whole migration if you ever want the tracker
off this cluster.

## Email is not being delivered

Production refuses to boot with no mail delivery configured, so an instance
that is running has one of `RESEND_API_KEY`, `SMTP_HOST`, or
`EMAIL_DELIVERY=none`. That last one disables email entirely.

Symptom: a user signs up, never receives a verification email, and cannot log
in — `hooks.ex` refuses login while `email_verified_at` is nil.

```bash
# Which mode is this instance in?
kubectl exec -n fountain deploy/fountain -- sh -c 'echo "resend=${RESEND_API_KEY:+set} smtp=${SMTP_HOST:-unset} delivery=${EMAIL_DELIVERY:-default}"'
```

Verify an account without sending anything — the escape hatch for
`EMAIL_DELIVERY=none`, and for a provider outage:

```bash
kubectl exec -n fountain deploy/fountain -- \
  bin/fountain_server eval 'Fountain.Release.verify_email("user@example.com")'
```

Sending domains must be verified with the provider (SPF/DKIM/DMARC) before
`EMAIL_FROM` can deliver to arbitrary inboxes, so a freshly configured provider
can accept mail and still have it rejected downstream.

## Granting admin without the panel

The first admin — or an instance whose only admin is locked out — cannot use
**/admin**. Grant the role from a release task instead; it is recorded as
`admin.role.granted` with a system actor, so it shows in the admin audit trail
like any panel-originated grant:

```bash
kubectl exec -n fountain deploy/fountain -- \
  sh -c "PHX_SERVER=false bin/fountain_server eval 'Fountain.Release.promote_admin(\"you@example.com\")'"
```

Revoking has no release task; that is done from **/admin**, by an admin, on
purpose.

## Postgres backup + restore

A `fountain-pg-backup` CronJob (`k8s/backup-cronjob.yaml`) takes a compressed
`pg_dump` every night at 03:17 UTC and uploads it to the private
`fountain-backups` bucket on the home-cloud Garage cluster, under `pg_dump/`.
Dumps older than 14 days are pruned after each successful upload.

The job verifies the uploaded object's size against the local file and fails if
they differ — a silently truncated upload is the failure mode that would
otherwise stay hidden until you needed it.

**Recovery granularity is 24 hours.** This is a nightly logical dump, not
continuous archiving; there is no point-in-time recovery. CNPG's own
`barmanObjectStore` would give PITR but is not usable here: as of CNPG 1.26 the
barman-cloud tooling moved out of the operand images into a separate plugin, and
neither the plugin nor its `ObjectStore` CRD is installed on this cluster.
Configuring `spec.backup` without it yields a Cluster that reports healthy and
archives nothing.

**Garage is in the same cluster as the database.** This covers a bad migration,
an accidental `DROP`, or an application bug. It does not cover loss of the
cluster or the site.

### Check backups are actually running

```bash
kubectl get cronjob fountain-pg-backup -n fountain
kubectl get jobs -n fountain -l app=fountain --sort-by=.metadata.creationTimestamp | tail -5
kubectl exec -n garage garage-0 -- /garage bucket info fountain-backups
```

### Restore

Note the Garage quirk: `aws s3 cp` issues a `HeadObject` first and Garage
answers that with `400`, so **use `s3api get-object` to download**. Uploads via
`s3 cp` are fine.

```bash
# Credentials for the backup bucket (never printed)
eval "$(kubectl get secret fountain-backup-s3-credentials -n fountain \
  -o go-template='export AWS_ACCESS_KEY_ID={{index .data "AWS_ACCESS_KEY_ID" | base64decode}}{{"\n"}}export AWS_SECRET_ACCESS_KEY={{index .data "AWS_SECRET_ACCESS_KEY" | base64decode}}{{"\n"}}')"
export AWS_DEFAULT_REGION=garage
EP=http://garage-s3:3900        # over the tailnet; in-cluster use http://s3.garage.svc.cluster.local:3900

# Newest dump
LATEST=$(aws --endpoint-url $EP s3api list-objects-v2 --bucket fountain-backups \
  --prefix pg_dump/ --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
aws --endpoint-url $EP s3api get-object --bucket fountain-backups --key "$LATEST" restore.dump

# Restore into a scratch database first and compare, before touching the live one.
# `postgres` is superuser but only over the pod's local socket — the app role is
# deliberately NOCREATEDB, so grant it for the duration and revoke afterwards.
kubectl exec -n fountain fountain-pg-1 -c postgres -- psql -U postgres -c "CREATE DATABASE restore_verify;"
kubectl exec -n fountain -i fountain-pg-1 -c postgres -- \
  pg_restore -U postgres -d restore_verify --no-owner --no-privileges < restore.dump
kubectl exec -n fountain fountain-pg-1 -c postgres -- \
  psql -U postgres -d restore_verify -c "SELECT count(*) FROM users;"
```

`pg_restore` reports one ignored error, `must be owner of extension vector`, on
a `COMMENT ON EXTENSION` statement. It is cosmetic — the extension comes from
the cluster's `postInitTemplateSQL` and the data restores fully.

This procedure was exercised end to end on 2026-08-01 against a real nightly
artifact: every table matched the live database (users 191, agents 45,
conversations 255, environments 22, vaults 5). Re-run it periodically — a
backup nobody has restored is a hypothesis, not a backup.

## BEAM crash recovery

Symptoms: server is up but conversations show as `running`/`idle` from before the crash.

`Fountain.Conversations.Rehydrator` runs on every successful boot (see `apps/fountain/lib/fountain/application.ex` after `Supervisor.start_link`). It scans conversations whose status is non-terminal AND whose sandbox status was `ready` at the time of the stop, and starts a `ConversationServer` for each. The server enters reattach mode:

- If the sprite is still alive at sprites.dev → attach via `Sprites.list_sessions` + `attach_session`. Any in-flight detachable runtime command keeps streaming where it left off.
- If the sprite is gone → mark sandbox `failed`. The user's next prompt triggers `wake_conversation` to spin a fresh sandbox.

Conversations whose sandbox was `pending` or `starting` at the crash (mid-provision) are left as-is. The next user action resolves them via `wake_conversation`.

## Stuck OpenAPI validation

Symptoms: API call returns `422` with `{"errors":[{"message":"Missing field: <name>"}]}` for what looks like a valid payload.

Our request schemas are reused for POST and PUT today, so PUT requires the full Create shape. Workaround: include all the required fields on PUT, or use the LiveView UI which talks to the context functions directly (no OpenAPI gate).

## "I just deployed and the rate limiter keeps blocking me"

ETS table state resets whenever the node restarts, which every redeploy does. If you're hitting limits immediately post-deploy, that's a real load issue, not a rollover artifact.

## Adding a new node (clustering)

`libcluster` with the `Cluster.Strategy.DNSPoll` topology is wired up via `CLUSTER_DNS_QUERY` (see `config/runtime.exs`). On Render, set it to the internal DNS name of the service for multi-instance deployments. `Registry`, `DynamicSupervisor`, and `Phoenix.PubSub` are still local — cross-node ConversationServer routing isn't implemented yet.
