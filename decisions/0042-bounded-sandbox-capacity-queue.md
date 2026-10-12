---
type: ADR
title: "Bounded sandbox-capacity queue"
description: "A fresh start can opt into a per-tenant FIFO queue at the tenant or fleet ceiling, and a schedule opts in when its cron fires; ten requests wait at most an hour. Built with this ADR (#1033). Since 2026-10-12 there is no credit gate on replay."
tags: [sandbox, quotas, api, schedules]
status: stable
adr: "0042"
adr_status: "Accepted"
date: 2026-09-10
generated: { by: claude-code/opus-5, at: 2026-09-10T23:45:00-04:00 }
verified: { by: claude-code/opus-5, at: 2026-09-10T23:45:00-04:00 }
stale_after: 2026-12-10
---

# 0042 — Bounded sandbox-capacity queue

**Status:** Accepted, and built by the stack that ends with this file
(#1033). Nothing described here is unbuilt.

## Context

A start can reach two capacity limits. The tenant limit is funded by its
credit balance under ADR 0031. `SANDBOX_FLEET_CEILING` protects the
deployment from creating more provider sandboxes than it can run.
`Quotas.with_sandbox_reservation/3` refuses at either, immediately, with
`{:sandbox_quota_exceeded, _}` (429) or `:fleet_full` (503).

Immediate refusal is the right answer for an interactive caller, which can
retry. It loses a scheduled teammate run completely: a 09:00 firing that
meets a fan-out at 08:59 writes an error on the schedule row and its next
chance can be a day away.

An unbounded queue would replace an honest refusal with work that can wait
forever. A queue also cannot weaken either capacity limit or the credit gate.
And several replicas can be told a slot freed at the same instant, so a
drainer must never let two of them replay one request.

## Decision

1. **Queued work has its own table.** `sandbox_requests` holds work before a
   sandbox or a conversation exists. A `queued` conversation status was the
   alternative and it would leak a row with no machine into every
   conversation list, every stream and every client enum. A `start` request
   stores the original JSON-safe launch attributes; a `schedule_run` stores a
   schedule id and re-fires that schedule.

2. **Queueing is explicit for fresh API starts.** `queue: true` on
   `POST /api/conversations` turns a tenant-cap 429 or a fleet-cap 503 into
   202 with the request and its position. Existing callers keep the error
   their clients already handle. Starts carrying images do not queue, because
   the server does not hold image bytes for an hour; starts naming an
   explicit `sandbox_id` do not either, being an attach to a machine the
   caller already has. The prompt and wake paths keep their refusals.

   What a `start` stores is an allow list of the launch keys
   `start_conversation/2` reads. `ConversationCreateRequest` does not set
   `additionalProperties: false`, so a drop list would park whatever else a
   caller sent in the table until the request expired.

   **A replay carries the restrictions the door was under, not only its
   attributes.** Two fields are stored beside the launch keys for that reason.
   `source` is the provenance the API inferred from the parent-conversation
   header, so a queued fan-out replays as `agent` rather than defaulting to
   `api`. `sandbox_key_id` is the ADR 0045 rule: a `sprite`-scoped token may
   label only the conversation it was minted for, and dropping it would let a
   queued `channel_id` start relabel another of the tenant's conversations an
   hour later — a write that same token is refused at the door. Anything that
   narrows what a request may do has to survive the wait, or the queue is a way
   around it.

3. **Cron firings of a teammate schedule opt in.** A cron firing has nobody
   there to retry it. At either ceiling `run_schedule/2` creates one
   `schedule_run` request. An active request is deduplicated by schedule, so
   later firings do not stack while the first waits, and the dedup reads under
   the same per-tenant lock as the depth bound so two firings cannot both pass
   it.

   While the request is live the schedule reads `waiting for a free sandbox
   slot`, whichever caller asked — including the drainer's own replay, which
   may meet the ceiling again and must not flip the row back to the capacity
   error the queue exists to absorb.

   What the row says and whether the caller fired are separate questions. The
   cron caller queued instead of firing and the drainer is replaying a firing
   already on the trail, so neither stamps `last_run_at` and neither records
   `team.schedule.fired`; the request's own audit events are the trail for the
   wait. Every other caller fired and got an answer, so a person's "Run now"
   refused while the work waits is stamped and recorded with the refusal it
   received, even though the row goes on reporting the wait. Deciding this from
   "is anybody waiting" rather than "did this caller wait" is how a person's
   action came to leave no audit trace at all.

   When the wait ends without a run, the row says so. A request that expires at
   the bound leaves `timed out waiting for a free sandbox slot` and a cancelled
   one `the queued run was cancelled`, because those two terminal transitions
   never reach `run_schedule/2` and a cron schedule's next firing is not a fix
   for a `one_off` that has no next firing.

   Who *enqueues* is a different question, and there the caller decides rather
   than the function. `run_schedule/2` is also the page's and the API's "Run
   now", and that caller is present: it gets the 429 or 503 unchanged, exactly
   as `POST /api/conversations` answers without `queue: true`. Queueing there
   would answer a person with an error while a conversation started up to an
   hour later, and the response carries no request id to watch or cancel. The
   gate is the audit actor, which also keeps the queue's own replay from
   re-entering the queue.

4. **The queue is bounded twice.** A tenant holds at most ten active
   requests (`SANDBOX_QUEUE_MAX_DEPTH`), and a request waits at most one hour
   (`SANDBOX_QUEUE_MAX_WAIT_SECONDS`). At the depth bound the original 429 or
   503 is returned. At the wait bound the request expires. The queue delays
   the cap; it never raises it.

   The depth bound is a check followed by an insert, so it is taken under a
   per-tenant advisory lock in its own namespace, for the reason
   `Quotas.with_sandbox_reservation/3` holds one (#330): two requests reading
   "room for one more" at the same instant would both be admitted.

5. **Capacity changes drive drains.** Every sandbox status transition goes
   through `Conversations.update_sandbox/2`. A transition out of `pending`,
   `starting` or `ready` frees a tenant slot and the global fleet slot at
   once, so it pokes every tenant with live queue work rather than only this
   one. This stays true when several conversations share one sandbox (ADR
   0023): the trigger is the sandbox leaving a cap-counting status, not a
   conversation ending.

   That poke is one Oban insert, and the job it schedules does the scan that
   finds the waiting tenants: `update_sandbox/2` is the choke point every
   status change goes through, and a caller writing one row must not pay for
   a query plus an insert per waiting tenant. It is best-effort for the same
   reason metering is at that choke point — the row is already committed and
   nearly every call site matches `{:ok, _}` — so a failed poke is logged
   rather than raised. A five-minute Oban cron is the lost-poke and expiry
   backstop.

   A drain is Oban work rather than a task started from the path that freed
   the slot. It outlives the request, it must survive a replica going away
   mid-drain, and an unawaited `Task.async` linked to a web request would
   take that request down when a replay failed (#1040).

6. **A claim is a compare-and-swap fenced on the version it observed.** The
   FIFO read orders by insertion time and id. Before any conversation or
   schedule call, one row moves from `queued` to `starting` under a swap
   guarded by the exact `(status, updated_at)` that read saw; `updated_at` is
   microsecond-resolution and every write changes it, so the pair is a
   version token. Only the replica that won the swap can write that row's
   outcome, and every later write it makes — release, start, failure —
   carries the same fence.

   The fence settles the bookkeeping, not the work: a replay that outran its
   claim has already created its conversation, and after the swap fails that
   conversation is simply orphaned from the request rather than recorded over
   the row a recovering drain replayed. It stays visible in the tenant's own
   conversation list. What the fence removes is the state in which one request
   reads as one conversation while two are running.

   Recovering an abandoned claim is part of the same step, not a separate
   pass: a claim older than five minutes is claimable directly. A separate
   recovery pass that returned the row to `queued` would leave a window in
   which the original replay, still running, could write `started` and its
   own conversation id over the row a recovering drain had already replayed
   — so one request would read as one conversation while two were running.
   Five minutes is a wide margin: both replay paths return in milliseconds,
   because provisioning happens in the `ConversationServer` rather than under
   the claim.

   Oban pokes are scheduled one second ahead and deduplicate only against
   another *scheduled* poke. Every Oban state group that includes `executing`
   would let a poke reporting capacity a running drain has already read past
   vanish into the uniqueness window.

7. **Every replay uses today's gates.** A start re-enters
   `start_or_resume_conversation/2`, including channel binding and the
   tenant, fleet, credit and platform-inference gates. The reservation's
   advisory locks remain the authority that makes capacity atomic. A replay
   ends three ways:

   - A **capacity** error (`sandbox_quota_exceeded`, `fleet_full`) returns
     the claim and stops that tenant's drain. Every request behind it would
     meet the same wall.
   - A **transient** error returns the claim and the drain moves past it to
     the next request. `:busy`, `:provisioning`, `:runner_offline` and
     `:sandbox_at_capacity` describe one teammate's machine, not the tenant's
     ceiling: the turn in flight ends, the home finishes building, the runner
     comes back. `Workers.TeamScheduleRun` snoozes on the same list. Treating
     these as terminal would destroy the prompt over a condition that clears
     by itself.
   - Anything else is **terminal**, and the next request can proceed.

8. **The resource is visible and leaves little behind.**
   `GET /api/sandbox-queue` lists waiting work in position order, and
   `GET /api/sandbox-queue/:id` reports a terminal outcome and its
   conversation id. `DELETE /api/sandbox-queue/:id` cancels tenant-owned
   waiting work, and is a compare-and-swap so it can never reach a row the
   drainer has already claimed. Another tenant's request is 404, never 403.

   Audit events cover enqueue, start, cancellation, expiry and failure.
   Telemetry reports live row counts, tenant depth, outcomes and wait time;
   the status gauge covers live rows only, because a `last_value` over
   terminal rows climbs forever and reports nothing about the queue now.
   Every terminal transition erases `attrs`, including the prompt.
   Provenance fields stay as small history rows, and `RetentionPruner`
   expires those after 30 days. A waiting or claimed row is never pruned.

## Consequences

- A scheduled run survives a temporary tenant or fleet capacity spike.
- A caller handles a second success shape (202 with a sandbox request) only
  when it opted in. The generated contract carries that shape.
- Freeing one slot costs one existence probe plus, when there is work, one
  Oban insert on the path that freed it. Per-tenant scheduled-job uniqueness
  coalesces repeated transitions, and the reservation locks still decide
  which request wins capacity.
- A tenant can read its position but not an estimated start time. Capacity
  release and run duration are not predictable enough for an honest estimate;
  the wait-time histogram is the evidence for revisiting that.
- A request can fail after acceptance: its credit runs out, its agent or
  schedule disappears, its launch becomes invalid, or platform inference is
  unavailable. The terminal row and the audit event say so.
- The SDKs omit `/api/sandbox-queue` rather than claim it. Each one's run
  handle promises an immediate conversation, and a queued start hands back a
  request first; wrapping that means a queued-run handle that owns the
  polling and the cancellation, which is separate work.
- The reset fence proposed in #1768 makes an unconfirmed reset hold its quota
  slot. That composes with this queue rather than fighting it: a held slot is
  simply capacity the replay does not find, and the request waits for it the
  same way it waits for any other. Nothing here needs to change when that
  lands.

## Alternatives considered

- **Add `queued` to conversations.** Rejected: a request has no sandbox and
  no conversation yet, and every existing read model assumes it has both.
- **Drain only on a timer.** Rejected: an idle slot would then sit unused for
  up to five minutes. The timer is a backstop, not the mechanism.
- **Queue every wake and start.** Rejected: interactive callers already
  retry, and silently changing their response contract would be breaking.
- **Do not queue `fleet_full`.** Rejected: from the caller's side it is the
  same temporary capacity condition. A slot freed by another tenant has to
  wake this request, which is why the poke fans out.
- **Recover stale claims in a separate pass.** Rejected: it leaves the
  double-start window described in decision 6.
- **Retain launch attributes on terminal rows.** Rejected: the prompt is
  tenant content, and the audit trail needs only provenance and outcome.

## Addendum — 2026-10-12: no credit gate

The tenant limit is no longer funded by a credit balance: credits are removed
([ADR 0031](0031-credits-are-the-product.md), retired). The tenant limit is
the account's `sandbox_limit_override`, else `SANDBOX_CAP_CEILING`, under
`SANDBOX_FLEET_CEILING`. A replay (decision 7) re-checks the tenant, fleet and
inference gates; there is no credit gate to re-check, and a request can no
longer fail after acceptance because its credit ran out. The queue's bounds
and behaviour are otherwise unchanged.
