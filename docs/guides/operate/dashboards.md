# Read the dashboards

Three teams ask different questions of the same instance. This page says which
dashboard answers which question, and what each number means.

Fountain reports itself through two systems. Neither one replaces the other.

| System | Holds | Answers |
|---|---|---|
| Grafana, over Prometheus and Tempo. | Counts, durations and traces. No identity. | How many. How fast. Which step. |
| PostHog. | Events with an account attached. | Who. Whether they returned. Which account costs money. |

A Prometheus counter discards identity by design, so no query there can name an
account. PostHog holds no histogram of turn duration, so no query there can
report a p95. Each system answers what the other cannot.

## The five dashboards

| Dashboard | System | Audience |
|---|---|---|
| Fountain / Ops. | Grafana. | Ops. |
| Fountain / Product. | Grafana. | Product. |
| Fountain / Finance. | Grafana. | Finance. |
| Fountain / Product. | PostHog. | Product. |
| Fountain / Finance. | PostHog. | Finance. |

The two names appear twice on purpose. A product question about volume belongs
in Grafana, and the same question about people belongs in PostHog. Each
dashboard carries a panel that names its counterpart.

## Grafana

The dashboard sources live in `deploy/grafana/`. Each file is a complete
Grafana dashboard in JSON.

| File | Dashboard |
|---|---|
| `fountain-ops.json`. | Fountain / Ops. |
| `fountain-product.json`. | Fountain / Product. |
| `fountain-finance.json`. | Fountain / Finance. |
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

- **Lifecycle funnel**. Registered, verified, onboarded, activated, funded,
  and the conversion between each pair. The counts are all time, so read the
  slope rather than the level. Activated means the first conversation with a
  reply. A conversation that never answered is not an activation.
- **What agents actually do**. Turn outcomes per hour, the failure share, and
  the two latency panels.
- **Time to first output** is the latency a person feels. Turn duration is how
  long the whole run took. Read the two together.

### Fountain / Finance

Read this one for cost drivers.

- **Live sandboxes by provider**. A minute on each provider costs a different
  amount, which is why the gauge carries a provider label.
- **Parked sandboxes by provider**. The idle bound suspends a sandbox and keeps
  the sprite, so a parked sandbox can still cost storage.
- **Untracked sprites**. Sprites alive at the provider with no sandbox row.
  This is money that leaves with nothing to attribute it to.
- **Usage events dropped**. Any value above zero means the instance lost
  billable rows.
- **Sandbox-minutes accrued per hour**. An estimate. See the traps below.
- **Funded accounts**. Counts, never revenue. The ledger holds the money.

The credit machinery has a row of its own. It answers two questions apart from
each other, because a worker can run on schedule and still move no money.

- **Time since each credit worker last finished**. The pricer runs every ten
  minutes. The expirer runs once a day. A worker with no bar has not run since the last rollout. Read the empty space as silence,
  never as zero.
- **Money through the ledger per hour, by reason**. The number comes from the
  ledger write itself, so it cannot drift from the ledger. The reasons are a
  closed set, so no cent moves without a line here.
- **Debits in the last day, by reason**. The same series, restricted to the
  rows that take money out.
- **Turns completed, last day**, beside **Burned on turns, last day**. Read the
  two together. Turns with no money against them mean a broken pricer. Both at
  zero mean an idle day.
- **Stripe webhooks failed, last hour**. Purchases, refunds and disputes all
  arrive on one endpoint. A rejected signature answers 400, so the global 5xx
  rate never carried these.
- **Emails that failed to send, last hour**. This path carries the credits-low
  and credits-exhausted notices. A failure here is an account that never
  learns its balance ran out.

The alerts over these same metrics live in the hosted overlay, not in the
shipped chart. `FountainCreditPricerPricedNothing` is the reason. Turns bill on
platform-paid providers only, so an instance on self-hosted runners completes
turns and correctly burns nothing.

## PostHog

Both dashboards live in the project the instance reports into.

