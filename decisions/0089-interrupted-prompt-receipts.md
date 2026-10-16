---
type: ADR
title: "Report accepted prompts interrupted before turn admission"
description: "Durable identifier-only receipts distinguish queued prompts lost on restart from admitted turns; clients resume reads without replaying writes."
tags: [conversations, deployment]
status: stable
adr: "0089"
adr_status: "Accepted"
date: 2026-10-16
---

# 0089 — Report accepted prompts interrupted before turn admission

**Status:** Accepted.

## Context

The one-node Recreate deployment interrupts streams and can stop an accepted
launch or follow-up before it creates a turn. In-memory casts and tasks do not
survive that stop. Waiting for a turn terminal event cannot resolve a prompt
that has no turn. Issue [#2866](https://github.com/managoat/managoat/issues/2866)
requires an observable outcome without duplicate prompts.

## Decision

Persist an identifier-only receipt before acknowledging an asynchronous prompt.
Carry its internal ID to admission. Delete it in the same transaction that
inserts the turn; a rollback preserves both the absence of a turn and the receipt.
Refusals publish correlated `wake/failed` before deleting their receipt.

Before the endpoint starts, publish `wake/failed` with
`reason=deployment_interrupted` and `retryable=true` for receipts belonging to
an earlier boot. A remaining receipt proves that this submission was not
admitted. This does not automatically reprovision a sandbox or replay a prompt.
Pending machines remain under the existing next-user-action recovery contract.

Receipts contain no prompt text, images or credentials, cascade with the
conversation, and disappear on resolution. They are internal lifecycle
bookkeeping; acceptance is audited by the existing submission doors and failure
is persisted in the conversation's stage log. Client request IDs remain optional
correlation labels, not unique keys or idempotency guarantees.

Clients reconnect reads with a configurable elapsed-time budget (180 seconds by
default), preserve cursors and honor cancellation. They never automatically
repeat create or prompt POSTs. A lost write response remains an ambiguous outcome
requiring inspection. Recovery stops only this submission's wait; the conversation
may remain promptable.

## Consequences

The receipt table must be migrated before running this server. Submissions made
by older releases have no receipts and cannot acquire this guarantee retroactively.
A crash between publishing an interruption and deleting its receipt may repeat
the failure notification after another restart; it cannot repeat model work.

SSE readers subscribe to a shutdown notification and close in `prep_stop`, before
the HTTP listener drains. A process-wide marker catches subscriptions racing the
broadcast. This preserves the normal HTTP drain budget for other requests. A
controlled release restart with an open SSE connection reduced endpoint drain
from 15.004 seconds to about 3 ms; this is local evidence, not a production SLO.

Shutdown checkpoints and one-second external probes support measuring future
rollouts. They do not reconstruct missing historical endpoint timestamps or
establish a fixed upper bound for a failed deployment. Single-node/Recreate
remains the supported architecture ([ADR 0072](0072-fountain-runs-as-one-node.md)).
