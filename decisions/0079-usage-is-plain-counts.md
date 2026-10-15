---
type: ADR
title: "Usage is plain counts"
description: "Managoat does not meter usage; the console counts conversations, turns and tokens from their own tables, and the provider invoice is the cost authority."
tags: [usage, admin, console, observability]
status: stable
adr: "0079"
adr_status: "Accepted"
date: 2026-10-15
---

# 0079 — Usage is plain counts

**Status:** Accepted, 2026-10-15, by the maintainer. Built in the PR that
adds this ADR; the `usage_events` table is dropped one release later by
migration `20261016120000_drop_usage_events`. Amends [0005](0005-platform-shared-sprites-token.md),
[0009](0009-account-deletion-and-export.md),
[0017](0017-suspend-idle-sandboxes.md) and
[0018](0018-sandbox-provider-abstraction.md), as described under
Consequences.

## Context

Managoat metered usage so that a hosted service could bill for it. Since
2026-10-12 it is self-hosted only: there is no billing, no credits and no
plans ([0031](0031-credits-are-the-product.md) and
[0030](0030-prepaid-credits.md) are retired), and nothing is priced, granted
or gated on usage. What was left of the meter:

- **An event log.** `Fountain.Usage.record_usage/5` wrote a `usage_events`
  row on every sandbox transition (`sandbox_provisioned`,
  `sandbox_provision_failed`, `sandbox_suspended`, `sandbox_resumed`,
  `sandbox_terminated`) and on every turn (`turn_started`). The machine
  owner called it through `Conversations.sandbox_status_effects/2` after
  every finalize, and the turn writers called it after every insert. Its
  failures were swallowed and counted on `[:fountain, :usage, :dropped]`,
  with a Grafana panel to watch.
- **An attribution engine.** `Fountain.Machines.Usage` folded sandbox rows
  and the park/wake pairs into active, idle, busy and turn seconds per
  account and per provider, clipped to a period, and split the providers
  into those the operator pays for and those it does not.
- **The surfaces on top.** The console's "This month" tiles (conversations
  and turns from `turn_started` events, turn hours, sandbox minutes in a
  hint), the "Billable sandbox time" tile on `/admin`, the "Spend by
  provider", "Billable to us" and "Who it belongs to" panels on
  `/admin/sandboxes`, and the "Usage 30d" column on `/admin/users`.

For one operator and his own apps, the provider's invoice already answers
what sandboxes cost, and the tables already answer what the agents did.
The meter added a write to every status change and every turn, a second
record that could disagree with the first, and a body of reconciliation
code (parked intervals, a dropped-event counter, period clipping) that
existed so a bill could be defended.

## Decision

1. **No usage event log.** `Fountain.Usage`, `Fountain.Usage.Event` and
   every `record_usage` call are removed: the five sandbox-transition writes
   in `Fountain.Conversations` and the `turn_started` write after a turn is
   inserted. `Conversations.sandbox_status_effects/2`, whose only effect
   was the metering, goes with them, and the machine owner (`Provision`,
   `Park`, `Resume`, `Destroy`) no longer calls it.
2. **No sandbox-time attribution.** `Fountain.Machines.Usage` is removed:
   per-account and per-provider active, idle and turn time, `provider_spend`
   and the "billable to us" figures. Managoat does not total sandbox time.
3. **No dropped-usage metric.** `[:fountain, :usage, :dropped]`, its
   `fountain.usage.dropped.count` definition in `FountainWeb.Telemetry`,
   its log handler and its Grafana panel are removed. No alert rule
   referenced it.
4. **Usage is counted from the tables.**
   `Conversations.activity_counts/3` counts the turns an account started in
   a half-open period and the conversations they belong to;
   `Conversations.token_usage/3` (unchanged) sums their token figures.
5. **The console keeps "This month".** Conversations, turns and tokens, for
   the running UTC calendar month. The turn-hours tile and its
   sandbox-minutes hint are removed.
6. **The admin pages lose their spend panels.** `/admin` keeps the active
   sandbox count; the "Billable sandbox time" tile is removed.
   `/admin/sandboxes` keeps the live list and the reap lever; "Spend by
   provider", "Billable to us" and "Who it belongs to" are removed.
   `/admin/users` replaces "Usage 30d" with "Activity 30d": conversations
   and turns over the last 30 days, counted in one query for the accounts on
   the page. Its "Last active" sort reads the latest turn instead of the
   latest usage event.
7. **The retention pruner stops pruning `usage_events`.** The table gets no
   new rows.
8. **The table goes one release later.** `usage_events` stays for one
   release, so the previous release can still write it during a deploy, and
   is then dropped by its own migration.

## Consequences

- **Counts follow the data.** A deleted conversation takes its turns with
  it, so it drops out of every count. The event log survived a deleted
  conversation; nothing needs that now.
- **Cost is the provider's figure.** Sandbox time per provider and per
  account is no longer on any page. The live gauge
  `fountain_sandboxes_by_provider_count` and the Grafana estimate built on it
  stay; the invoice is the authority
  (`docs/guides/operate/sandbox-lifetime.md`).
- **The API and SDK are unchanged.** Neither exposed the event log or the
  attribution. Token usage on turns and conversations (`usage`,
  `usage_total`) is the runtime's report and stays.
- **The provision failure path is simpler.** The starting row was carried
  to the failure write only so `sandbox_provision_failed` could record the
  status before the failure. That field is gone, and so is the carry.
- **0005 amended.** Its context assumed Managoat recovered the provider
  bill from its own tiers, which needed the meter. There is no meter; the
  shared credential stands.
- **0009 amended.** `usage_events` was one of the tables that nilified on
  account deletion. It takes no new rows and is dropped one release later.
- **0017 amended.** Its "Usage metering blurs at the edges" cost is moot:
  there is no meter to blur.
- **0018 amended.** "Usage-event metadata gains a `provider` key" describes
  a log that is gone. The provider is still on the sandbox row.
- **Leftovers.** Retired ADRs that describe the meter (0006, 0010, 0025,
  0026, 0030, 0031) are history and are not edited. Migrations that create
  or alter `usage_events` are history too.

## Alternatives considered

- **Keep the event log, drop the pages.** That keeps a write on every status
  change and every turn for a table nothing reads. Rejected.
- **Keep the sandbox-time attribution on `/admin/sandboxes`.** It answered
  "whose sandboxes is the bill for" when strangers shared a deployment. The
  accounts on an instance are now the operator's own, and the invoice
  answers the cost. Rejected.
- **Drop `/admin/users`' usage column without a replacement.** One grouped
  count over the page's accounts is cheap and keeps the page useful for
  spotting an account that is busy or idle. Rejected.
- **Drop `usage_events` in the same release.** The previous release writes
  it during a deploy. One release later costs nothing and matches how the
  other removals landed. Rejected.

## History

- 2026-10-15 — Decided and built: the usage event log, sandbox-time attribution and spend panels removed; usage counted from conversations and turns.
- 2026-10-15 — `usage_events` dropped by its own migration, a release after the change that stopped writing it (#2741).
