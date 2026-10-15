---
type: ADR
title: "Agent config versioning: full-value snapshots in a tenant table, rollback as a new edit, provenance on conversations"
description: "agent_versions keeps the complete config per change, append-only and user-owned, and each conversation records the version, model and session config it launched with; going back means writing an old config to the agent again."
tags: [agents, conversations, audit, data-model]
status: stable
adr: "0029"
adr_status: "Accepted"
date: 2026-08-23
generated: { by: human:mdonigian, at: 2026-08-23T22:30:00-04:00 }
verified: { by: human:mdonigian, at: 2026-08-23T22:30:00-04:00 }
---

# 0029 — Agent config versioning: full-value snapshots in a tenant table, rollback as a new edit, provenance on conversations

**Status:** Accepted, 2026-08-23, and built: `Fountain.Agents.AgentVersion`,
the snapshot writes in `Agents.create_agent/2` and `update_agent/3`,
`_unsafe_current_version_id/1`, the `conversations.agent_version_id` stamp in
`Conversations.start_conversation/2`, and `GET /api/agents/:id/versions` and
`/versions/:version`. Running a conversation on a pinned version is not built.

## Context

An agent is a named, re-runnable config, and it gets edited: prompts tuned,
models swapped, skills added. Nothing recorded what the config was, so "why did
this agent behave differently yesterday" and "how do I get back the config that
worked" had no answer from the data. The audit trail deliberately cannot answer
either: [0013](0013-audit-trail.md) records which fields moved, never their
values, so the trail is not a second copy of tenant data.

Three constraints made the design non-obvious:

- **The values rule.** Restoring a config needs the values, which the audit
  trail refuses to hold. Whatever holds them is tenant data, with tenant-data
  lifecycle obligations, not audit's.
- **Old configs can be invalid now.** `Agent.changeset/2` validates against the
  present: a sandbox provider can be de-configured, a permission policy can be
  unenforceable on a runtime. A restore path that bypasses validation
  reintroduces states the changeset exists to refuse.
- **Conversations read the agent live.** `ConversationServer` fetches the agent
  row at provision and at prompt time. Making a conversation run an old version
  would mean swapping every one of those reads.

## Decision

**A tenant-owned table, `agent_versions`,** holds one immutable row per shape
the agent has had: a `version` counter and the complete string-keyed `config`
(every field `Agent.changeset/2` casts except ownership and the avatar).
`create_agent` writes version 1 in the same transaction as the insert;
`update_agent` writes the next version in the same transaction as the update,
only when a config field moved. A migration backfilled version 1 for every
pre-existing agent. The audit call stays outside the transaction, per 0013.

Full values live here because this is a tenant table, which 0013 does not
govern; the trail still records only which fields moved. The trail answers who
changed what, when; a version answers what the config was. `agent_versions`
cascades with its agent and leaves with account deletion. Versions have no
retention window (stated in `RetentionPruner`'s moduledoc): a version older
than every conversation that ran it is still the only record of what the
config was, and the table grows by one row per edit, not per use.

**Going back is a new edit, never a rewrite.** Read the version with
`GET /api/agents/:id/versions/:version` and write its `config` to the agent
with `PUT /api/agents/:id` or a manifest. That goes through `update_agent/3`:
the config is re-validated (a snapshot referencing removed infrastructure is
refused with a changeset error, not restored blind), the edit becomes the
newest version, history is not rewritten, and the audit row is an ordinary
`agent.updated`. Older audit rows that carry `rolled_back_to` keep it as
ordinary metadata.

**Conversations record the version they launched with.** `start_conversation`
stamps `conversations.agent_version_id` with the agent's newest version at
launch, parallel to the snapshotted `runtime`. The FK nilifies on version
delete, so a conversation never goes down with its version. The live agent row
still drives the sandbox: system prompt, skills, MCP servers and environment
are read live.

The version is also read, once (#2664): when a sandbox has no applied-skills
record (`sandboxes.applied_skills` is nil) and the disk has no skills manifest,
`Fountain.Conversations.Skills.previous_skills/1` reads the version's
`config["skills"]` as the evidence for which entries under the skills root
Managoat owns, so `SandboxSkills.reconcile/4` removes a skill the version named
and the agent no longer does. With no version, or a deleted one, nothing is
removed on that evidence. Versions are immutable, so this cannot change under
a conversation, but it is a behavioral dependency, not only provenance.

The version is the agent's shape at launch, not what the conversation runs.
What it runs is recorded on the conversation and its turns:

- **The model.** `conversations.model` is the conversation's override
  ([0061](0061-conversation-model-override.md)); nil runs the agent's model.
  The model and runtime the conversation was admitted with are in
  `conversations.inference_source`, and each turn's in
  `turns.inference_source`. An agent model edit that would move the source is
  refused on the next turn (`inference_source_changed`), not followed.
- **The session config options.** `conversations.agent_session_config` is the
  agent's `session_config` copied at launch, and `conversations.session_config`
  the launch's own request over it
  ([0062](0062-acp-session-config-options.md)). Each turn's `config_selection`
  records the merged request with its prompt's options, and what the adapter
  applied, skipped and restored.

## Consequences

- "Why did it behave differently yesterday" is answerable from the data: the
  conversation names its version and the version holds the config.
- A bad edit has a way back that cannot silently restore an invalid config,
  because it goes through the same validation as any edit.
- Every config edit costs one extra row and one `max(version)` query inside the
  transaction; the unique index on `[agent_id, version]` turns a concurrent-edit
  race into a changeset error.
- Deleting an environment or vault removes its references from the tenant's
  agents and writes a version for each changed configuration in the same
  transaction (#1052). An emptied allowlist stays empty; unrestricted access
  stays unrestricted. Older snapshots keep their original references, and
  writing one back revalidates them. Agent updates and deletion serialize on
  the affected rows, so the newest snapshot describes the persisted config.
- Making a conversation run its pinned version remains unbuilt and out of
  scope; it would mean replacing `ConversationServer`'s live agent reads.

## Alternatives considered

- **Values in audit metadata** — breaks 0013's rule for every reader of the
  trail instead of keeping values in one tenant table; retention would also
  fight audit's own windows.
- **Rollback as a direct row write (bypassing the changeset)** — restores
  configs the validators now refuse.
- **Mutable history (rollback rewrites the row, drops later versions)** —
  destroys the provenance conversations point at, which is the problem this
  exists to solve.
- **Snapshot the whole config onto each conversation** — duplicates the config
  per launch instead of per edit, and gives no diff or way back.
- **A dedicated rollback function** — built as `rollback_agent/3`, then removed
  for having no caller once the console's history page went; writing the old
  config through the API does the same with the same guarantees.

## History

- 2026-08-23 — Accepted: full-value versions in a tenant table, rollback through `update_agent/3`, version stamped on conversations; with a console history page and the account export.
- 2026-10-12 — The account export is removed (#2615, [0009](0009-account-deletion-and-export.md)); versions no longer join it.
- 2026-10-15 — The console history page is removed ([0076](0076-console-without-configuration-pages.md)); versions are read through the API.
- 2026-10-15 — `rollback_agent/3` is removed (#2733); going back is a plain `PUT` of the old config.
- 2026-10-15 — Recorded the skills reconcile's read of the version (#2664) and where the conversation's effective model and session config live.
