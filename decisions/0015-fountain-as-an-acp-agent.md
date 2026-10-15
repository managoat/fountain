---
type: ADR
title: "Managoat as an ACP agent, reachable from a code editor"
description: "`managoat acp` speaks ACP over stdio to a code editor and HTTP+SSE to the API, so an editor drives a Managoat agent, permission requests included."
tags: [acp, cli, editor]
status: stable
adr: "0015"
adr_status: "Accepted"
date: 2026-08-09
generated: { by: human:jhgaylor, at: 2026-08-14T22:24:48-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-14T22:24:48-04:00 }
stale_after: 2026-11-14
---

# 0015 — Managoat as an ACP agent, reachable from a code editor

**Status:** Accepted, 2026-08-09. Built: `managoat acp` in `cli/internal/acp`
opens, prompts, streams, cancels and reloads a conversation from an editor,
and forwards permission requests (#709, #708). A channel binding from
OpenClaw is unproven; see Consequences.

## Context

[0014](0014-agent-client-protocol.md) makes Managoat an ACP **client** of the
coding-agent CLIs it runs in sandboxes. This ADR is the other end: making a
conversation reachable from an editor, with Managoat as the ACP **agent**.
Together they make Managoat an ACP proxy: the same block vocabulary arrives
from a sandbox on one side and leaves for an editor on the other.

```
  ┌─ editor (Zed, VS Code, …) ─────────────┐   ┌───────────────┐
  │  spawns  ▸  managoat acp               │   │ other clients │
  │              ▲   ACP over local stdio  │   │ (apps, CLI)   │
  └──────────────┼─────────────────────────┘   └───────┬───────┘
                 │  HTTP + SSE                         │  HTTP + SSE
                 ▼                                     ▼
  ┌─────────────────────────────────────────────────────────┐
  │                        managoat                         │
  │    ACP agent upward (0015) · ACP client downward (0014) │
  │          the runtime dialects stop at this line         │
  └────────────────────────────┬────────────────────────────┘
                               │  ACP over the sandbox's stdio
                               ▼
  ┌─────────────────────────────────────────────────────────┐
  │     sandbox — where the workspace and the files are     │
  │               claude  ·  codex  ·  gemini               │
  └─────────────────────────────────────────────────────────┘
```

`managoat acp` is a local subprocess of the editor, not a network peer of the
server: the editor spawns it and speaks ACP down a pipe, and the HTTP+SSE hop
is on the far side of that process. That is where authentication and
multi-account selection stay. The workspace is at the bottom of the picture;
the editor is the one box with no files in play.

**Why an editor would want this rather than a local agent.** An editor can
already spawn Claude Code or Codex locally. Managoat is worth reaching for
only where a local subprocess cannot go:

- The work outlives the editor. A turn keeps running when nothing is
  attached; reopen and reattach.
- Conversations are addressable and persistent: a transcript, turn history
  and an audit trail ([0013](0013-audit-trail.md)).
- Fan-out. `X-Managoat-Parent-Conversation-Id` and
  `GET /api/conversations/:id/tree` let one editor session start and
  enumerate sub-conversations.
- The unit is a Managoat agent, not a raw CLI: environment, vault overrides,
  skills and MCP servers already provisioned, and inference credentials that
  never touch the developer's machine.
- Other clients of the account see the same conversation while it runs.

**What it builds on.** The Go CLI was already an HTTP+SSE client of this API:
the resumable, heartbeated `GET /api/conversations/:id/stream`, a consumer
with reconnect and backoff that already classifies terminal outcomes (the
classification an ACP stop reason needs), `managoat auth login` with
`~/.managoat/credentials`, and a release that ships platform binaries. One
subcommand on an installed, authenticated binary is a small proposition.

**The impedance mismatch.** ACP assumes the agent runs beside the editor and
edits the editor's files: `fs/read_text_file` and `fs/write_text_file` are
client-provided, and `tool_call.locations` lets the editor follow along. A
Managoat agent edits a sandbox's filesystem, on a repo the sandbox cloned.
Every design that pretends otherwise produces an agent that appears to edit
the open project and does not.

## Decision

Build `managoat acp`: a subcommand of the Go binary that speaks ACP over
stdio to an editor and HTTP+SSE to the API. The editor spawns it as it spawns
any other ACP agent.

1. **Local stdio, not ACP's remote transport.** The remote transport is
   documented by ACP as work in progress. Stdio is stable and universally
   implemented, needs no inbound network path to the developer's machine,
   and keeps authentication, instance and profile selection in the CLI that
   already handles them. Even if the remote transport stabilises, the local
   process is where credentials and multi-account selection live, so it
   stays.

2. **A control surface, not a workspace.** `managoat acp` declares no client
   `fs/*` or `terminal/*` capabilities and requests none. The editor is
   where you watch, steer, interrupt and fan out a remote conversation. A
   tool call's `locations` are moved under `_meta`
   (`managoat.sandboxLocations`) rather than labelled, because the protocol
   cannot say "this path is on another machine"; an editor that learns the
   key can show them as remote. Reading a file the agent touched and
   syncing a workspace are separate decisions; the read is
   [0039](0039-sandbox-files-over-the-api.md), and workspace sync is not
   built.

3. **Protocol mapping.**

   | ACP | Managoat |
   |---|---|
   | `initialize` | capability declaration; `authMethods` points at `managoat auth login` |
   | `authenticate` | the API key in `~/.managoat/credentials` |
   | `session/new` | `POST /api/conversations` for the chosen agent (`--agent`) |
   | `session/load` | replay `GET .../stream` from `Last-Event-ID: 0` |
   | `session/prompt` | `POST .../prompts`, then block on the stream until a terminal stage |
   | `session/update` | the stream's ACP events, forwarded |
   | `session/cancel` | `POST .../interrupt` |
   | `session/request_permission` | forwarded to the editor; answered with `POST .../requests/:request_id` |
   | `session/set_config_option` | acknowledged, not applied |
   | stop reason | the sandbox adapter's own |

   The ACP session id is the conversation id, not a minted one, because an
   editor must be able to hand back an id from last week. `session/prompt`
   correlates the prompt with the terminal stage on the SSE stream, as the
   CLI does to give `managoat run` a truthful exit code (#398).

4. **Translation happens once, server-side.** The stream used to carry raw
   runtime stdout in four dialects, with parsers only in Elixir. A second
   copy in Go would be two implementations of undocumented formats drifting
   apart, so this work waited on 0014. With Managoat an ACP client of the
   sandbox, it already holds ACP blocks, and `managoat acp` forwards rather
   than translates. A dialect parser must never land in `cli/`.

5. **Permission forwarding.** Under an `ask` policy the request goes to the
   editor with the agent's own options, and the answer returns through
   `POST /api/conversations/:id/requests/:request_id`. An editor that
   errors, disconnects or dismisses the prompt denies at once, with a
   `reject_*` option the agent offered; an option id the agent never
   advertised is refused rather than relayed; and when the agent offered no
   rejection, nothing is sent, because inventing one is what the
   never-synthesise rule forbids. Behind that, 0014's permission timeout,
   well under the idle bound, denies a request nobody answers. A request
   lives only as long as the turn that raised it. Other clients are peers on
   the same request: first answer wins, and a 409 is an ordinary outcome.
   `--permission` sets the policy for an editor entry (`auto_allow`, `ask`,
   `auto_deny`, or per-tool `key=verdict` pairs), because an agent's default
   is `auto_allow` and would raise nothing to forward.

6. **Session config options are the agent's.** Every option a conversation
   has, its model above all, comes from the agent at launch
   ([0062](0062-acp-session-config-options.md)), so `session/new` and
   `session/load` advertise no `configOptions` and `session/set_model` is
   absent. `session/set_config_option` exists because some clients push
   controls at spawn and abort on "method not found" (#759): it applies
   nothing and answers with `_meta.managoat.applied: false` and no
   `configOptions` list, because acpx narrows the controls it sends to the
   last list it saw and an honest, empty list would fail its next push
   (#760). Advertising options the agent does not have, to satisfy such a
   client, was rejected as describing unbuilt behaviour.

## Consequences

- **The event stream is an interface.** The ACP adapter and every other
  client render from the same events, so the stream carries the
  compatibility obligations of one, documented in the OpenAPI spec and
  under the router-walking guard test (#707).
- **A proxy that forwards stored events depends on the store's filter.**
  Running against production found that the filtered replay excluded the
  `acp` stream, so `session/load` returned an empty transcript and
  reconnects silently dropped events (#716). It also found that a lost wake
  race left a conversation pointing at a sandbox it had just terminated,
  which this adapter reproduced every session because `session/new` and the
  first prompt arrive a second apart (#717).
- **Editor support is ours.** ACP clients differ in what they render and
  how they handle a slow agent, and "it doesn't work in $EDITOR" lands in
  our tracker whoever's bug it is.
- **A third surface.** A conversation that takes seconds to provision reads
  very differently in an editor than on a page that showed a spinner.
- **A real product limit.** The editor sees the conversation, not the
  files. That is stated, not hidden.

### OpenClaw is another ACP client

[OpenClaw](https://docs.openclaw.ai) fronts chat surfaces (Telegram, Discord,
Slack, Signal) and routes them to coding harnesses over ACP. It reaches
Managoat through the same `managoat acp` adapter, after Zed and
[Buzz](0020-buzz-as-a-client-of-the-acp-gateway.md). Its `acpx` plugin
supports a custom-command harness, so registering an agent is configuration
(`plugins.entries.acpx.config.agents.<id> = { command, args }` with
`permissionMode: "approve-all"`), documented in `docs/integrations/openclaw.md`.

Verified on 2026-08-16 against production: an acpx-identical client, then
the real acpx 0.11.2 binary on Node 24 (both the `--agent` escape hatch and a
named agent from the `agents` map), then a live `--dev` gateway (OpenClaw
2026.7.1) running `openclaw agent` → `sessions_spawn(runtime: "acp")` → acpx
→ `managoat acp` → sandbox → reply relayed back. Authentication flowed from
the inherited host credentials, with no secret in the acpx config. The
gateway round trip is what found decision 6's two constraints (#759, #760):
OpenClaw pushes the model its brain chose, and a `thinking` level derived
from it, over `session/set_config_option`, and treats any rejection as fatal.

From a chat surface there is no open project to confuse with a sandbox path,
so decision 2's limit is a natural fit there.

Still open, or OpenClaw's to fix:

- A Telegram or Discord channel binding has not been run; it is the same
  gateway path with a delivery step on the end.
- A `mode: "run"` spawn makes one-shot acpx open a session twice, so every
  gateway spawn opens two conversations and prompts one; the orphan waits
  `pending` until the idle reaper parks it. Worth an upstream report, not an
  adapter workaround.
- OpenClaw is single-user, so every session authenticates as the host's
  Managoat login. Per-channel-user identities are out of scope.
- Under `approve-all`, per-tool approvals do not reach a channel.

## Alternatives considered

- **Do nothing; keep the web UI as the only interactive surface.**
  Defensible, but the editor is where the developer already is, and every
  advantage above already existed and was exposed only in a browser.
- **ACP's remote transport, served from Phoenix.** Removes the local binary
  and is cleaner, but the transport is work in progress and it would move
  auth and multi-account selection into the protocol layer. Revisited at
  gate 3 and still declined.
- **A bespoke extension per editor.** Maximum control and the way to true
  workspace sync, but it is the N×M problem ACP exists to remove.
- **Build this before 0014.** Smaller and more visible, but the only way to
  emit `session/update` then was to reimplement the dialect parsers in Go.

## History

- 2026-08-09 — Decided: `fountain acp` as a stdio ACP agent over the HTTP+SSE API, gated on 0014 (#709).
- 2026-08-14 — Gates 1–3 built: transcript, session lifecycle, auth and distribution (#710–#715, #718, #707); session id is the conversation id; locations moved to `_meta`; #716 and #717 found against production.
- 2026-08-16 — OpenClaw verified as another ACP client; `session/set_config_option` accepted and not applied, with no `configOptions` in the reply (#759, #760).
- 2026-08-22 — Gate 4, permission forwarding, built (#708).
- 2026-10-14 — A forwarded permission request lives only as long as its turn (#2676).
- 2026-10-15 — `session/set_config_option` briefly forwarded options as each prompt's `session_config` (#2663), then reverted to acknowledge-only when session options became the agent's alone (0062).
- 2026-10-15 — Renamed: the command is `managoat acp` ([0082](0082-the-project-is-managoat.md)).
