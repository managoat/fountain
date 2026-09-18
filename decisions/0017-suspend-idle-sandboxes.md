---
type: ADR
title: "Suspend idle sandboxes instead of destroying them"
description: "Idle timeout suspends the sandbox and parks it for reattach; only max lifetime destroys it. Built in the PR that added this ADR."
tags: [sandbox, lifecycle]
status: stable
adr: "0017"
adr_status: "Accepted"
date: 2026-08-13
generated: { by: human:jhgaylor, at: 2026-08-13T19:28:44-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-13T19:28:44-04:00 }
---

# 0017 — Suspend idle sandboxes instead of destroying them

**Status:** Accepted (built in the PR that added this document)
**Date:** 2026-08-13

**Amended 2026-08-24 (#936):** the max-lifetime ceiling this ADR keeps as the
one destroying bound is now **off by default** (`SANDBOX_MAX_LIFETIME_HOURS`
defaults to `0`). Decided 2026-08-23 with ADR 0023: a tenant who wants a
machine running 24/7 is not something to stop, and a persistent home's disk
is the product. The idle timeout is the only automatic stop; the
concurrent-sandbox cap (0026) bounds how many machines a tenant can keep up.
An operator who wants the backstop sets the variable, and then the text below
applies as written (ephemeral: destroy; persistent home: park, per 0023).

**Amended by [0058](0058-the-machine-has-one-owner.md) (2026-09-17):** the
idle and ceiling decision is `Fountain.Machines.Policy`'s, since stage 7a. Park
or destroy at each bound, and the capability check behind it, are decided there
once. The machine's owner applies them under its lease (`Machines.Park`), for
both the conversation server's own timer and the reaper's sweep. The policy
below is unchanged; it has one home instead of two callers that decided it
separately.

## Context

Since #233, both lifetime bounds destroyed the sprite: the ConversationServer
called `Sprites.destroy` when a conversation crossed the idle timeout or the
max-lifetime ceiling, and the reaper's abandoned-sandbox pass did the same for
rows whose server had died. The design was chosen under the premise that an
idle sprite bills indefinitely — the motivating incident was a sandbox idle
for 83 days.

That premise was wrong. Sprites scale themselves to zero when idle and cost
approximately nothing while suspended; the sprite does not need Fountain's
help to stop billing. Meanwhile #649 measured what the destroy costs: the
runtime's session lives in the sandbox's filesystem, so resuming onto a fresh
sprite fails on every path we have (`claude --resume` answers "No conversation
found with session ID"; ACP `session/resume` answers `-32002 Resource not
found`). Every idle reclaim guaranteed the agent's amnesia to save money we
were not spending. The response at the time (#651) was honest UX copy; #664
raised the production idle bound to four hours so human-gated incident
conversations would survive review — treating the symptom, because the disk
loss itself was assumed to be the price of cost control.

## Decision

Split the two bounds by what they actually protect against:

- **Idle timeout → suspend.** The ConversationServer stops, the sprite is left
  alone (it scales to zero on its own), and the sandbox row parks in a new
  `suspended` status. The next prompt reattaches to the same sprite through
  the existing reuse path — same disk, same runtime session, real resume.
- **Max lifetime → destroy**, unchanged. The ceiling exists for the
  conversation that never stops being busy; it fires with a detachable
  session still running on the sprite, and parking would leave that exec
  burning unattended. Its price — the #649 session loss — is still stated
  honestly in the stage message.

`suspended` means: sprite alive at sprites.dev, no ConversationServer, woken
only by the next prompt. It is excluded from the concurrency quota (a parked
sprite is not compute; waking one re-runs the quota gate under the same
advisory lock as creation) and from boot rehydration (parked conversations
wake on demand, not on deploy).

The max-lifetime clock measures a **continuous run**, not calendar age:
`sandboxes.last_resumed_at` is stamped on each wake from `suspended`, and the
ceiling is measured from `last_resumed_at || inserted_at`. A deploy reattach
of a `ready` row stamps nothing, so restarts still cannot reset the ceiling —
the property #233 encoded — while a conversation parked for a week is not
destroyed the moment it is woken.

## Accepted costs

- **Suspended sandboxes are never aged out.** Sprites accumulate per tenant at
  sprites.dev indefinitely. This is deliberate: the parked-sprite cost is
  treated as zero, and the disk is the agent's memory. If that cost stops
  being ignorable — or a sprites.dev account-level sprite cap starts binding —
  a retention bound for `suspended` rows is the knob to add, with the #649
  caveat attached.
- **Usage metering blurs at the edges, in both directions — half-fixed by
  #665.** `sandbox_suspended`/`sandbox_resumed` events now bracket each parked
  interval, and the `usage_summary`/`usage_summaries` roll-up subtracts that
  interval (or, for a sandbox torn down while still parked, the span up to
  its `sandbox_terminated`) from `duration_ms`, so the overstating direction
  is corrected. The understating direction stands: a sandbox that stays
  suspended forever still emits no `sandbox_terminated`, so its time never
  enters `sandbox_minutes` at all. A `suspended → ready` wake still
  deliberately emits no second `sandbox_provisioned`.
- **A rolling deploy has a one-time loss window.** An old node waking a
  suspended row does not recognise the status, provisions a fresh sprite, and
  the parked disk is destroyed by the reaper. Old nodes cannot *write*
  `suspended` (their changeset rejects it), so the window is read-only and
  self-limiting.

## Consequences elsewhere

- The reaper's abandoned pass splits on which bound fired: idle → park to
  `suspended` (audited as `sandbox.suspended`, actor `system:sandbox_reaper`),
  max lifetime → terminate as before. A grace window on `updated_at` keeps it
  from parking a row mid-wake, before the new server registers in Horde's
  async registry. Suspended rows match no reaper pass.
- Every sweep that destroys sprites had to learn the status, because the
  reaper's leak pass only touches terminal rows: account deletion
  (`Deletion.@non_terminal`) and tenant suspension (`_unsafe_reap_all_for_user`)
  both include `suspended` explicitly. The quota's active-status list must
  **never** include it — those two lists now differ on purpose.
- The admin sandbox view ("anything non-terminal") and the quota counter
  ("compute only") now legitimately disagree about a suspended sandbox.
- The production `SANDBOX_IDLE_TIMEOUT_MINUTES=240` override (#664) is
  reverted: suspension is lossless, so the stock idle bound no longer
  endangers human-gated incident conversations.
