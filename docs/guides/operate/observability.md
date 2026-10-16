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
| `ManagoatBackupStale` | The optional dump CronJob has not succeeded in 36 hours. |
| `ManagoatBackupNeverSucceeded` | The dump CronJob has no successful run. |
| `ManagoatBackupJobFailing` | A dump Job failed. |
| `ManagoatBackupSuspended` | The dump CronJob has `suspend: true`. |
| `ManagoatMetricsTargetDown` | Prometheus cannot scrape Managoat. |
| `ManagoatHighServerErrorRate` | More than 5% of HTTP responses are server errors. |
| `ManagoatUnhandledExceptions` | Request handlers raise exceptions. |
| `ManagoatDatabasePoolSaturated` | Requests wait for database connections. |
| `ManagoatProvisionFailures` | Sandbox provision attempts fail. |
| `ManagoatStageFailures` | A stage after provisioning fails more than twice in 30 minutes. |
| `ManagoatBrokerCAInstallFailureRate` | More than 10% of at least five conversation CA setups fail with an installer exit per provider over one hour, sustained for ten minutes. |
| `ManagoatTurnFailureRate` | More than 25% of at least ten terminal turns fail per provider over 30 minutes. |
| `ManagoatReattachFailures` | A conversation reattach fails within the last hour. |
| `ManagoatTurnFirstOutputSlow` | Observed first-output p95 exceeds 30 seconds for 15 minutes, with at least ten samples per window. |
| `ManagoatProvisionDeadlineExceeded` | A provision attempt reaches its watchdog deadline. |
| `ManagoatSandboxBudgetExceeded` | Sandbox concurrency exceeds the configured budget. |
| `ManagoatConversationsAboveBudget` | Live conversations exceed the configured budget. |
| `ManagoatUntrackedSprites` | Sprites exist without a sandbox row. |
| `ManagoatReaperSilent` | The sandbox reaper has not completed a run. |
| `ManagoatObanJobsRaising` | Background jobs raise exceptions. |
| `ManagoatObanJobsDiscarded` | Background jobs exhaust their retries. |
| `ManagoatObanQueueBacklog` | A background queue has a sustained backlog. |

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

`deploy/grafana/` holds five complete Grafana dashboards in JSON. Every panel
carries a description; hover over the `i` in its header.

| File | Read it for |
|---|---|
| `fountain-ops.json` | A reported problem. Golden signals across the top (error share, exceptions, request p95, scraped pods, untracked sprites, live conversations), then HTTP and database (pool wait is the saturation signal), conversations and sandboxes (stage transitions, provisioning, turn duration, time to first visible update), background work and the VM, and traces. |
| `fountain-product.json` | Volume and speed: turn outcomes per hour, the failure share, time to first visible update (text, thinking, tool call or plan) beside turn duration. |
| `fountain-latency.json` | Response latency and successful turn duration by provider/runtime, with sample counts, failures, provisioning and reattachment by provider/runtime, step timings, and trace searches. |
| `fountain-latency-breakdown.json` | Continuous phase means, total p50/p90, sample counts, outcomes and individual trace waterfalls. |
| `fountain-dashboard.json` | A starter for an empty Grafana. |

On Kubernetes, add `deploy/grafana` to your overlay. It generates one
ConfigMap per dashboard labelled `grafana_dashboard: "1"`, which the
kube-prometheus-stack sidecar picks up. Anywhere else, import each file in
Grafana (**Dashboards**, then **Import**) and choose your Prometheus
datasource. The ops dashboard also asks for Tempo; without it only the two
trace panels stay blank. A `fountain.turn` span carries the runtime and the
model, and its **Logs** button opens that pod's lines for the same window.

The latency dashboard uses live application metrics, not synthetic echo tests.
Provider/runtime filters cover preparation and turn timings; the Turn filter
selects the first conversation turn or follow-ups. Stage failures remain global.
First visible update may be reasoning, a tool or a plan. **First text** waits
for a nonempty assistant text chunk. Turn timing starts before runtime spawn
or session reuse; **request to first text** starts at application launch or
send-prompt entry and includes admission, queueing, preparation and wake.
It excludes client transport and rendering. Cold means a launch with a prompt;
warm means an existing server (possibly still preparing); wake means no server
was present. A promptless launch emits no cold-response sample. A later prompt
gets a fresh request clock, excluding user idle time.

