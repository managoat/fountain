# Read the dashboards

Two teams ask different questions of the same instance. This page says which
dashboard answers which question, and what each number means.

Fountain reports itself through Grafana, over Prometheus and Tempo: counts,
durations and traces. A Prometheus counter discards identity by design, so no
query there names an account. For a question about one account, read the
admin pages (`/admin/users`, `/admin/sandboxes`), which read Postgres.

## The two dashboards

| Dashboard | Audience |
|---|---|
| Fountain / Ops. | Ops. |
| Fountain / Product. | Product. |


## Grafana

The dashboard sources live in `deploy/grafana/`. Each file is a complete
Grafana dashboard in JSON.

| File | Dashboard |
|---|---|
| `fountain-ops.json`. | Fountain / Ops. |
| `fountain-product.json`. | Fountain / Product. |

| `fountain-dashboard.json`. | The starter, for an empty Grafana. |

Every panel carries a description. Hover over the `i` in a panel header to read
why the query has the shape it has.

### Install them

On Kubernetes, add `deploy/grafana` to your overlay. That directory generates one ConfigMap per dashboard, each labelled
`grafana_dashboard: "1"`. The kube-prometheus-stack sidecar watches every
namespace for that label, so a deploy delivers the dashboards.

Anywhere else, import the JSON by hand.

1. Open **Dashboards**, then **Import**, in Grafana.
2. Paste one file.
3. Choose your Prometheus datasource.
4. Repeat for each file.

The ops dashboard also asks for a Tempo datasource. Leave it empty if you run
no Tempo. Only the two trace panels then stay blank.

### Fountain / Ops

Read this one when somebody reports a problem.

- **Golden signals** across the top. Error share, unhandled exceptions, request
  p95, scraped pods, untracked sprites, and live conversations.
- **HTTP** and **Database**. The pool wait panel is the saturation signal. A
  climb there with a flat query time means the pool holds no free connection.
- **Conversations and sandboxes**. Stage transitions, the provision histogram
  beside its own sub-steps, turn duration, and time to first output.
- **Background work and the VM**. Oban depth, job outcomes, and BEAM memory.
- **Traces**. The slowest turns, and the spans that ended in error. A `fountain.turn`
  span carries the runtime and the model. Open one, then use the **Logs** button
  to reach that pod's log lines for the same window.

### Fountain / Product

Read this one for volume and speed.

- **What agents actually do**. Turn outcomes per hour, the failure share, and
  the two latency panels.
- **Time to first output** is the latency a person feels. Turn duration is how
  long the whole run took. Read the two together.

## Two traps

### Every replica exports the same gauge

Fountain polls the conversation, sandbox and Oban gauges from the
database. Every replica polls the same database and reports the same number.
Two replicas therefore export the same value twice.

Use `max` on those, and never `sum`. A `sum` reports two replicas as twice the
work. Counters are different. Each replica counts its own events, so a counter
wants `sum`.

A total across providers needs both in one expression. It collapses the
per-replica duplicate first, then adds the providers together.

```promql
sum(max by (provider) (fountain_sandboxes_by_provider_count{status=~"pending|starting|ready"}))
```


The other order multiplies the total by the replica count.

### Sandbox-minutes are an estimate

A query that counts sandbox-minutes from Prometheus samples the live-sandbox
gauge every minute, takes the mean over an hour, and multiplies by 60. The result is accurate to the scrape interval. A
sandbox that lived and died between two scrapes never appears.

Reconcile the number against the provider bill before anyone quotes it. The
authority for cost, in order, is the provider bill, then `usage_events` in
Postgres, then a Prometheus estimate.

## A series that does not exist is not a zero

A Prometheus counter appears only after the first event. A metric that has never
fired has no series, and a panel that reads it says **No data** rather than 0.

The panels that watch for a rare failure therefore end with `or vector(0)`, so
that a healthy instance reads 0. A new panel on a rare counter wants the same
treatment.

## Change a dashboard

Edit the JSON in `deploy/grafana/`, then open a pull request. Do not edit the
dashboard in the Grafana UI. The sidecar overwrites the change on the next
deploy.

Check a new expression against the live Prometheus before you commit it.

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
curl -s --get localhost:9090/api/v1/query --data-urlencode 'query=<your expression>'
```

## Related

- [Configure observability](observability.md), for the scrape, the alerts and the
  health endpoints.
- [See what sandboxes cost](sandbox-spend.md), for the per-account view.
- [Operations overview](../../operations.md).
