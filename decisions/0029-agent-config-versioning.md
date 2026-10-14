---
type: ADR
title: "Agent config versioning: full-value snapshots in a tenant table, rollback as a new edit, provenance on conversations"
description: "agent_versions stores the complete config per change in a tenant-owned table with tenant-data lifecycle (cascade and deletion; the account export it also joined was removed on 2026-10-12) — outside ADR 0013's trail, which keeps recording only which fields moved — with rollback re-applied through update_agent (history is append-only, never pruned) and conversations stamped with the version they launched under; the version does not drive the sandbox, the live agent row still does."
tags: [agents, conversations, audit, data-model]
status: stable
adr: "0029"
adr_status: "Accepted"
date: 2026-08-23
generated: { by: human:mdonigian, at: 2026-08-23T22:30:00-04:00 }
verified: { by: human:mdonigian, at: 2026-08-23T22:30:00-04:00 }
---

# 0029 — Agent config versioning: full-value snapshots in a tenant table, rollback as a new edit, provenance on conversations

**Status:** Accepted. Everything described here is built: `Fountain.Agents.AgentVersion`,
the snapshot writes in `Agents.create_agent/2` and `update_agent/3`,
`rollback_agent/3`, `_unsafe_current_version_id/1`, the
`conversations.agent_version_id` stamp in `Conversations.start_conversation/2`
and `Team.open_on_sandbox/4`, the history page at
`FountainWeb.AgentsLive.Versions`, and the versions section of the account
export. Covered by the `versions` describe in `agents_test.exs`,
`agent_versions_live_test.exs`, the stamping test in
`conversations_start_test.exs`, and the `agent rollback` entry in
`audit_guardrail_test.exs`.

## Context

An agent is a named, re-runnable config, and it gets edited: prompts tuned,
models swapped, skills added. Nothing recorded what the config *was*, so two
questions had no answer from the data: "why did this agent behave differently
yesterday" and "how do I get back the config that worked". The audit trail
deliberately cannot answer either — ADR 0013 records which fields moved,
never their values, because the trail must not be a second copy of tenant
data.

Three constraints made the design non-obvious:

- **The values rule.** Restoring a config requires the values, which is
  exactly what the audit trail refuses to hold. Whatever holds them is a copy
  of tenant data and needs the lifecycle obligations that come with that
  (deletion, export), not audit's.
- **Old configs can be invalid now.** `Agent.changeset/2` validates against
  the present: a sandbox provider can be de-configured, a permission policy
  can be unenforceable on a runtime. A restore path that bypasses validation
  reintroduces states the changeset exists to refuse.
- **Conversations read the agent live.** `ConversationServer` fetches the
  agent row at provision and at prompt time; the only launch-time snapshot is
  `runtime`. Making a conversation *run* an old version would mean swapping
  every one of those reads.

## Decision

A new tenant-owned table, `agent_versions`: one immutable row per shape the
agent has had, holding a `version` counter and the complete string-keyed
`config` (every field `Agent.changeset/2` casts except ownership and the
avatar). `create_agent` writes version 1 in the same transaction as the
insert; `update_agent` writes the next version in the same transaction as the
update, and only when a config field actually moved. A migration backfilled
version 1 for every pre-existing agent from its live row, so every agent has
at least one version. The audit call stays outside the transaction, per
ADR 0013.

**Full values live here because this is a tenant table, which ADR 0013 does
not govern.** 0013 constrains the *audit trail* — the trail still records
only which fields moved, and nothing about that changes. What is decided
here is the design that sits beside it: `agent_versions` is tenant data with
tenant-data lifecycle — it cascades with the agent, leaves with account
deletion, and joins the account export. The two mechanisms answer different
questions — the trail answers *who changed what, when*; a version answers
*what the config was* — and future work (a versions API, running a pinned
version) leans on this table, not the trail.

**Rollback is a new edit, never a rewrite.** `rollback_agent/3` feeds the
stored config back through `update_agent/3`: the config is re-validated on the
way in (a snapshot referencing removed infrastructure is refused with a
changeset error, not restored blind), the rollback itself becomes the newest
version, and the audit row is the ordinary `agent.updated` carrying
`rolled_back_to` metadata — no new actor, no new action.

**Conversations record provenance, nothing more.** `start_conversation` and
the team page stamp `conversations.agent_version_id` with the agent's newest
version at launch, exactly parallel to the snapshotted `runtime`. The live
agent row still drives the sandbox. The FK nilifies on version delete so a
conversation never goes down with its version.

Versions have no retention window — a stated decision in `RetentionPruner`'s
moduledoc: a version older than every conversation that ran it is still the
only record of what the config was, and the table grows by one row per config
edit, not per use.

## Consequences

- "Why did it behave differently yesterday" is answerable from the row: the
  conversation names its version, the version holds the config, the history
  page diffs it against its neighbours.
- A bad edit has a one-click way back that cannot silently restore an invalid
  config, because rollback goes through the same validation as any edit.
- Every config edit now costs one extra row and, on the write path, one
  `max(version)` query inside the transaction; the unique index on
  `[agent_id, version]` turns a concurrent-edit race into a changeset error.
- The export grows: each agent carries its full version history, values
  included.
- Deleting an environment or vault removes its references from the tenant's
  agents and writes a version for each changed configuration in the same
  transaction as the deletion (#1052). An emptied allowlist stays empty;
  unrestricted access stays unrestricted. Older snapshots retain their
  original references, and rollback still revalidates them. Agent updates
  and deletion serialize on the affected rows, so the newest snapshot
  describes the persisted configuration.
- Making a conversation actually *run* its pinned version remains unbuilt and
  is out of scope here; it would mean replacing `ConversationServer`'s live
  agent reads with version-aware ones. Nothing in this ADR should be read as
  that mechanism existing.

## Alternatives considered

- **Values in audit metadata** — breaks ADR 0013's rule for every reader of
  the trail instead of keeping values in one tenant table with tenant-data
  lifecycle; retention would also fight audit's own windows.
- **Rollback as a direct row write (bypassing the changeset)** — restores
  configs the validators now refuse; the sandbox-provider and
  permission-policy validators exist precisely to keep those states out.
- **Mutable history (rollback rewrites the row, drops later versions)** —
  destroys the provenance conversations point at and makes "what ran
  yesterday" unanswerable again, which is the problem this exists to solve.
- **Snapshot the whole config onto each conversation** — duplicates the
  config per launch instead of per edit, and gives no diff or rollback
  surface; the version table is strictly smaller and does both.

## Addendum — 2026-10-14: the account export is gone

The account data export was removed on 2026-10-12 (simplify 4/5, #2615;
[0009](0009-account-deletion-and-export.md)'s addendum of that date). The
Decision's "joins the account export" and the Consequence "The export grows"
no longer apply. `agent_versions` still cascades with its agent and leaves
with account deletion; nothing else here changes.