Reattachment measures only part of wake. Parallel preparation steps overlap:
do not add durations or percentiles. Check sample counts and failures beside
latency, especially at low traffic. Text and request timings are emitted once
per turn and preserved across session retries; replay after a process restart
has no sample. New series and labels are available only after deploying the
instrumentation. Metrics pool models and reasoning settings; turn traces carry
requested/effective models, provider, turn class and first-text durations.
Conversation and turn IDs stay in traces/logs, never metric labels.

The breakdown dashboard's continuous charts use
`fountain_response_phase_elapsed_ms` histograms, with bounded provider,
runtime, path and phase labels. Every matched request reaching first text
contributes all five phases, including zero for unused phases. Stacked rolling
means therefore add to the mean total; total p50/p90 are separate histogram
estimates in adjacent panels. Provider colors match between the panels; Codex
uses dashed lines. Both axes start at zero with a 30-second baseline and expand
for larger values. Provider rows and runtime panels repeat from the selectors. **Trend
path** chooses cold, warm or wake and **Rolling window** controls smoothing.
The sample-count chart shows when a percentile rests on little data. Gaps are
no observations, not zero latency.

The five exclusive wall-clock phases are:

| Phase | Boundary / meaning |
|---|---|
| Admission / queue / bookkeeping | Time before turn start not covered by sandbox or bootstrap intervals; includes admission, mailbox waits and orchestration. |
| Sandbox provision / resume | Fresh machine bracket excluding its bootstrap callback, or wake probe/resume calls; includes provider admission and finalization. |
| Bootstrap / reattach preparation | Server preparation, including parallel config/install work once by elapsed time. Sprites can implicitly wake during the first command here. |
| Runtime / session setup | Turn start through the first successful ACP prompt write, including spawn, handshake, session selection and pre-prompt retries. |
| Prompt → first text | Prompt write through the first nonempty assistant text received by Managoat; includes transport and agent work, not just model compute. |

Completed setup intervals travel with the request across wake handoffs and the
server mailbox. Intervals are clipped to the request lifetime; a warm request
cannot inherit old setup time. Nested bootstrap work replaces its enclosing
machine interval rather than adding to it. Turns without a request clock or
prompt-write timestamp (for example, restored in-flight turns) do not fabricate
phase samples. Existing total first-text metrics remain independent.

`fountain_response_completed_count` records terminal timed-turn outcomes by
provider/runtime/path, status and whether text arrived. It includes failures
without text, but not requests refused or lost before a turn starts. The
adjacent setup-stage failure chart covers provisioning errors separately;
these existing events lack provider/runtime/path labels and are not distinct
request counts. Those filters do not apply to that chart.

The sampled comparison and individual-request table below retain Tempo trace
search, capped at 500 matches per query. **Path** and **Trace model regex** filter
only those sampled panels; models are deliberately not metric labels. New turn
spans carry `response_phase_*_ms` attributes and a `fountain.response` span in
the same trace contains the exclusive phase waterfall with original timestamps.
Older traces retain the two-phase comparison and have empty detailed phase
columns. These sampled panels exclude failed/no-text requests. Continuous
metrics have no trace-search cap and do not require Tempo's metrics generator.

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
| `GET /health/ready` | 200 when this instance can serve. 503 when it cannot reach its database, or when its egress broker listener is down. Point your **load balancer** and deploy gates here. |

```bash
curl -sS localhost:4000/health/ready
# {"status":"ok","checks":{"broker_listener":"ok","database":"ok"}}
```

Both are public and report only `ok` or `error` per check. A healthy check
takes about 2 ms, but a database it cannot reach takes a few seconds to give
up, so give the check a timeout above one second.
[Pods restart or never go ready](../../troubleshooting/pods-restarting.md)
explains the probe layout as symptoms.