- [Fountain / Product](https://us.posthog.com/project/570897/dashboard/2020978)
- [Fountain / Finance](https://us.posthog.com/project/570897/dashboard/2020979)

Every tile carries a description that states what it measures and why.

### Fountain / Product

| Tile | Question |
|---|---|
| `Turn outcomes`. | How many turns finished, and how did they end. |
| `Accounts running turns`. | How many accounts ran an agent today and this week. |
| `Activation funnel`. | Where does an account stop between an agent and a turn. |
| `Do accounts come back`. | Weekly retention on finished turns. |
| `What ends an attempt before any output`. | Setup and model failures, per account. |
| `What people build`. | Agents, conversations and scheduled runs. |
| `How much each active account runs`. | Depth against breadth. |
| `Verified to first reply`. | Where does a new account stop before its first reply. |
| `Time to first reply`. | How long an account waits from verification to the first reply. |

### The activation funnel

Activation is the first conversation with a reply. ADR 0038 sets that rule, and
`Fountain.Activation` holds the one definition. The admin page and PostHog both
read it.

The funnel has four steps.

| Step | Event | Source |
|---|---|---|
| Verified. | `auth.email.verified`. | `Fountain.Audit.record/1`. |
| First page seen. | `onboarding.landing_viewed`. | The page after verification. |
| Request sent. | `onboarding.request_sent`. | The page after verification. |
| First reply. | `activation.first_reply`. | `Fountain.Activation.turn_replied/1`. |

The two middle events come from the page after verification. Both of those
steps are optional in the funnel. The conversion from the first step to the
last step is therefore correct before that page exists.

`activation.first_reply` carries an `hours_since_verified` property. A trend on
that property reports the median and the p90 for any window. The admin funnel
page at `/admin` reports the same two numbers from Postgres. It also reports the
share of accounts that reach a reply inside a day.

### Fountain / Finance

| Tile | Question |
|---|---|
| `Billable metering events`. | The nine event types that meter what the credit pricer burns. |
| `Accounts driving the sandbox bill`. | Top twenty accounts by provisions and turns. |
| `Cost concentration`. | More accounts, or heavier accounts. |
| `Is metering still recording`. | Two independent event streams, compared. |

### Where the events arrive from

`Fountain.Analytics` sends nothing from a call site. Every event leaves a choke
point that the action already had to pass through.

| Choke point | Events |
|---|---|
| `Fountain.Audit.record/1`. | Each audited mutation, under its own action name. |
| `Fountain.Billing.record_usage/5`. | The nine `usage.` events. |
| `Conversations.publish_stage/4`. | `conversation.turn.done` and the other outcome stages. |
| `Fountain.Activation.turn_replied/1`. | `activation.first_reply`, once per account. |
| `FountainWeb.Live.Hooks`. | `$pageview` for the console. |

A new audited action is therefore a new product event, and the two can never
drift apart in coverage.

Two names never reach PostHog. The `:api` pipeline writes a second audit row
per mutation, named after the request line, and that name embeds resource ids.
An API key that the system issued itself is also refused. Both rules live in
`Fountain.Analytics.product_event?/2`, and neither one changes what the audit
trail keeps.

## Two traps

### Every replica exports the same gauge

Fountain polls the funnel, conversation, sandbox and Oban gauges from the
database. Every replica polls the same database and reports the same number.
Two replicas therefore export the same value twice.

Use `max` on those, and never `sum`. A `sum` reports two replicas as twice the
work. Counters are different. Each replica counts its own events, so a counter
wants `sum`.

The finance dashboard needs both in one expression. It collapses the per-replica
duplicate first, then adds the providers together.

```promql
sum(max by (provider) (fountain_sandboxes_by_provider_count{status=~"pending|starting|ready"}))
```

The credit worker stamp needs `max` for a different reason. Only the pod that
ran the Oban job holds `fountain_credits_worker_run_last_run_unix`, so an `avg`
reads whichever replica answered and goes stale when the leader moves.

The other order multiplies the total by the replica count.

### Sandbox-minutes are an estimate

Grafana samples the live-sandbox gauge every minute, takes the mean over an
hour, and multiplies by 60. The result is accurate to the scrape interval. A
sandbox that lived and died between two scrapes never appears.

Reconcile the number against the provider bill before anyone quotes it. The
authority for cost, in order, is Stripe, then `usage_events` in Postgres, then
the PostHog finance dashboard, then this panel.

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

For PostHog, edit the tile in the product. Then record the change in the table
above, so the repo stays the description of record.

## Related

- [Configure observability](observability.md), for the scrape, the alerts and the
  health endpoints.
- [See what sandboxes cost](sandbox-spend.md), for the per-account view.
- [Operations overview](../../operations.md).
