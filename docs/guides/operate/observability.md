# Configure observability

This guide shows you how to scrape metrics. It also shows you how to import
the dashboard and alerts that ship with the repo, and where to point your
health checks.

## Metrics

The app serves Prometheus metrics on port 9568. The compose file does not
publish that port. Map the port to scrape it, and keep it off the public
internet. The endpoint lists routes, request rates and database timings.

You do not have to start from an empty scrape. The repo ships an
observability pack, built from a real run of the hosted instance.

- **Alerts**, in `deploy/k8s/prometheusrule.yaml`. They cover error rate,
  unhandled exceptions, pool saturation, failures to provision, and staleness
  watches for the optional backup CronJob. Each one carries a comment that
  says what it means and what to do. It needs the PrometheusRule CRD, and it
  sits commented out of the kustomization until you turn it on.
- **A starter dashboard**, in `deploy/grafana/fountain-dashboard.json`. It is
  built from metrics the app exports, and from nothing else. Import it
  into Grafana, then choose your Prometheus datasource. On compose, point any
  Prometheus at the metrics port and import the same file.
- **Three team dashboards**, in `deploy/grafana/`, one each for ops, product
  and finance. They cover the same metrics in more depth, and the ops one adds
  trace panels. [Read the dashboards](dashboards.md) says what each number
  means, and which questions belong in PostHog instead.

One series gets a mention here, because it is the one that maps to money.
The gauge `fountain_sandboxes_by_provider_count` reports how many sandboxes
each provider holds right now, by status. See
[See what sandboxes cost](sandbox-spend.md) for the per-account view that goes
with it.

## Which alerts you get

