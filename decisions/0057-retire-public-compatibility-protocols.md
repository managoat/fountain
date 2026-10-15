---
type: ADR
title: "Retire the OpenAI-compatible and AG-UI public protocols"
description: "The compatibility endpoints and request-tool bridge are removed; native conversations and agent-configured application tools stay."
tags: [api, architecture, integrations]
status: stable
adr: "0057"
adr_status: "Accepted"
date: 2026-09-15
---

# 0057 — Retire the OpenAI-compatible and AG-UI public protocols

**Status:** Accepted, 2026-09-15, and built (#2252 stack; column drop #2319).
Supersedes [0035](0035-openai-compatible-endpoint.md), which described the
OpenAI-compatible dialect as shipped behavior.

## Context

[0035](0035-openai-compatible-endpoint.md) added an OpenAI-compatible public
API alongside AG-UI. Both translated an external transcript into a stateful
conversation and translated native events back into another protocol. Their
request-defined tools also needed a bridge through conversation storage, MCP
injection, parked calls, timers and follow-up tool-result messages.

The maintainer requested retirement under #2252. On 2026-09-15 they reported
no known consumers requiring a transition period and no users explicitly
relying on request-defined tools, and identified active use of tools
configured on agents that call back into client applications, which is
supported behavior to keep. That report is maintainer evidence, not a
measured census of hosted traffic or self-hosted databases.

The source and consumer inventory (`contributing/protocol-retirement.md`)
recorded the snapshots, removable code, shared behavior and migration gaps;
the retirement it planned is done and the file was removed on 2026-10-13 (it
is in git history before that date). [0056](0056-conversation-request-inputs.md)
supplies native request APIs; it does not make an OpenAI or AG-UI host work by
changing its base URL alone.

## Decision

These five method/path combinations are retired, in an explicitly announced
breaking server release:

- `POST /v1/chat/completions`
- `GET /v1/models`
- `GET /v1/models/:model`
- `POST /api/agui/:agent_id`
- `POST /api/mcp/caller/:conversation_id`

Their route declarations, exclusive controllers, translations and the
request-tool bridge (`Fountain.CallerTools`, the registration write, the
parked-call plumbing in `ConversationServer` and `Pending`, and the bridge's
advertisement to a sandbox) are removed, along with the `openai_compat` flag.
No dialect-specific response envelope, redirect or dormant implementation is
kept. The caller MCP route went in the same change as the four protocol
routes because neither could wait: the two controllers were the only way to
hand a parked call back to a client, so still offering the tools would let an
agent park a call nobody could answer; and the caller route scoped only to the
tenant, never binding a sandbox's callback key to the conversation in its
path, so one sandbox could park calls on another conversation's turn in the
same account. This ADR assigns no release tag; retirement did not ship in
v0.17.1.

A retired path answers with the server's shared unmatched-route behavior,
which is not a plain 404 everywhere:

| Path | JSON client | No API key | `Accept: text/event-stream` |
|---|---|---|---|
| `/v1/*` | 404 | 404 | 404 |
| `/api/agui/*`, `/api/mcp/caller/*` | 404 | 401 | 406 |

`/v1` matches no route, so `NoRouteError` renders 404 before anything
authenticates. An unmatched `/api` path reaches `FountainWeb.Plugs.ApiNotFound`,
forwarded last in the router inside the `:accepts_json, :api` pipeline:
`TenantAPIAuth` answers a keyless call 401, and `plug :accepts, ["json"]`
refuses an event-stream `Accept` with 406, which is what an AG-UI client sends.
A path that never existed answers the same way, so nothing dialect-specific
survives.

Kept: agent-configured MCP servers and application tool callbacks, credential
substitution, callback-key scope and rotation, native SSE, permissions and
runtime tool execution. OpenAI/Codex inference adapters, credentials and model
support remain.

Native clients resolve an agent explicitly and use conversation creation,
prompt submission, event streams and permission responses. Existing
conversations and `openai:`/`agui:` channel bindings remain readable and usable
through native APIs; channels are not renamed and sandboxes are not replaced to
migrate a client. Request-defined tool callbacks have no drop-in native
replacement: put application tools in the agent's tool/MCP configuration, or
build a client-side integration over native APIs. No second protocol server is
reintroduced as part of this retirement.

`conversations.caller_tools` was retired in two phases: the implementation
release stopped all reads and writes and left the column, and a later forward
migration, `20260915210000_drop_caller_tools_from_conversations` (#2273,
#2319), dropped it once old servers were gone; its minimum upgrade-from
version is v0.18.0. Callback-key fields, native permission records,
conversations, sandboxes and historical events, audit and webhook deliveries
are preserved. The retired `caller_tool` stage vocabulary stays valid as an
event filter; nothing publishes it.

Public migration pages, examples and release notes were coordinated with
[managoat/site#3](https://github.com/managoat/site/issues/3): the four
integration pages stay as migration pages at their URLs and the three runnable
examples were deleted. The AG-UI outreach section of
[#1196](https://github.com/managoat/fountain/issues/1196) points to
retirement; its ACP and native/MCP work is independent.

## Consequences

- Four exclusive production files, 2,295 lines at the audited commit, are gone,
  with the bridge-only server state, its timers and the turn-end drain.
  `conversation_server.ex` fell from 2,364 to 2,213 lines. This counts deleted
  production code, not a net reduction across the repository.
- Generic OpenAI/AG-UI hosts lose a zero-adapter integration. Native SDK
  wrappers can replace delegation calls, but they are not `ChatOpenAI`,
  `HttpAgent` or request-tool-loop substitutes; the migration pages say which
  capability ended.
- Generated API types lost the retired operations and schemas, under each
  SDK's version policy.
- With the column dropped, the obsolete tool definitions are gone; re-adding
  an empty column would not restore them.

## Alternatives considered

- **Leave the endpoints disabled behind flags** — keeps the duplicate code,
  tests and bridge state; AG-UI was not gated by `openai_compat` anyway.
- **Keep a generic request-tool callback bridge** — no reported direct consumer
  justifies the subsystem; agent-configured application tools already serve the
  pattern in active use.
- **Remove all callback/MCP plumbing** — breaks current application
  integrations and credential scoping, which are shared native behavior.
- **Drop the column in the first release** — an older Ecto reader could still
  select it during a rolling deployment; two phases made that boundary explicit.

## History

- 2026-09-15 — Accepted: retire the five routes and the request-tool bridge, keep agent-configured tools (#2252).
- 2026-09-15 — On implementation, the "ordinary 404" was corrected to the 404/401/406 table above.
- 2026-09-15 — `conversations.caller_tools` dropped by migration (#2273, #2319); minimum upgrade-from v0.18.0.
- 2026-10-14 — The extension-dispatch scope, connections and the `connections` flag were removed with extensions ([0043](0043-first-party-extensions.md), [0054](0054-extensions-contribute-connection-providers.md), [0025](0025-product-analytics-in-posthog.md)); unmatched `/api` paths now reach `ApiNotFound`, with the same answers.
- 2026-10-15 — Team tools removed with the team ([0074](0074-remove-the-team.md)); they leave the list of preserved behavior.
