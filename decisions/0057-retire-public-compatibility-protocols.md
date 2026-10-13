---
type: ADR
title: "Retire the OpenAI-compatible and AG-UI public protocols"
description: "Remove the compatibility endpoints and the request-tool bridge while preserving native conversations and agent-configured application tools. Built in the #2252 stack; supersedes ADR 0035. Amended 2026-09-15: the retirement answer is not a plain 404 on every path — /api paths keep the shared 401 and 406 that content negotiation and authentication produce before dispatch."
tags: [api, architecture, integrations]
status: stable
adr: "0057"
adr_status: "Accepted"
date: 2026-09-15
---

# 0057 — Retire the OpenAI-compatible and AG-UI public protocols

**Status:** Accepted and built, in the #2252 stack. **This ADR supersedes
[ADR 0035](0035-openai-compatible-endpoint.md)**, which described the
OpenAI-compatible dialect as shipped behavior.

Built, in the order the stack landed it:

- The four OpenAI/AG-UI route declarations and their two exclusive controllers,
  with their operations and schemas out of the contract and the generated types
  — **and the caller MCP adapter and its route with them**, so all five retired
  method/path combinations went unrouted together, along with the bridge's
  advertisement to a sandbox. Neither could wait for a later change. The two
  controllers were the only things that could hand a parked call back to a
  client, so still offering those tools would have let an agent on a legacy row
  park a call nobody could answer; and the caller route scoped only to the
  tenant, never binding a sandbox's callback key to the conversation named in
  its path, so while it was reachable one sandbox could park calls on another
  conversation's turn in the same account.
- The public cutover in the same change: the four integration pages kept as
  migration pages at their URLs, their cross-links, the three runnable examples
  deleted, and the operator flag guidance. The approved inventory requires the
  source-removal change to carry the migration guide.
- `Fountain.CallerTools` itself, the registration write, and the parked-call
  plumbing in `ConversationServer` and `Pending`, all unreachable by then.
  Nothing publishes a `caller_tool` stage any more, so the retired event
  vocabulary is the last trace of the bridge — it stays valid as a filter, and
  leaves at the rollback floor rather than here.
- The `openai_compat` flag, which by then gated nothing. `FEATURE_FLAGS_ON`
  itself stays: a deployment drops the `openai_compat` entry and keeps any
  other, because `connections` still decides the Connections creation rollout
  wherever PostHog answers flags. Only a deployment without PostHog has no
  shipped feature left that needs a key in it.

Nothing of the retirement itself is left unbuilt. **This section was updated by
each change of the stack**, so it describes the tree it is merged into.

