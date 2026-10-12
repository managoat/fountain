---
type: ADR
title: "Product analytics in PostHog, from choke points already in the code"
description: "Retired 2026-10-12: PostHog product analytics removed when Fountain became self-hosted only. Product events go to PostHog from Audit.record/1, Billing.record_usage/5 and Conversations.publish_stage/4 rather than from instrumented call sites; capture is off without a project key, best-effort, and carries no secret values, prompts or agent output."
tags: [observability, analytics, privacy]
status: deprecated
adr: "0025"
adr_status: "Retired"
date: 2026-08-22
generated: { by: human:jhgaylor, at: 2026-08-22T04:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-22T04:00:00-04:00 }
---

# 0025 — Product analytics in PostHog, from choke points already in the code

**Status:** Retired 2026-10-12; see the addendum at the end. The text above the addendum is history. Was: Accepted. Everything described here is built. `Fountain.Analytics`,
`Fountain.Analytics.Sink`, the three bridges and the config switches are in
`apps/fountain/lib/fountain/analytics*` and covered by
`analytics_test.exs`, `analytics_bridges_test.exs`, `analytics/sink_test.exs`
and `fountain_web/live/analytics_pageview_test.exs`.

**Amended by [ADR 0028](0028-web-analytics-and-api-usage.md)** (2026-08-23) in
three places, each marked below: the `:api` request-log row is now captured as
a single `api.request` event, the public browser surface loads `posthog-js`
(the console still does not), and `$ip` is no longer sent as `null`.

## Context

Fountain had three telemetry sinks and none of them answered a product
question.

* `Fountain.Audit` — who changed what. Kept forever, tenant-visible, and
  shaped by ADR 0013's rules (never record values; only record what happened).
  A compliance record.
* `Fountain.Billing.record_usage/5` — six event types, shaped by the invoice.
  What to charge for.
* OTel spans and `Fountain.Telemetry` — how the machine is behaving.

"Did the accounts that verified last week come back", "which console pages does
anyone use", "does the flagged cohort run more turns" were all unanswerable.
The one product question anybody had asked was hand-rolled in SQL as
`Fountain.Funnel`, which computes a five-stage funnel from `users` on every
call and cannot express retention, cohorts, or anything past the funnel.
`ROADMAP.md` had carried "instrument PostHog/Honeycomb and establish WAU
baseline" since launch.