The portable rules are in
[`deploy/k8s/prometheusrule.yaml`](https://github.com/managoat/fountain/blob/main/deploy/k8s/prometheusrule.yaml).
They are optional: enable the file in your Kustomization and install the
PrometheusRule CRD and the scrapes its expressions need. A rule file alone
does not collect metrics.

The hosted instance adds the rules [listed below](#added-by-the-hosted-overlay).
Those rules are specific to that deployment. They do not arrive with the
portable manifest artifact. Shared rule names can also have different
thresholds or selectors in the overlay.

### Portable baseline

| Rule | What it watches |
|---|---|
| `FountainBackupStale` | The optional dump CronJob has not succeeded in 36 hours. |
| `FountainBackupNeverSucceeded` | The dump CronJob has no successful run. |
| `FountainBackupJobFailing` | A dump Job failed. |
| `FountainBackupSuspended` | The dump CronJob has `suspend: true`. |
| `FountainMetricsTargetDown` | Prometheus cannot scrape Fountain. |
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

Turn alerts group by provider and sum event counters across replicas.
The first-output rule measures turns that produce output. A turn that emits
nothing produces no latency sample. Use conversation failure events and
deployed execution checks to investigate that case.

These rules do not add an automatic rollback. Before you enable them, assign
an alert receiver and tune the thresholds for your traffic. The hosted
overlay requires its own rollout; a merge of this file does not update it.
Run `python3 scripts/test-alerts.py` with PyYAML and `promtool` installed to
check the shipped expressions and their failure fixtures.

### Added by the hosted overlay

| Rule | What it watches |
|---|---|
| `FountainPitrBaseBackupStale` | The CNPG base backup is older than 26 hours. |
| `FountainPitrBaseBackupNeverSucceeded` | CNPG has never completed a base backup. |
| `FountainPitrBackupFailed` | The latest CNPG base backup failed. |
| `FountainPitrWalArchivingFailing` | The write-ahead log (WAL) archive queue falls behind. |
| `FountainPitrMetricsAbsent` | CNPG base-backup metrics are absent from Prometheus. |
| `FountainPitrWalMetricsAbsent` | CNPG WAL archive metrics are absent from Prometheus. |
| `FountainStageFailures` | Conversation stages fail. |
| `FountainSiteUnreachable` | An external probe cannot reach the public site. |
| `FountainCreditPricerSilent` | The turn pricer has no successful pass. |
| `FountainCreditWorkerSilent` | A credit worker stops. |
| `FountainCreditPricerPricedNothing` | Paid-provider turns complete without ledger debits. |
| `FountainStripeWebhookFailures` | Stripe webhooks fail. |
| `FountainEmailDeliveryFailures` | Transactional email fails to send. |
| `FountainBrokerListenerDown` | The broker listener refuses connections. |
| `FountainBrokerUnreachable` | A probe cannot reach the broker through its Service. |
| `FountainBrokerDenialSpike` | The broker denies most requests. |
| `FountainBrokerUpstreamFailures` | The broker cannot reach upstream origins. |
| `FountainBrokerSessionsUnresolvable` | Sandbox broker tokens do not resolve. |
| `FountainBrokerLogDropping` | The broker drops request-log rows. |
| `FountainBrokerCaExpiring` | The broker root CA expires within 14 days. |

### The broker admin page

The admin page at `/admin/broker` shows recorded request traffic and current health. Health refreshes every 30 seconds. Traffic and session details refresh when you choose a window, or when you click Refresh data.

The page lists the listener state, the live sessions, and the request counts by outcome for a window. It also lists the busiest hosts, the bindings the proxy attached a credential for, and the requests it refused or that failed.

Denied holds every request the broker answered itself. Most of them are policy. One example is a `403` for a host outside the allowed list of a limited environment. A `502 credential_missing` is a different fault. The broker holds no usable credential for a rule, so it refuses the request instead of a send without one. A run of them points at one tenant secret that the broker cannot read. Failed holds the forwards that broke, and it leaves out the refusals, so no request appears under both.

Sandboxes cutting streams lists the sandboxes whose streamed requests mostly end `client_closed`. A request counts as a stream when it ran for one second or more. A sandbox is listed when it has at least 10 streams in the window and at least half of them ended `client_closed`. On healthy machines less than 1% of streams end that way. A share this high is a machine that drops quiet connections, which Fountain cannot repair; see [A Sprites machine that drops quiet connections](../../concepts/sandboxes.md#a-sprites-machine-that-drops-quiet-connections). Ask the owner to reset a persistent sandbox with `fountain sandbox reset <id>`, or reap the sandbox from `/admin/sandboxes`. The list shows at most 20 sandboxes, most cut first.

The live-session table shows a maximum of 50 rows. A conversation holds one session per provision and one per reattach, until each session expires. The page tells you when the true total is larger.

Unresolved-token failures and dropped log rows stay visible in Grafana through `FountainBrokerSessionsUnresolvable` and `FountainBrokerLogDropping`. The page does not include those failures in its request tables.

### If you run CNPG

The four portable backup rules watch the dump CronJob. They do **not** cover
CNPG point-in-time recovery (PITR), its base backups or WAL archives.

Add the six `FountainPitr*` rules from the overlay to your own Prometheus
configuration. Enable the scrape for your CNPG cluster and check that the
metrics named in those rules appear in Prometheus. Adapt the namespace,
cluster name, scrape labels and backup cadence: the hosted selectors name
`fountain` and `fountain-pg`, and the staleness threshold assumes daily base
backups.

Keep both missing-metrics rules. Without them, an exporter that stops can make a failed backup look quiet. Validate the rules with
`promtool`, exercise an absent scrape, and run a
[restore drill](back-up-and-restore.md#run-the-restore-drill). An alert that
stays quiet does not prove a backup can restore your data.

## Logs

Logs go to stdout.

```bash
docker compose logs -f app
```

## Errors

Fountain reports no error unless you opt in. Set `SENTRY_DSN`. Sentry then
receives each crash with a stack trace, groups them, and matches them to
releases. That includes the crashes that never touch a web request.

The endpoint can be sentry.io, or any service that speaks the Sentry API. Use
GlitchTip for a stack you host yourself. Leave the variable unset and nothing
ever leaves your instance.

The [Sentry integration guide](../../integrations/sentry.md) covers the setup,
and the Crons pattern that alerts you when the backup job stops.

## Health endpoints

There are two, because a restart of a container and a removal from a load
balancer are different decisions.

| | |
|---|---|
| `GET /health` | Always 200 while the app runs. It checks nothing. Point a **restart** check here. If it read the database, one Postgres blip would restart each container at once, and that does not fix Postgres. |
| `GET /health/ready` | 200 when this instance can serve. 503 when it cannot reach its database, or when its egress broker listener is down. The broker check applies only when you set `BROKER_LISTEN_PORT`. Point your **load balancer** and your deploy gates here. |

```bash
curl -sS localhost:4000/health/ready
# {"status":"ok","checks":{"broker_listener":"ok","database":"ok"}}
```

Both are public, and neither asks for authentication. Each reports `ok` or
`error` for each check, with no more detail. A check that fails does not
describe your database to whoever asked.

A healthy check takes about 2ms. A database it cannot reach takes a few
seconds to give up. Give the check a timeout above one second when your
platform defaults lower.

## Related

- [Sentry integration guide](../../integrations/sentry.md).
- [Pods restart or never go ready](../../troubleshooting/pods-restarting.md),
  which explains the probe layout as symptoms.
- [Architecture](../../architecture.md), for which component owns which
  symptom.