Outside the stack entirely, with their own gates: the physical
`conversations.caller_tools` column, which
[#2273](https://github.com/managoat/fountain/issues/2273) drops once the
deployment floor has advanced, and the release itself — no tag is claimed
below, and a code merge is not a deployment.

## Context

[ADR 0035](0035-openai-compatible-endpoint.md) added an OpenAI-compatible public
API alongside AG-UI. Both translate an external transcript into a stateful
Fountain conversation and translate native events back into another protocol.
Their request-defined tools also require a bridge through conversation storage,
MCP injection, parked calls, timers and follow-up tool-result messages.

The maintainer requested retirement under #2252. On 2026-09-15, they reported no
known consumers requiring a transition period and no users explicitly relying
on request-defined tools. They also identified active use of tools configured
on agents that call back into client applications. Those tools are supported
behavior to preserve. This report is maintainer evidence, not a measured census
of hosted traffic or self-hosted databases.

The source and consumer inventory in `contributing/protocol-retirement.md`
recorded the exact snapshots, removable code, shared behavior and migration
gaps. The retirement it planned has been executed, and the file was removed on
2026-10-13; it is in git history before that date.
[ADR 0056](0056-conversation-request-inputs.md) supplies native request APIs; it
does not make an OpenAI or AG-UI host work by changing its base URL alone.

## Decision

Retire these five method/path combinations, in an explicitly announced
breaking server release:

- `POST /v1/chat/completions`
- `GET /v1/models`
- `GET /v1/models/:model`
- `POST /api/agui/:agent_id`
- `POST /api/mcp/caller/:conversation_id`

Remove their route declarations and exclusive controllers, translations and
request-tool bridge. Preserve no dialect-specific response envelope, redirect
or dormant feature-flag implementation. Record the actual release tag when
scheduled; this ADR does not assign one or claim retirement shipped in v0.17.1.

**Amended 2026-09-15, on implementing it.** This decision originally said
requests "then receive the ordinary unmatched-route HTTP 404". That is true of
`/v1` and not of the `/api` paths, and the difference is worth writing down
because a retiring client meets it:

| Path | JSON client | No API key | `Accept: text/event-stream` |
|---|---|---|---|
| `/v1/*` | 404 | 404 | 404 |
| `/api/agui/*`, `/api/mcp/caller/*` | 404 | **401** | **406** |

`/v1` matches no route at all, so `NoRouteError` renders 404 before anything
authenticates. The `/api` paths fall through to the extension-dispatch scope,
which sits inside the `:api` pipeline: `TenantAPIAuth` answers a keyless call
401, and `plug :accepts, ["json"]` refuses an event-stream `Accept` with 406 —
which is exactly what an AG-UI client sends, so that is the common case for
that path rather than an edge one.

Both are the *shared* unmatched-`/api` behaviour: a path that never existed
answers identically, which `protocol_retirement_test.exs` asserts by comparing
the two rather than hard-coding a status. So the decision's intent holds —
nothing dialect-specific survives — but "ordinary 404" was too simple a
sentence for what a caller actually sees.


Preserve agent-configured MCP servers and application tool callbacks, including
credential substitution, connection-backed tools, callback-key scope/rotation,
extension and team tools, native SSE, permissions, and runtime tool execution.
OpenAI/Codex inference adapters, credentials and model support remain supported.
The implementation must prove these boundaries with regression coverage.

Native clients resolve an agent explicitly and use conversation creation,
prompt submission, event streams and permission responses. Existing conversations
and `openai:`/`agui:` channel bindings remain readable and usable through native
APIs; do not rename channels or create replacement sandboxes merely to migrate a
client. Request-defined tool callbacks have no drop-in native replacement. Put
application tools in the agent's tool/MCP configuration, or build a client-side
integration over native APIs; do not reintroduce a second protocol server in a
new directory as part of this retirement.

Remove all reads and writes of `conversations.caller_tools` in the implementation
release, leaving the physical column temporarily intact. A later forward
migration, [#2273](https://github.com/managoat/fountain/issues/2273), drops it only
after every old server/job is gone and the rollback floor is documented. Never
rewrite its applied migration. Preserve callback-key fields, native permission
records, conversations, sandboxes and historical events/audit/webhook deliveries.

Coordinate public migration pages, examples and release notes with
[managoat/site#3](https://github.com/managoat/site/issues/3). Update the AG-UI
outreach section of [#1196](https://github.com/managoat/fountain/issues/1196) to
point to retirement; its ACP, Buzz and native/MCP work remains independent.

## Consequences

- Four exclusive production files contained 2,295 lines at the audited commit
  and are gone, along with the bridge-only server state, its timers and the
  turn-end drain. `conversation_server.ex` fell from 2,364 to 2,213 lines and
  its size pin with it. This counts deleted production code, not a net
  reduction across the repository.
- Native launch, streaming, permission and MCP code still needs independent
  tests. Shared `Pending` permission logic, `FeatureFlags`, API authentication
  and rate limits remain; their protocol-specific branches can go.
- Generic OpenAI/AG-UI hosts lose a zero-adapter integration. Native SDK wrappers
  can replace delegation calls, but they are not `ChatOpenAI`, `HttpAgent` or
  request-tool-loop substitutes. Documentation must say which capability ended.
- Generated API types lose the retired operations/schemas. Review package export
  impact and follow each SDK's version policy; native SDK behavior alone does
  not imply that removing a public generated type is source-compatible.
- The code release is reversible while the old column remains. The later column
  drop destroys obsolete tool definitions and needs its own backup/rollback
  accounting. Re-adding an empty column does not restore those definitions.

## Alternatives considered

- **Leave the endpoints disabled behind flags** — keeps the duplicate code,
  tests and bridge state; AG-UI is not gated by `openai_compat` today.
- **Keep a generic request-tool callback bridge** — no reported direct consumer
  justifies preserving this subsystem. Agent-configured application tools already
  serve the actively used pattern and retain their existing behavior.
- **Remove all callback/MCP plumbing** — breaks current application integrations,
  team/extension tools and credential scoping; those are shared native behavior.
- **Drop the column in the first release** — an older Ecto reader can still select
  it during a rolling deployment. Two phases make that deployment boundary explicit.