PostHog was already a dependency of sorts. `Fountain.FeatureFlags` (#850) has
evaluated per-user flags against `POSTHOG_PROJECT_API_KEY` since the
`team_comms` work, so the key, the host config, the Req plumbing and the
test-stub pattern all existed. The same project key is also PostHog's capture
credential.

## Decision

Capture product events into PostHog from the server, at choke points the code
already has, and never from instrumented call sites.

**One module, one process.** `Fountain.Analytics.capture/4` builds a payload
and casts it to `Fountain.Analytics.Sink`, a `GenServer` that batches into
`POST /batch/`. The HTTP call runs in a monitored task, so the sink can keep
buffering while a request is in flight; the queue is bounded at 5,000 events
and drops its oldest half past that. A failed flush is dropped, not retried,
and every drop is counted on `[:fountain, :analytics, :dropped]`.

**Three bridges, no call sites.**

| Choke point | What it produces |
|---|---|
| `Fountain.Audit.record/1` | every audited mutation, under its own action name |
| `Fountain.Billing.record_usage/5` | `usage.<event_type>` for the six metering events |
| `Fountain.Conversations.publish_stage/4` | `conversation.turn.done` / `.failed` / `.interrupted`, plus `setup.failed` and `model.failed` |

Plus `$pageview` from `FountainWeb.Live.Hooks`, `$identify` when an
account-shaped audit action fires, and `$feature_flag_called` from
`Fountain.FeatureFlags`, which also stamps `$feature/<key>` onto every other
event from its own cache.

This is the same argument ADR 0013 makes for auditing inside the context. A
call site that has to remember to instrument is a call site that will not, and
the #540 campaign found seven contexts with no audit calls at all. Riding the
audit trail means the analytics vocabulary *is* the audit vocabulary, the
guardrail test that forces a new mutation to audit also forces it to be
captured, and the two can never drift apart in coverage.

**The trail is a superset of the product stream.** Riding the audit trail gives
coverage for free, and the first day in production showed it also carries two
things a product stream must refuse. Of 2,160 audit rows in 24 hours:

- **1,513 (70%) were `api_key.created` / `api_key.revoked`**, and not one had a
  human actor: 534 `self` (the default, which OAuth token issuance takes — a
  Fountain OAuth token *is* an API key, ADR 0021), 445
  `system:conversation_server`, 341 `system:buzz_harness`, 193
  `system:buzz_boot_sweep`. Those are sprite credentials minted and revoked per
  conversation and per harness boot. A key a person mints in the console or
  through the API arrives as `ui` or `api` and is kept.
- **425 rows across 73 distinct names were the `:api` pipeline's request-log
  row** (ADR 0013 §4), named after the request line and carrying a resource id.
  PostHog registers each distinct name as its own event definition, so that is
  73 new definitions per day. The semantic row for the same mutation is already
  captured, so refusing it loses nothing.
  **Amended by ADR 0028**: the reasoning above is about the *name*, and was
  applied to the row. The row is now captured as one `api.request` event with
  the route as a property.
  **Corrected by ADR 0028 (2026-08-23)**: this said "permanently", and that is
  not true — the retired request-line definitions left the project's taxonomy
  about a day after their events stopped. The cost of a name-per-route is paid
  while it exists, by everyone who reads the taxonomy, which is enough to
  refuse it; it is not paid forever. See ADR 0028's Correction section.

`Fountain.Analytics.product_event?/2` is that filter: a closed dotted
vocabulary, and `api_key.*` only from a human actor. It changes nothing about
what is audited — every row still lands in the trail.

**Off unless configured, and it never carries content.** No
`POSTHOG_PROJECT_API_KEY` means nothing is sent. `POSTHOG_CAPTURE=false` keeps
flag evaluation and stops capture. Events carry action names, resource types,
counts and sizes; `Fountain.Analytics.sanitize/1` refuses any *string* under a
key that names a secret, a credential, a prompt or output, while letting
`value_bytes` and `secret_count` through because those are exactly what ADR
0013 requires be recorded in place of the value. Person properties carry the
account email by default, because the destination is the operator's own
project; `POSTHOG_PERSON_PII=false` removes it.

**Deployments are a PostHog group.** Every event is associated with an
`instance` group keyed by `POSTHOG_INSTANCE` (defaulting to `PHX_HOST`), so a
hosted instance and a self-hoster reporting into one project stay separable.

## Consequences

A new audited action is a new PostHog event with no further work, which is the
point. It also means the event vocabulary grows by default rather than by
decision, and a badly named audit action becomes a badly named product event.
The audit guardrail's exclusion list is now doing double duty.

Analytics can never fail an operation. Every bridge rescues, the sink drops
rather than retries, and `capture/4` returns `:ok` unconditionally. The cost is
that silence is ambiguous, which is why the drop counter exists — the same
argument `record_usage/5`'s counter was added for in #503.

`publish_stage/4` gains one indexed `SELECT` per captured turn outcome, and
only when capture is on. Provision stages are deliberately left to the
metering bridge, which already carries the user id, so the two never
double-count the same fact.

PII leaves the building for the first time. The audit trail is ours; PostHog
is not. That is why the email is a switch, why `sanitize/1` exists even though
audit metadata is values-free by rule, and why `$ip` is only sent when a
request-scoped caller knows the end user's address.
**Amended by ADR 0028**: sending `$ip` as `null` did not mean "no location" —
PostHog fell back to the sending pod's address and geolocated that. A capture
with no client address now sets `$geoip_disable` instead.

## Alternatives considered

- **A browser snippet (`posthog-js`) in the console.** The console is an
  operator surface behind a login, its pages are LiveView, and the events that
  matter (a turn finishing, a sandbox provisioning) happen on the server where
  no browser is watching. It would also mean a third-party script in the CSP.
  **Amended by ADR 0028**: this holds for the console and is now a stated
  constraint there. It was read as covering the whole browser surface, which
  left every visitor who was not signed in uncounted; the *public* pages load
  the snippet.
- **Instrument at call sites.** Precise, and exactly the mistake ADR 0013 was
  written to stop. Coverage would depend on which door a request came through.
- **Emit from `:telemetry` handlers.** Tempting, since `Fountain.Telemetry`
  exists. But the events that carry a `user_id` are the audit and metering
  ones, and the telemetry events are machine-shaped: attaching there would
  mean re-deriving the tenant for every event.
- **An Oban job per event.** Durable, and wrong for this. Analytics that
  writes a database row per captured event costs more than the thing it
  measures, and a queue of unsent events is not worth keeping.
- **Extend `Fountain.Funnel` instead.** It answers one question well. Adding
  retention, cohorts and per-page usage to it means building PostHog.

## Addendum — 2026-10-12: retired

Fountain is no longer sold as a hosted service. It is a self-hosted
application, and the product analytics this ADR set up existed to measure a
hosted growth goal. They were removed, along with the PostHog dependency.

- `Fountain.Analytics` and `Fountain.Analytics.Sink` are deleted, and so is
  every capture: the mirror in `Fountain.Audit.record/1`, the `usage.` mirror
  in what was `Billing.record_usage/5` (now `Fountain.Usage.record_usage/5`,
  which writes `usage_events` and nothing else), the stage mirror in
  `Conversations.publish_stage/4`, the console `$pageview` hook and the
  `$feature_flag_called` and `$identify` events.
- `POSTHOG_PROJECT_API_KEY`, `POSTHOG_HOST`, `POSTHOG_CAPTURE`,
  `POSTHOG_PERSON_PII` and `POSTHOG_INSTANCE` are no longer read.
- `Fountain.FeatureFlags` no longer asks PostHog. A flag is on or off for the
  whole deployment, from `FEATURE_FLAGS_ON` and each flag's default.

The audit trail (ADR 0013) and the Prometheus metrics are unchanged, and are
what an operator reads instead.
