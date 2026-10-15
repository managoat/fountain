---
type: ADR
title: "Suspend idle sandboxes instead of destroying them"
description: "Idle timeout suspends a sandbox and parks it for reattach; only max lifetime destroys it."
tags: [sandbox, lifecycle]
status: stable
adr: "0017"
adr_status: "Accepted"
date: 2026-08-13
generated: { by: human:jhgaylor, at: 2026-08-13T19:28:44-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-13T19:28:44-04:00 }
---

# 0017 — Suspend idle sandboxes instead of destroying them

**Status:** Accepted — 2026-08-13.

## Context

Since #233, both lifetime bounds destroyed the sprite: the conversation server
destroyed it when a conversation crossed the idle timeout or the max-lifetime
ceiling, and the reaper did the same for rows whose server had died. The
premise was that an idle sprite bills indefinitely; the motivating incident was
a sandbox idle for 83 days.

That premise was wrong. Sprites scale themselves to zero when idle and cost
approximately nothing while suspended. Meanwhile #649 measured what the
destroy costs: the runtime's session lives in the sandbox's filesystem, so
resuming onto a fresh sprite fails on every path (`claude --resume` answers
"No conversation found with session ID"; ACP `session/resume` answers
`-32002 Resource not found`). Every idle reclaim guaranteed the agent's
amnesia to save money that was not being spent. Raising the production idle
bound to four hours (#664) treated the symptom.

## Decision

Split the two bounds by what they protect against:

- **Idle timeout (`SANDBOX_IDLE_TIMEOUT_MINUTES`, default 60) → suspend.** The
  conversation server stops, the sprite is left alone (it scales to zero on
  its own), and the sandbox row parks in `suspended`. The next prompt
  reattaches to the same sprite: same disk, same runtime session, real
  resume. This is the only automatic stop.
- **Max lifetime (`SANDBOX_MAX_LIFETIME_HOURS`) → destroy**, and it is off by
  default (`0`). Someone who wants a machine running around the clock is not
  something to stop. An operator who wants the backstop sets the variable;
  the ceiling exists for the conversation that never stops being busy, and it
  fires with a detachable session still running on the sprite, so parking
  would leave that exec burning unattended. Its price, the #649 session loss,
  is stated in the stage message.

`suspended` means: sprite alive at the provider, no conversation server, woken
only by the next prompt. It is excluded from the fleet ceiling (a parked
sprite is not compute; waking one re-runs the admission check under the same
advisory lock as creation) and from boot rehydration (parked conversations
wake on demand, not on deploy).

The max-lifetime clock measures a continuous run, not calendar age:
`sandboxes.last_resumed_at` is stamped on each wake from `suspended`, and the
ceiling is measured from `last_resumed_at || inserted_at`. A reattach of a
`ready` row stamps nothing, so restarts cannot reset the ceiling (the property
#233 encoded), while a conversation parked for a week is not destroyed the
moment it is woken.

Park or destroy at each bound is decided once, in `Fountain.Machines.Policy`
([0058](0058-the-machine-has-one-owner.md)). The machine's owner applies it
under its lease, a park through `Machines.Park` and the max-lifetime destroy
through `Machines.Destroy`, for both the conversation server's own timer and
the reaper's sweep. Every machine is one conversation's
([0073](0073-one-sandbox-per-conversation.md)), so there is no case where the
ceiling parks instead of destroying.

## Consequences

- Suspended sandboxes are never aged out; sprites accumulate at the provider
  indefinitely. This is deliberate: the parked cost is treated as zero, and
  the disk is the agent's memory. If that cost stops being ignorable, or a
  provider account-level sprite cap starts binding, a retention bound for
  `suspended` rows is the knob to add, with the #649 caveat attached.
- The reaper's abandoned pass splits on which bound fired: idle → park to
  `suspended` (audited as `sandbox.suspended`, actor
  `system:sandbox_reaper`), max lifetime → terminate. A grace window on
  `updated_at` keeps it from parking a row mid-wake, for a server that dies
  mid-wake. Suspended rows match no reaper pass.
- Every sweep that destroys sprites must include `suspended` explicitly,
  because the reaper's leak pass only touches terminal rows: account deletion
  (`Deletion.@non_terminal`) does. The fleet ceiling's active-status list
  (`pending`, `starting`, `ready`, and a machine admitted to resume) must
  never include it; the two lists differ on purpose.
- The admin sandbox view ("anything non-terminal") and the fleet ceiling
  ("compute only") legitimately disagree about a suspended sandbox.
- The production `SANDBOX_IDLE_TIMEOUT_MINUTES=240` override (#664) is
  reverted: suspension is lossless.
- Managoat runs as one node with the Recreate deploy strategy
  ([0072](0072-fountain-runs-as-one-node.md)), so a park holds its lease for as
  long as the machine's owner lives, and a slow checkpoint and suspend cannot
  be taken over mid-flight. The rolling-deploy loss window the first rollout
  had (an old node waking a `suspended` row it did not recognise) cannot recur.

## Alternatives considered

- **Destroy on both bounds** (the #233 design) — guarantees amnesia to save a
  cost that does not exist.
- **Raise the idle bound** (#664) — treats the symptom; the disk is still lost
  eventually.

## History

- 2026-08-13 — Decided and built: idle parks to `suspended`, max lifetime destroys (#649, #651, #664); parked intervals later bracketed in usage metering (#665).
- 2026-08-24 — Max lifetime off by default, with [0023](0023-persistent-agent-sandbox.md); a persistent home parked at the ceiling (#936).
- 2026-09-17 — Park or destroy decided once in `Fountain.Machines.Policy` and applied by the machine's owner ([0058](0058-the-machine-has-one-owner.md)).
- 2026-10-13 — No per-account cap; the deployment-wide fleet ceiling is the only concurrency bound ([0005](0005-platform-shared-sprites-token.md)).
- 2026-10-14 — Persistent homes removed, so the ceiling always destroys (#2676, [0073](0073-one-sandbox-per-conversation.md)); one node, the rolling-deploy window gone and the `woken_at` grace dropped ([0072](0072-fountain-runs-as-one-node.md)).
- 2026-10-15 — Usage metering removed, with the suspend/resume events ([0079](0079-usage-is-plain-counts.md)).
