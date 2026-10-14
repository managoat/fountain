---
type: ADR
title: "One sandbox per conversation"
description: "Decided 2026-10-14 by the maintainer (#2676). Every conversation runs on a sandbox of its own, destroyed when the conversation ends. Persistent homes, attaching to a sandbox by sandbox_id, several conversations on one machine and concurrent turns on one machine are removed. Parking (0017) stays. Supersedes 0023."
tags: [sandbox, lifecycle, conversations, product]
status: stable
adr: "0073"
adr_status: "Accepted"
date: 2026-10-14
---

# 0073 — One sandbox per conversation

**Status:** Accepted — decided 2026-10-14 by the maintainer in the
complexity review tracked on #2676. **Supersedes:**
[0023](0023-persistent-agent-sandbox.md). **Amends:**
[0058](0058-the-machine-has-one-owner.md) and
[0017](0017-suspend-idle-sandboxes.md), as described under Consequences.

## Context

[0023](0023-persistent-agent-sandbox.md) added a second sandbox mode beside
the original sandbox per conversation. A persistent "home" was one machine per
agent identity (user, agent, environment, vault, runtime). Every conversation
of that identity landed on it, could run turns on it at the same time, and
left it standing when the conversation ended. A conversation could also attach
to any machine its caller owned by `sandbox_id`. On 2026-09-26 that was
extended to a guest agent of another runtime, and that extension was removed
on 2026-10-14 (the step before this one).

That mode is most of the lifecycle code in `Fountain.Machines` and
`Fountain.Conversations`. It covers home lookup and the partial unique index,
the refcount that decides whether a detach keeps the machine, co-tenants that
follow or are stranded when a dead home is rebuilt, per-runtime turn capacity,
home checkpoints, home retirement when an agent, environment or vault moves,
the reset door, the shared Codex auth binding, and a relaunch for Codex
SQLite contention that exists only because conversations shared `CODEX_HOME`.
In the 60 days before the decision, production had 52 homes, 51 of them the
maintainer's. None had been used since early September, apart from 5
conversations in the last 14 days.

## Decision

Every conversation gets a sandbox of its own and keeps it for its life. The
sandbox is destroyed when the conversation ends. While the conversation idles,
the sandbox is parked and woken as [0017](0017-suspend-idle-sandboxes.md)
describes, and that is how a conversation keeps its disk between turns.

Removed:

- `sandbox_mode: "persistent"` on `POST /api/conversations` and on the agent.
  `"ephemeral"` is still accepted, because existing clients send it.
  `"persistent"` is refused with `422 persistent_sandbox_removed`.
- `sandbox_id` on `POST /api/conversations`. A non-null value is refused with
  `422 sandbox_attach_unsupported` rather than ignored. A caller that asked
  for a shared disk must not silently get a fresh one.
- `DELETE /api/sandboxes/:id` (reset) and `fountain sandbox reset`, together
  with the admin "Retry reset". A `destroying` stamp left by a reset is
  finished by the reaper as a teardown.
- The CLI's `--sandbox-mode` and `--sandbox`, and the ACP `_meta` keys
  `sandboxMode` and `sandboxId`.
- Home lookup, home retirement on agent, environment and vault changes, the
  home checkpoint at park, co-tenant follow and strand on a wake, per-runtime
  turn capacity (`409 sandbox_at_capacity`), the last-detach keep rule (the
  fence no longer answers `:sandbox_kept`), `Machine.attach/3`, the Codex
  machine auth binding (`409 codex_inference_conflict`), and the Codex SQLite
  contention relaunch (#1910).
- The error codes `sandbox_identity_mismatch`, `sandbox_runtime_mismatch`,
  `sandbox_not_attachable`, `sandbox_not_resettable` and `sandbox_mid_turn`,
  which no code path returns any more.

A team rotation (`Team.open_fresh_conversation/3`) now provisions a fresh
sandbox. It releases the old conversation, which refuses a running turn, and
then destroys the old machine.

The max-lifetime ceiling destroys every machine. Until now it parked a home.

### The data

Migration `20261014160000_one_conversation_per_sandbox` keeps one live
conversation on every live sandbox that carried several. The keeper is the
Team conversation if there is one, else the one with the most recent turn.
Every other live conversation is detached: it is repointed at a new
`terminated` sandbox row of its own, and its runtime session is cleared. Its
next prompt therefore provisions a fresh machine, and its transcript is kept.
On 2026-10-14 production had 60 homes and 3 ephemeral machines carrying more
than one live conversation, 192 conversations on them in all.

The columns this release stops reading (`sandboxes.mode`, `runtime`,
`codex_inference_source`, `codex_peer_homes`, `departed_conversations` and
its trigger, and `agents.sandbox_mode`) are dropped a release later, so that
a replica of this release keeps working during the rollout.

## Consequences

- **What a home bought is gone.** No conversation sees another's files, so
  cross-conversation memory, shared checkouts and children on the parent's
  disk all end. A child conversation gets a sandbox of its own. Fan-out is
  unchanged.
- **Blast radius shrinks.** A prompt injection in one conversation reaches
  only that conversation's disk, the risk 0023 asked users to accept.
- **[0058](0058-the-machine-has-one-owner.md) keeps its owner and lease.**
  Only the binding layer collapses: there is no attach verb, and `detach/2`
  always ends with the machine. The lease is simplified separately (#2676,
  wave 3).
- **[0017](0017-suspend-idle-sandboxes.md) stands.** An idle machine parks
  and wakes. The "persistent home: park" row of its ceiling table no longer
  applies.
- **Leftovers.** `Fountain.Machines.Occupancy` still reads a machine as a set
  of conversations. With one conversation per machine those readers are
  degenerate but correct, and thinning them is follow-up work.

## Alternatives considered

- **Keep homes behind a flag.** That keeps all of the code for a mode almost
  nobody used. Rejected.
- **Ignore `sandbox_mode: "persistent"` and `sandbox_id` silently.** A client
  would think it had a shared disk when it did not. Rejected in favour of a
  clear 422.
- **End the extra conversations on a shared machine in the migration.** That
  is simpler, but it throws away conversations that can carry on with a fresh
  disk. Rejected.
