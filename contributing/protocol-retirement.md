# OpenAI-compatible and AG-UI retirement inventory

Parent: [#2252](https://github.com/managoat/fountain/issues/2252).
Decision: [ADR 0057](../decisions/0057-retire-public-compatibility-protocols.md).

**Executed.** This was the implementation plan; the removal has since landed in
the #2252 stack — the routes, their controllers, the caller MCP adapter and the
whole public cutover together (#2279), then the request-defined tool bridge's
internals (#2280), then the `openai_compat` flag (#2282). The file is kept
as the audit trail behind ADR 0057: what was surveyed, at which commits, and
which of it was shared rather than exclusive. Read the paths and line counts
below as a snapshot of `44c70b61`, not as a description of the tree.

Two items it lists are deliberately still open: the physical
`conversations.caller_tools` column
([#2273](https://github.com/managoat/fountain/issues/2273)) and the release and
site coordination ([managoat/site#3](https://github.com/managoat/site/issues/3),
[#1196](https://github.com/managoat/fountain/issues/1196)). A code merge is not
a deployment.

Where the plan and the implementation disagree, the implementation is right and
ADR 0057 records the difference — most notably the retirement response, which is
a plain 404 only on `/v1`; the `/api` paths keep the shared 401 and 406 that
authentication and content negotiation produce before dispatch.

## Evidence and scope

Audited on 2026-09-15:

- Fountain main `44c70b61` (the merged #2267 tree).
- Demos migration `3ae2e5fbdeebdcdeba843cdec8dec66c387c0544`, merged as
  [demos#77](https://github.com/managoat/demos/pull/77). Tracked app/package/script/docs
  searches found no `/v1/chat/completions`, `/api/agui`, `fountain-caller`,
  `openai_compat` or `ag-ui` references. This is source evidence only.
- Site main `9dee721898b03d4b28eaded62d00569d7d38a67c`:
  [`lib/site/pages.ex`](https://github.com/managoat/site/blob/9dee721898b03d4b28eaded62d00569d7d38a67c/lib/site/pages.ex)
  advertises both protocols in its client catalog, examples and feature comparison.
- Indexed organization code searches for the two endpoint paths,
  `fountain-caller` and `openai_compat` found Fountain and site references.
  Search visibility/indexing is incomplete evidence of consumers; repositories
  constructing URLs dynamically and external deployments can be missed.
- The maintainer reports no known consumers needing a transition period and no
  explicit users of request-defined tools. Agent-configured tools calling client
  applications **are used**. No production traffic, feature-flag assignments,
  credentials or customer tool schemas were inspected.

Historical smoke runs in ADR 0035 and the OpenBot manual establish previously
verified integrations, not present usage. No notices have been sent to consumers
or upstream projects as part of this audit.

## Two different ways to call application tools

| Path | Behavior | Disposition |
|---|---|---|
| Request `tools` → `CallerTools` → stored definitions → injected `fountain-caller` MCP server → parked call → next OpenAI/AG-UI `role: tool` message | Fountain implements the protocol's client-side tool loop | Retire with the two compatibility protocols |
| Agent `mcp_servers` / runtime tools → application MCP or callback endpoint | Agent calls tools configured for its runtime; the application owns its response | Preserve; maintainer-confirmed active use |
| Fountain callback credentials → native/team/extension/connection endpoints | Authenticates and scopes sandbox callbacks | Preserve; used beyond the request-tool bridge |

A URL pointing back to a client application is not evidence that it belongs to
`CallerTools`. Trace its configuration and call path before deleting it.

## Consumer migration and losses

| Consumer/evidence | Migration or disposition |
|---|---|
| `examples/openai-chat` | Retire the OpenAI-client example and point its README to a native SDK creation/prompt/stream recipe. Resolve names explicitly; never send a display name as `agent_id` |
| `examples/litellm-gateway` | Retire the Fountain-specific proxy config and smoke program. An OpenAI-compatible gateway is not migrated by changing its URL to `/api`; no replacement gateway is proposed |
| `examples/deepagents-contractor` and `docs/integrations/langchain.md` | Native SDK delegation can replace the leaf tool/runnable/subagent calls. Retire `as_model()` and the request-tool loop; either port and test the leaf wrappers in the implementation or remove the old example and document that loss. Do not leave a shipped example calling removed endpoints |
| Open WebUI / LibreChat / LiteLLM and other hosts advertised by the manual/site | Document loss of the generic base-URL integration; use a native client or an application-owned adapter. No current deployment was verified |
| OpenBot / AG-UI hosts, including site `HttpAgent` example | Requires a native integration handling conversations and streams. A stock `HttpAgent` cannot consume native events. Existing AG-UI docs already disclose missing native permission/attachment support |
| `managoat/demos` | No protocol migration found necessary in the audited tree. Retain its app-owned streams, promptless tabs, permissions and validated proxies |
| `managoat/site` | Coordinate catalog/example/feature claims with the release in [site#3](https://github.com/managoat/site/issues/3) |
| #1196 outreach plans | Mark only the AG-UI contribution section superseded by #2252 after the decision lands. Preserve ACP, Buzz and independent native/MCP work; do not contact upstreams without authorization |

### Native conversation mapping

- Model pickers become tenant-scoped `GET /api/agents`; resolve a selected agent's
  name to its ID before sending a native request.
- The old OpenAI key precedence is `X-Fountain-Thread`, then `user`, then
  `safety_identifier`, stored as `openai:<key>`. AG-UI `threadId` becomes
  `agui:<threadId>`. Keep existing bindings intact.
- To continue old work, find the existing conversation through the tenant-scoped
  API and prompt its ID. When using channel-based creation/resume, preserve its
  agent/environment/vault identity; an incomplete identity can select a different
  machine. Do not replay the entire host transcript into the sandbox.
- Native `runRequest` is useful when submitting a prompt and following completion.
  Promptless tabs use raw conversation creation; subsequent prompts and permission
  answers retain their explicit native endpoints.
- Native events carry blocks and stages, not `reasoning_content` or AG-UI events.
  Handle native SSE/replay/errors in the client. SDK run completion remains the
  simpler path for a caller that only needs the result.
- Native images require an explicit nonblank prompt and the accepted media/data
  shape. The OpenAI controller's synthesized image caption is a retiring dialect
  behavior, not something to copy into native validation.
- Configure application tools on the agent and preserve their credentials and
  callbacks. The native SDK is not a replacement for `role: tool` continuation.

## Production deletion map

All Fountain paths below are relative to `apps/fountain/` unless noted.

| Area | Exclusive removal | Shared boundary to preserve |
|---|---|---|
| Protocol controllers | `lib/fountain_web/controllers/{openai_controller,agui_controller}.ex`; route declarations for the four public operations | `ConversationController`, native SSE, `:api` auth/rate-limit/audit pipeline and `:accepts_json` |
| Request-tool wire/MCP adapter | `lib/fountain/caller_tools.ex`, `lib/fountain_web/controllers/caller_mcp_controller.ex`, `/api/mcp/caller/:conversation_id` | Team/extension MCP controllers, connection tools and normal runtime tools |
| Conversation storage/writes | `Conversation.caller_tools`, `Conversations.set_caller_tools/3`, both launch writers, queued-launch projection | Conversation and sandbox identity, agent `mcp_servers`, callback-key fields, native permission state. Physical column drop is a later migration |
| Pending-call state | `Pending.calls`, park/await/answer/resolve/drop-call functions; matching `ConversationServer` APIs, handlers, state entry, timeout and turn-end cleanup | `Pending` permission timers, detached requests, durable permissions and turn lifecycle |
| Session MCP assembly | `McpServers.caller/2` and its `fountain_served/2` append | `for_session/3`, agent substitution/resolved config, connection egress, team and extension ordering |
| Features/config | `openai_compat` known-flag entry and flag-specific docs/tests; OpenAI/AG-UI quiet-timeout settings if no remaining reader | `FeatureFlags`/PostHog/overrides and `connections`; shared `sse_heartbeat_ms` and native SSE idle timeout |
| Contract/types | Controller-inline schemas/operations; generated contract and TS output; AG-UI/OpenAI omissions entries | Native schemas, conformance and SDK behaviors. Inspect exported generated type removals before choosing SDK versions |
| Event vocabulary | New emission/catalog entries for `caller_tool.started/done` and current subscription documentation | Retained log/audit/webhook rows and generic historical rendering. Review existing stored filters when tightening the catalog |

The four exclusive production files total **2,295 lines** at this snapshot
(1,175 OpenAI controller, 686 AG-UI controller, 389 caller tools, 45 caller MCP
controller). This excludes router entries, distributed bridge branches,
generated output, docs and tests; it is not a final net deletion estimate.
The associated four focused test files contain 2,228 lines. Mixed tests must be
edited selectively, not deleted wholesale.

No protocol-only server package dependency was established: the dialects are
implemented in Elixir. Phoenix, Jason, ACP, runtime, MCP-auth and other shared
libraries stay. The OpenAI/LangChain/LiteLLM dependencies inside retired examples
can go with those examples; provider inference dependencies cannot.

## Mixed-file and documentation cleanup

Keep the native assertions in `saved_allowance_channel_test.exs`,
`conversation_server_acp_test.exs`, `pending_test.exs`, `mcp_servers_test.exs`,
`attach_test.exs`, redaction and audit guardrail tests. Replace generic
feature-flag tests that happen to use `openai_compat` with a test flag; preserve
remote-cache, failure and analytics behavior.

Search the whole repository again after editing, including extension
apps, tests and scripts. Update stale comments in `PromptInput`, `Agents` and
`llms_controller`, and test timing manifests for files actually deleted.
Do not remove provider-side `/v1/models` calls or model-catalog commentary just
because the path matches Fountain's retired route.

Published surfaces to reconcile:

- Integration pages: `openai-compatible.md`, `openbot.md`, `langchain.md`,
  `gateways.md`, `clients.md`, plus `docs/nav.yml`.
- Build guides, docs index, glossary, feature-status and
  configuration pages.
- `.env.example`, `.env.compose.example`, and the Compose flag comments.
- The three example directories above and links to them.
- ADR 0035 and historical ADR cross-references: explicitly supersede the current
  decision while keeping its original rationale and dated evidence readable.
- Site catalog/examples/feature comparison, tracked in site#3.

Keep old integration documentation URLs as short migration pages where they
have inbound links, with truthful loss-of-support wording. This is documentation
continuity, not a redirect or a surviving API compatibility handler.

## Cutover and persistence sequence

1. Land the decision and inventory. The source-removal PR implements the bounded
   deletion map, native regression coverage, contract/type regeneration and the
   public migration guide. It names all remaining exceptions with linked issues.
2. Announce an explicitly breaking server release and coordinate site#3. Record
   the exact tag and native SDK versions; there is no automatic deadline or
   promise of uninterrupted compatibility traffic in this proposal.
3. Before deploying that release, check for active compatibility streams and
   outstanding request-tool calls. If any appear despite the maintainer's current
   report, drain them on the old version or record an explicit interruption
   decision. Removing ingress alone does not preserve a parked client's reply
   route. Normal native runs and application callbacks are not drain targets.
4. Deploy code that no longer reads/writes caller-tool definitions. Remove the
   protocol-specific flags from deployment/PostHog configuration where present.
   Keep generic flag services and all shared callback credentials intact.
5. Verify retired route 404s and native creation, resume, prompt, stream,
   permissions and agent-configured callbacks against the released build.
6. After all old readers/jobs are gone, execute the separately reviewed forward
   migration in [#2273](https://github.com/managoat/fountain/issues/2273). Preserve
   historical rows and channel names. The first release deliberately leaves
   `caller_tools` physically present so rollback/rolling readers remain valid.

## Required implementation evidence

- Router/HTTP regressions for all five retired method/path combinations, including
  JSON and event-stream Accept headers; no dialect handler remains callable.
- Native create/attach/resume, promptless creation, saved execution allowances,
  permission answer/detach/timeout, SSE replay/errors and tenant boundaries pass.
- An agent-configured application MCP endpoint still reaches `session/new` with
  its substituted URL/headers. Exercise the same configuration on a subsequent
  turn/resume, preserving token scope/rotation and connection-backed tools.
- Extension/team MCP ordering and behavior pass without the bridge append.
- Prompt/image rules, audit/redaction and retained history remain intact.
- `mise exec -- mix precommit`, affected tests, documented contract regeneration,
  SDK checks for resulting public changes, and `bash scripts/test-docs.sh` pass.
  Run conflict-marker, changelog, diff, ADR index and OKF checks too.
- Record actual deleted production code, retained shared dependencies, release
  evidence, site deployment and the outstanding column migration in #2252.

This inventory has source-review evidence only. It does not claim those future
HTTP, runtime, migration or release checks have already passed.
