---
type: ADR
title: "An OpenAI-compatible /v1/chat/completions where the model is an agent"
description: "Superseded by 0057. Was: an OpenAI chat-completions dialect at /v1."
tags: [api, integrations, openai, dialect]
status: deprecated
adr: "0035"
adr_status: "Superseded by 0057"
date: 2026-08-25
generated: { by: human:jhgaylor, at: 2026-08-25T23:30:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-25T23:30:00-04:00 }
---

# 0035 — An OpenAI-compatible `/v1/chat/completions` where the model is an agent

**Status:** **Superseded by [ADR 0057](0057-retire-public-compatibility-protocols.md)**,
which retires this dialect. The endpoints described below no longer exist:
`/v1/chat/completions` and the two model reads are removed, and `/v1` answers
404. The rest of this file is kept unedited as the record of what was built and
why — read it as history, not as a description of the server.

Accepted and built in the PR that added this file (#1198). Nothing described
here was unbuilt. Shipped as **alpha behind the `openai_compat`
feature flag** (off by default on the hosted platform, 404 when off), the
same way `team_comms` shipped: the dialect's edges may move until the
gateway and client smokes below have run.

## Context

The integration-docs tracker (#1196) had some fifteen rows — Open WebUI,
LibreChat, Codex, OpenCode, Letta, the agent frameworks — gated on a remote
MCP server Fountain does not have. Each of those clients would also have
needed a plugin, an auth dance, or a docs contribution to someone else's
repo. The question under all of them is one question: *how does a generic
client reach a Fountain agent with no plugin?*

AG-UI (`POST /api/agui/:agent_id`, `FountainWeb.AguiController`) answered it
for the CopilotKit world at the price of one endpoint. The same trade exists
for a much larger world. Every AI gateway (LiteLLM, Portkey, Kong AI Gateway,
Cloudflare AI Gateway, Helicone, Bifrost) and every chat client with a
base-URL field (Open WebUI, LibreChat, Raycast, Continue-style IDE tools,
`curl`, the `openai` SDK in any language) speaks OpenAI's
`POST /v1/chat/completions`. A bearer key is the whole protocol, and the doc
is ours.

It also makes Fountain a *target* of a gateway rather than a consumer of one:
a gateway routes `model = pr-reviewer` to us, and its users get an agent that
runs for ten minutes in a sandbox where a model answered in ten seconds.

The hard part is statefulness. Chat completions are stateless — the client
replays the whole history on every call — and a Fountain conversation is the
opposite: the sandbox holds the context. The AG-UI endpoint already resolved
that shape (the thread is mapped to a conversation, not replayed into it),
but a chat-completions request carries no thread id, so the open question
was where the key comes from. Five options were on the table (#1198): a
header, the `user` field, `metadata.thread_id`, a hash of the first message,
or no binding at all.

A second public dialect on the server is a decision, not a feature: every
future change to how a turn is opened, prompted, streamed or refused now has
two wire shapes to keep honest.

## Decision

1. **The server carries the OpenAI chat-completions dialect at `/v1`.**
   `POST /v1/chat/completions`, `GET /v1/models`, `GET /v1/models/:model`,
   in `FountainWeb.OpenAIController`. Same auth chain as `/api` (bearer API
   key, rate limit, audit); the credit gate stays `Billing.check_spend/1` in
   the context (ADR 0031), so this door is gated by construction. The path
   is `/v1`, not `/api/v1`, because every client appends `/chat/completions`
   to whatever base URL it is given and `https://host/v1` is the shape they
   all expect.

2. **The thread key is `X-Fountain-Thread`, else `user`, else
   `safety_identifier`, else 400.** The
   header is explicit and any gateway that forwards headers forwards it. The
   `user` field is the fallback because every SDK exposes it and Open WebUI
   and LibreChat set it per person — one sandbox per person per agent, which
   is the team page's model and is right for a chat client. A request with
   none of the accepted keys is refused with a 400 that names the header.
   The stateless fallback (one conversation per request) is the failure mode this endpoint
   exists to avoid — Hermes's `copilot-acp` provider does exactly that over
   ACP and gets one sandbox per message — so it is refused, not offered.
   `metadata.thread_id` and the content hash are not read: the first is
   unsupported by generic clients, the second breaks under any gateway that
   rewrites content. The key binds as channel `openai:<key>`, namespaced
   like `agui:` and `fountain:team`.

   **Amended 2026-09-03:** `safety_identifier` is read third, after `user`.
   OpenAI introduced it as one successor to the deprecated `user` field. The
   LiteLLM smoke run on 2026-08-26 found that the gateway's then-current
   parameter filter dropped `user` but forwarded `safety_identifier`. This
   keeps a body-level thread key available when the client cannot set a custom header. The
   header remains the precise choice for a per-chat id; both body fields
   commonly identify a person.

3. **The mapping is the AG-UI mapping.** `model` is the agent's name (what
   `/v1/models` advertises and a picker shows) or its id, tenant-scoped;
   unknown is 404 in OpenAI's error envelope. Only the newest `user` message
   is the prompt; `system`/`developer` messages ride with the first prompt
   of a new conversation and are ignored afterwards. `image_url` parts must
   be `data:` URLs — the server fetches nothing on the client's behalf.

4. **What the client sees is text, plus its own tools.** `text` blocks are
   `content`. Thinking, tool use and the lifecycle stages stream as
   `reasoning_content`, the de-facto field Open WebUI, LibreChat and LiteLLM
   render, which a client that does not know it ignores and which keeps a
   stall watchdog fed while a sandbox provisions. **A tool call is emitted if
   and only if the tool came from the request's `tools`** (amended 2026-08-25,
   #1202; the original rule was "never"). The sandbox's own tool use is never
   a tool call: it ran, and the result is already in the text. A
   caller-defined tool is the opposite case — it exists only on the client,
   the sandbox cannot run it, and the client is the only party that can
   return a result — so it is served to the agent as one more Fountain-served
   MCP server (`Fountain.CallerTools`, `POST /api/mcp/caller/:conversation_id`),
   and when the agent calls it the completion ends with `finish_reason:
   "tool_calls"` while the turn stays open. The next request on the thread
   whose newest messages are `role: "tool"` answers the parked calls and
   streams the rest of the turn; a `user` message while calls are pending is
   409 `tool_calls_pending`. A parked call has the permission prompt's
   deadline; on expiry the agent gets an error result and the turn goes on.
   `tool_choice: "none"` registers nothing; `required` and a named tool are
   400, because Fountain cannot force an agent's next action. The AG-UI
   endpoint gets the same bridge (`TOOL_CALL_START/ARGS/END`, then
   `RUN_FINISHED` with `stopReason: "tool_calls"`). `usage` is zeros — a turn
   is billed in seconds (ADR 0030), and an invented token count is a number
   a gateway would aggregate. `finish_reason` is `stop` or `tool_calls`; a
   failed turn is an `error` event on the stream (then `[DONE]`) or a 500
   with `code: turn_failed` unstreamed.

5. **A busy thread is 409 with `Retry-After`, not a queue.** Chat clients
   retry. Queuing a prompt behind a running turn would be a second
   concurrency model beside ADR 0023's runtime capacity, for a client that
   already knows how to wait.

6. **Order: this before the MCP server.** For the #1196 rows this answers
   (Open WebUI, LibreChat, LiteLLM and every gateway, the `openai` SDK), it
   is the whole integration. Rows where the client wants to *call tools on*
   Fountain rather than *talk to* an agent — Codex, OpenCode and the
   frameworks as tool hosts, Letta — still need an MCP server; this ADR does
   not build one and does not decide its shape. Some rows want both (a chat
   surface and a tool), and get the chat half now.

7. **Neither the SDK nor the CLI learn it.** The SDK is for people who want
   the real API; the CLI already is one. The OpenAPI spec documents the
   three operations under the Integrations tag, and the generated SDK types
   follow because the spec does, not because the SDK wraps them.

## Consequences

- One base URL and one key put a Fountain agent in any chat client or behind
  any gateway. The doc (`docs/integrations/openai-compatible.md`) is ours to
  keep, and no one else's repo needs a contribution.
- A second dialect means a second translation of the turn's block events.
  The two controllers share the mapping by convention (same block → same
  meaning) rather than by module; a change to how a turn opens or ends must
  land in both, and each has a suite that plays a turn through replay and
  asserts the wire shape (`agui_controller_test.exs`,
  `openai_controller_test.exs`).
- `user` as a thread key means a client that sets it per person and never
  sets the header gets one long-lived conversation per person per agent.
  That is the intended behaviour; it also means that person's sandbox is
  never rotated by the client. `?fresh` has no equivalent here; a new key is
  a new sandbox.
- `reasoning_content` is a convention, not a standard. A client that
  displays only `content` shows nothing while a first request provisions,
  and looks quiet though the connection is healthy — the same trade AG-UI's
  thinking events make.
- The bridge makes a Fountain agent usable *inside* a framework loop
  (`create_agent`, Deep Agents, the `openai` tool runner) rather than only
  as a leaf. A changed `tools` list between requests replaces the old one at
  the next turn; whether a runtime re-lists a server's tools mid-session is
  the adapter's business, and a framework sends the same list every time.
  Approvals (#643) are a separate thing that can be built on the same
  parked-call shape later; this bridge never prompts either way.
- Gateway and client smokes were tracked on #1198. The LiteLLM half ran on
  2026-08-26 against production and is preserved as
  `examples/litellm-gateway`: the model picker filled from `/v1/models`, two
  turns on one forwarded `X-Fountain-Thread` landed in one conversation, and
  `reasoning_content` passed through. The Open WebUI half is still owed.

## Alternatives considered

- **The MCP server first, or only.** Answers the tool-host rows and none of
  the chat-client rows; needs an auth dance on every client; and is a
  bigger surface to design. Chosen order is this first (decision 6).
- **`metadata.thread_id` as the key.** The cleanest field OpenAI accepts,
  and the least supported by generic clients and gateways. Not read.
- **Hash the first user message.** Zero configuration, and fragile under any
  gateway that rewrites content; an edit to the first message would
  silently open a new sandbox. Not read.
- **One conversation per request when no key is given.** Works out of the
  box and spawns a sandbox per line of chat. Refused (decision 2).
- **Queue a prompt behind a running turn.** A second concurrency model for
  clients that already retry. Refused (decision 5).
- **Emit the sandbox's tool use as `tool_calls`.** Asks the client to
  execute something that already ran and waits for a result it will never be
  sent — the same reasoning as the AG-UI endpoint's. Still refused (decision
  4); the 2026-08-25 amendment emits only the *caller's* tools, which is the
  protocol working as designed rather than this alternative.
- **Hold the agent's MCP call open until the client answers.** The call is
  an HTTP request from the sandbox through the tunnel, whose idle limit is
  well under the five-minute deadline. So the handler waits under a minute
  and returns `pending` with a call id, and a reserved `wait_for_caller_result`
  tool re-attaches — the shape `Fountain.Team.Mcp.wait_for_teammate` already
  lives with. A client that answers within seconds never sees it.
- **Keep the tool list only in server state.** The sandbox lists tools over
  HTTP whether or not a server is running, and the row is the one place both
  the controller and the MCP endpoint can read; the *parked calls* stay in
  server state because the HTTP request they answer dies with the BEAM anyway.
- **The Anthropic Messages shape as well.** One dialect; the OpenAI one is
  what gateways and clients speak.
