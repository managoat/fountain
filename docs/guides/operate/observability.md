# Observability

This page covers metrics, the alerts and dashboards that ship with the repo,
logs, errors and the health endpoints.

## Metrics

The app serves Prometheus metrics on port 9568: routes, request rates,
database timings, and Managoat's own conversation, sandbox and background-job
series. The compose file does not publish that port. Map it to scrape it, and
keep it off the public internet.

The repo ships an observability pack built from a real run of the
maintainer's instance:

- **Alerts** in `deploy/k8s/prometheusrule.yaml`, listed below.
- **Dashboards** in `deploy/grafana/`, described below.

## Which alerts you get

The portable rules in
[`deploy/k8s/prometheusrule.yaml`](https://github.com/managoat/managoat/blob/main/deploy/k8s/prometheusrule.yaml)
are optional: enable the file in your Kustomization, and install the
PrometheusRule CRD and the scrapes its expressions need. Each rule carries a
comment that says what it means and what to do.

### Portable baseline

| Rule | What it watches |
|---|---|
| `FountainBackupStale` | The optional dump CronJob has not succeeded in 36 hours. |
| `FountainBackupNeverSucceeded` | The dump CronJob has no successful run. |
| `FountainBackupJobFailing` | A dump Job failed. |
| `FountainBackupSuspended` | The dump CronJob has `suspend: true`. |
| `FountainMetricsTargetDown` | Prometheus cannot scrape Managoat. |
| `FountainHighServerErrorRate` | More than 5% of HTTP responses are server errors. |
| `FountainUnhandledExceptions` | Request handlers raise exceptions. |
| `FountainDatabasePoolSaturated` | Requests wait for database connections. |
| `FountainProvisionFailures` | Sandbox provision attempts fail. |
| `FountainStageFailures` | A stage after provisioning fails more than twice in 30 minutes. |
| `FountainBrokerCAInstallFailureRate` | More than 10% of at least five conversation CA setups fail with an installer exit per provider over one hour, sustained for ten minutes. |
| `FountainTurnFailureRate` | More than 25% of at least ten terminal turns fail per provider over 30 minutes. |
| `FountainReattachFailures` | A conversation reattach fails within the last hour. |
| `FountainTurnFirstOutputSlow` | Observed first-output p95 exceeds 30 seconds for 15 minutes, with at least ten samples per window. |
| `FountainProvisionDeadlineExceeded` | A provision attempt reaches its watchdog deadline. |
| `FountainSandboxBudgetExceeded` | Sandbox concurrency exceeds the configured budget. |
| `FountainConversationsAboveBudget` | Live conversations exceed the configured budget. |
| `FountainUntrackedSprites` | Sprites exist without a sandbox row. |
| `FountainReaperSilent` | The sandbox reaper has not completed a run. |
| `FountainObanJobsRaising` | Background jobs raise exceptions. |
| `FountainObanJobsDiscarded` | Background jobs exhaust their retries. |
| `FountainObanQueueBacklog` | A background queue has a sustained backlog. |

The first-output rule measures only turns that produce output; a turn that
emits nothing produces no sample, so investigate that case through
conversation failure events. The rules add no automatic rollback. Assign a
receiver and tune the thresholds for your traffic before you enable them.
Run `python3 scripts/test-alerts.py` with PyYAML and `promtool` installed to
check the expressions against their failure fixtures.

### Added by the hosted overlay

The maintainer's instance adds rules that are not in the portable manifests:
`FountainSiteUnreachable`, `FountainEmailDeliveryFailures`, broker health
rules (`FountainBrokerListenerDown`, `FountainBrokerUnreachable`,
`FountainBrokerDenialSpike`, `FountainBrokerUpstreamFailures`,
`FountainBrokerSessionsUnresolvable`, `FountainBrokerLogDropping`,
`FountainBrokerCaExpiring`) and six CNPG point-in-time recovery rules
(`FountainPitrBaseBackupStale`, `FountainPitrBaseBackupNeverSucceeded`,
`FountainPitrBackupFailed`, `FountainPitrWalArchivingFailing`,
`FountainPitrMetricsAbsent`, `FountainPitrWalMetricsAbsent`).

**If you run CNPG,** the four portable backup rules watch only the dump
CronJob, not base backups or WAL archives. Write the six `FountainPitr*`
equivalents for your cluster: enable its scrape, check the metrics appear, and
adapt the namespace, cluster name and staleness threshold (the hosted ones
assume daily base backups). Keep both missing-metrics rules, or an exporter
that stops makes a failed backup look quiet. A quiet alert does not prove a
backup restores; run the
[restore drill](back-up-and-restore.md#run-the-restore-drill).

## Dashboards

`deploy/grafana/` holds three complete Grafana dashboards in JSON. Every panel
carries a description; hover over the `i` in its header.

| File | Read it for |
|---|---|
| `fountain-ops.json` | A reported problem. Golden signals across the top (error share, exceptions, request p95, scraped pods, untracked sprites, live conversations), then HTTP and database (pool wait is the saturation signal), conversations and sandboxes (stage transitions, provisioning, turn duration, time to first output), background work and the VM, and traces. |
| `fountain-product.json` | Volume and speed: turn outcomes per hour, the failure share, time to first output (the latency a person feels) beside turn duration. |
| `fountain-dashboard.json` | A starter for an empty Grafana. |

On Kubernetes, add `deploy/grafana` to your overlay. It generates one
ConfigMap per dashboard labelled `grafana_dashboard: "1"`, which the
kube-prometheus-stack sidecar picks up. Anywhere else, import each file in
Grafana (**Dashboards**, then **Import**) and choose your Prometheus
datasource. The ops dashboard also asks for Tempo; without it only the two
trace panels stay blank. A `fountain.turn` span carries the runtime and the
model, and its **Logs** button opens that pod's lines for the same window.

To change a dashboard, edit the JSON and open a pull request; the sidecar
overwrites edits made in the Grafana UI on the next deploy.

Prometheus discards identity, so no query names an account. For one account,
read `/admin/users` and `/admin/sandboxes`, which read Postgres.

### Three traps in the queries

**A gauge is the database's number.** The conversation, sandbox and Oban
gauges are polled from the database. After a restart the old process's series
lingers until Prometheus marks it stale, so the same value appears twice. Use
`max` on gauges, never `sum`; counters are per-process events and want `sum`.
A total across providers collapses the duplicates first:

```promql
sum(max by (provider) (fountain_sandboxes_by_provider_count{status=~"pending|starting|ready"}))
```

**Sandbox-minutes from Prometheus are an estimate**, accurate to the scrape
interval; a sandbox that lived between two scrapes never appears. The
authority for cost is the provider bill. Read [Sandbox lifetime and cost](sandbox-lifetime.md#what-sandboxes-cost).

**A series that does not exist is not a zero.** A counter appears only after
its first event, so a panel on a rare failure ends with `or vector(0)` to read
0 on a healthy instance.

## The broker admin page

`/admin/broker` shows the egress broker's listener state, live sessions,
request counts by outcome for a window, the busiest hosts, the bindings it
attached a credential for, and the requests it refused or that failed. Health
refreshes every 30 seconds; traffic refreshes when you pick a window or click
Refresh data.

- **Denied** is every request the broker answered itself, mostly policy, such
  as a `403` for a host outside a limited environment's allowed list. A
  `502 credential_missing` is different: the broker holds no usable credential
  for a rule. A run of them points at one tenant secret it cannot read.
- **Failed** is forwards that broke, excluding refusals.
- **Sandboxes cutting streams** lists sandboxes with at least 10 streamed
  requests (one second or longer) in the window, at least half ending
  `client_closed`. Healthy machines stay under 1%. Such a machine drops quiet
  connections, which Managoat cannot repair; see
  [A Sprites machine that drops quiet connections](../../concepts/sandboxes.md#a-sprites-machine-that-drops-quiet-connections).
  Ask the owner to start a new conversation, or reap the sandbox from
  `/admin/sandboxes`. At most 20 are listed.
- The live-session table shows at most 50 rows, and says when there are more.
  A conversation holds one session per provision and one per reattach.

Unresolved-token failures and dropped log rows are not in these tables; they
show in Prometheus as `FountainBrokerSessionsUnresolvable` and
`FountainBrokerLogDropping`.

## Logs and errors

Logs go to stdout (`docker compose logs -f app`).

Managoat reports no error unless you set `SENTRY_DSN`. Sentry, or any service
that speaks its API such as GlitchTip, then receives each crash with a stack
trace, including crashes outside a web request. The
[Sentry integration guide](../../integrations/sentry.md) covers the setup, and
the Crons check-in that alerts you when the backup job stops.

## Health endpoints

| | |
|---|---|
| `GET /health` | Always 200 while the app runs. It checks nothing. Point a **restart** check here: if it read the database, one Postgres blip would restart the container, which does not fix Postgres. |
| `GET /health/ready` | 200 when this instance can serve. 503 when it cannot reach its database, or when its egress broker listener is down (checked only when `BROKER_LISTEN_PORT` is set). Point your **load balancer** and deploy gates here. |

```bash
curl -sS localhost:4000/health/ready
# {"status":"ok","checks":{"broker_listener":"ok","database":"ok"}}
```

Both are public and report only `ok` or `error` per check. A healthy check
takes about 2 ms, but a database it cannot reach takes a few seconds to give
up, so give the check a timeout above one second.
[Pods restart or never go ready](../../troubleshooting/pods-restarting.md)
explains the probe layout as symptoms.
