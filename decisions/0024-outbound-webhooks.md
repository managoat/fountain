---
type: ADR
title: "Outbound webhooks: signed lifecycle callbacks, no values, pinned egress"
description: "Retired 2026-10-12: outbound webhooks were removed (simplify 4/5). Tenant-scoped webhook endpoints delivered by Oban off publish_stage/4, Stripe-shaped HMAC signing, a payload that carries ids and a stage and never conversation content, and an SSRF guard that resolves and pins the address at request time. Built in this PR; per-resource routing and asymmetric signatures are deliberately not built."
tags: [api, security, integrations]
status: deprecated
adr: "0024"
adr_status: "Retired"
date: 2026-08-22
generated: { by: human:jhgaylor, at: 2026-08-22T09:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-22T09:00:00-04:00 }
---

# 0024 — Outbound webhooks: signed lifecycle callbacks, no values, pinned egress

**Status:** Retired 2026-10-12; see the addendum at the end. The text above the addendum is history. Was: Accepted — built in this PR: `Fountain.Webhooks` (the
`webhook_endpoints` and `webhook_deliveries` tables), `Fountain.Webhooks.Url`
(the SSRF guard), `Fountain.Webhooks.Signature`, the `:webhooks` Oban queue
with `Fountain.Workers.WebhookDelivery`, `/api/webhooks`, `/account/webhooks`
and `fountain webhooks`. What is deliberately *not* built is under
[Consequences](#consequences).

## Context

The only way to learn that something happened to a conversation was to hold an
HTTP connection open. `GET /api/conversations/:id/events` subscribes the caller
to the conversation's PubSub topic, replays from `Last-Event-ID`, heartbeats
every 15s and gives up after 60s of quiet. It is a good stream and a bad
integration point:

- **It needs a live process.** A GitHub Action, a Lambda, a Slack app, a
  cron-driven script — none can hold a socket for the twenty minutes a turn
  might take. "Stay connected and reconnect" is a daemon every integrator has
  to write and operate.
- **It is per-conversation.** There is no way to ask "tell me whenever
  anything of mine finishes", which is the question a dashboard, a notifier or
  a fan-out orchestrator asks.
- **Missed events expire.** Replay is bounded by what is still in
  `log_events`, which `RetentionPruner` deletes on schedule.
- **It pushes callers toward polling**, which is worse for both sides.

Fountain spawns agents that run for minutes to hours and then go quiet. That
is the shape that wants a callback.

Three choices in this design constrain everything built on top, which is why
they are here rather than only in the module docs: what crosses the wire, how
it is signed, and what the URL is allowed to point at.

## Decision

### 1. Dispatch hangs off `publish_stage/4`, and stage events only

`Fountain.Conversations.publish_stage/4` is already the single chokepoint every
operationally meaningful outcome flows through; the Prometheus stage counter is
built on that guarantee. Webhook dispatch hangs off the same call and inherits
the same property: **a new lifecycle outcome cannot be added without webhook
subscribers seeing it.**

`Fountain.Webhooks.Events` writes the catalogue down, and
`webhook_events_test.exs` reads the `publish_stage/4` call sites out of the
source and fails if one produces a type the catalogue does not name. That test
is what keeps the guarantee true rather than merely asserted.

`kind: "output"` rows do **not** get webhooks. A chatty turn produces thousands
of stdout chunks; turning those into HTTP POSTs is a self-inflicted denial of
service on both ends. Streaming output stays on SSE.

Dispatch is best-effort **by rescuing**, and it runs on the conversation's own
hot path. A webhook that is not sent is a degraded integration; a stage
transition that raises is a stuck agent.

### 2. The payload carries no values

Ids, a stage, a status, a duration. No transcript text, no prompt, no
environment variable names, no secret values.

This is the rule [0013](0013-audit-trail.md) established for the audit trail,
applied for the same reason and one more. A webhook payload is tenant data
leaving the building over a URL the tenant typed into a form; and
`webhook_deliveries` retains the payload for redelivery, so a payload carrying
content would make that table a second, less-guarded copy of every
conversation. A receiver that wants the transcript calls
`GET /api/conversations/:id/events` with its own API key.

`id` is the `log_events` row id — stable, monotonic, and already the SSE event
id — so a consumer running both can dedupe across them.

**At-least-once, no ordering.** Retries and parallel delivery both mean the
same event can arrive twice and out of order. This is documented on the
reference page rather than being an implementation detail readers discover.

### 3. HMAC, Stripe-shaped

```
Fountain-Signature: t=1755203400,v1=<hex hmac_sha256(secret, "1755203400.<raw body>")>
```

Stripe-shaped because every integrator has already written this verifier once.
The timestamp is inside the signed string so a receiver can enforce a replay
window; `v1` is looked up by name so a `v2` can be added alongside it.

The secret is **encrypted, not hashed**, unlike `api_keys.key_hash`: the
delivery worker has to read it back to sign with it. That is what
`Fountain.Crypto` envelope encryption is for, and it is the same path
environment and vault secrets take. Shown once at creation and once at each
rotation, never rendered again.

### 4. The URL is resolved and pinned at request time

The URL is tenant-controlled and the request comes from inside the cluster.
Three defences, because each alone is defeated by an obvious trick:

1. **Shape**, when the endpoint is saved. `https://` only, unless
   `WEBHOOK_ALLOW_HTTP`; a real host; no credentials in the URL.
2. **Address**, before **every** request. Every A and AAAA answer must be
   publicly routable. Loopback, link-local (where every cloud metadata service
   lives), RFC1918, CGNAT, and the documentation and reserved blocks are
   refused, as are the IPv6 transition encodings that would otherwise smuggle
   an IPv4 address past an IPv6 check. Create-time validation alone is
   decorative against DNS rebinding.
3. **Pinning**, during the request. Fountain connects to the address it just
   checked, carrying the hostname in the `Host` header and in TLS SNI. Without
   this there is still a window between our resolution and Finch's, which is
   the whole of a rebinding attack.

**Redirects are never followed.** A `302` to `169.254.169.254` walks past all
three, so a `3xx` is a delivery failure. Response reads are capped at 4 KB.

### 5. Failure is counted in events, not attempts

`max_attempts: 8` with Oban's exponential backoff is roughly a day per event.
`consecutive_failures` counts *events* that exhausted their retries and resets
on any accepted delivery, so a flaky receiver never trips the auto-disable and
a dead URL trips it in the low tens of hours. At the threshold the endpoint is
set to `disabled` and the owner is emailed.

The increment and its read are one statement, so two events finishing at once
cannot both read the pre-increment value and neither trip the threshold.

### 6. The delivery log is the support surface

One row per HTTP attempt, with status, duration and the first few KB of the
response. That table is what turns "your webhook is broken" from a support
thread into a screenshot, and it is what a manual redelivery replays. It is
pruned on a 30-day window by `RetentionPruner`: a debugging aid, not an event
store.

### 7. `system:webhook_delivery` joins the actor vocabulary

The auto-disable path mutates tenant state from an unattended worker, so it
needs an actor. [0013](0013-audit-trail.md) owns the closed vocabulary and is
amended by this ADR to include it. Endpoint CRUD audits in the context like
everything else, recording the URL **host** and the event filter — never the
secret, and never the path or query, which a tenant can put anything in.

## Consequences

- Anything that can learn about a conversation without a live process can now
  integrate. The daemon each integrator was writing is Fountain's problem now,
  which is the point.
- **A receiver still cannot get content from a webhook.** Every integration
  that wants output makes a second, authenticated call. That is a deliberate
  cost, paid so the payload and the delivery log never become a copy of tenant
  data on an egress path.
- **Not built: per-resource routing.** Scoping an endpoint to one agent or one
  conversation is tempting and deferred. Tenant-wide plus an event-type filter
  covers every use case we have, and per-resource routing can be added later
  without a payload change.
- **Not built: asymmetric signatures.** HMAC is right for v1. A receiver that
  wants to verify without holding a shared secret would need a keypair and a
  `v2` scheme; the header format already accommodates one, and nothing here
  has to change to add it.
- **Not built: `agent.*` or `vault.*` events.** The `conversation.` prefix is
  paid for now so those can be added without renaming anything.
- Outbound HTTP from the app pods is now load-bearing for a tenant-facing
  feature. A deployment with no egress sets `WEBHOOKS_ENABLED=false`; endpoints
  stay saved and stop receiving.
- `webhook_deliveries` grows with conversation volume times endpoint count. The
  30-day window is the bound; watch it before widening the retention window.

## Alternatives considered

- **Deliver from the `ConversationServer` directly.** No queue, no delivery
  log, no retries, and a slow receiver would hold up the agent. Rejected on
  the first of those alone.
- **One shared queue with the rest of maintenance.** A tenant's dead URL would
  sit in front of retention sweeps and email. The queue is cheap; the coupling
  is not.
- **Validate the URL only at create time.** This is the common implementation
  and it is decorative. DNS is the attacker's to change afterwards.
- **Follow redirects, re-checking each hop.** Every hop is another rebinding
  window, and the feature is worth nothing: a receiver can publish the URL it
  wants to be called.
- **Put the transcript in the payload.** It is what integrators ask for. It
  would also put tenant content in `webhook_deliveries` and on an egress path
  chosen by whoever filled in the form, which is exactly the shape
  [0013](0013-audit-trail.md) exists to refuse.
- **Hash the secret like an API key.** Impossible: signing needs the plaintext.
  Envelope encryption with the tenant DEK is the existing answer for a secret
  Fountain has to read back.

## Addendum — 2026-10-12: retired

Fountain removed outbound webhooks (simplify 4/5). In the thirty days before
the decision no account had a webhook endpoint, and Fountain is now a
self-hosted application whose operators can follow a conversation over the
event stream.

- `Fountain.Webhooks` and its modules (`Url`, `Signature`, `Events`,
  `Endpoint`, `Delivery`), the `WebhookDelivery` and `WebhookEmail` workers,
  the `:webhooks` Oban queue, `/api/webhooks`, `/account/webhooks`, the
  switched-off email, `fountain webhooks` and the `Webhook` manifest kind are
  deleted. The routes answer `404`, and an apply naming the kind is refused.
- `Conversations.publish_stage/4` and the deadline transaction
  (`DeadlineEvents`, [0046](0046-durable-turn-deadlines.md)) no longer
  dispatch. The deadline transaction still commits the turn, its stage event
  and its local notification together.
- `WEBHOOKS_ENABLED` and `WEBHOOK_ALLOW_HTTP` are no longer read, and the
  retention pruner no longer prunes `webhook_deliveries`.
- Migration `20261012170000` deletes pending jobs on the `webhooks` queue and
  for both workers. It does **not** drop `webhook_endpoints` or
  `webhook_deliveries`: the previous release reads `webhook_endpoints` on every
  stage transition, including inside the deadline transaction, so dropping it
  during a rolling deploy would fail turns on the old pods. A later migration
  drops both once no running release reads them.
