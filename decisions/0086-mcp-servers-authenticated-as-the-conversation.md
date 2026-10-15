---
type: ADR
title: "An HTTP MCP server can be authenticated as the conversation"
description: "An http or sse MCP entry with \"auth\": \"conversation\" gets the conversation's callback key and id as headers on session/new, on every ACP runtime, and GET /api/auth/me names the conversation that key belongs to; a turn reattached across a deploy keeps the key it started with."
tags: [mcp, acp, runtimes, security, api]
status: stable
adr: "0086"
adr_status: "Accepted"
date: 2026-10-15
---

# 0086 — An HTTP MCP server can be authenticated as the conversation

**Status:** Accepted, 2026-10-15. Decided by Jake. Built (#1405).

## Context

An application that gives an agent its own tools serves them as a remote MCP
server, and it has to know which conversation is calling. Salon does this:
its plan tools act on the room the conversation belongs to. Until now the
only way to give that server the conversation's credential was to write
`Authorization: Bearer $${MANAGOAT_TOKEN}` in the agent's `mcp_servers` and
let the runtime expand the reference from the sandbox's process environment.
Only Claude expands `${VAR}` in an MCP header, so Salon offered its tools on
Claude alone (#1405), and the escape needed its own fix first (#1404).

The credential already exists. Every conversation that may call back holds a
`sprite`-scoped API key, minted by `CallbackKey.rotate/2` on every fresh
provision and reattach, revoked when its server stops, and named by the
conversation row (`conversations.callback_api_key_id`). The sandbox has it
as `MANAGOAT_TOKEN`. `ConversationServer` holds the plaintext in memory as
`callback_token`.

[0085](0085-mcp-connections.md) gave MCP entries an `auth` key for a user's
OAuth grant and left room for this value.

## Decision

1. **The entry asks; Managoat fills it.** An `http` or `sse` entry in an
   agent's `mcp_servers` may say `"auth": "conversation"`:

   ```json
   {"salon": {"type": "http", "url": "https://salon.example/mcp", "auth": "conversation"}}
   ```

   The agent changeset refuses the flag on a stdio entry, and beside an
   `Authorization` header of the entry's own.

2. **At the session, not before.** When a turn spawns its adapter,
   `McpServers.for_session/2` gives that entry
   `Authorization: Bearer <callback key>` and
   `X-Managoat-Conversation-Id: <conversation id>` in the list sent on
   `session/new`, `session/resume` and `session/load`, and drops the flag.
   Every ACP runtime receives plain headers; nothing depends on a runtime
   expanding `${VAR}`. A conversation with no key
   (`sandbox_api_access: "none"`) sends the id and no `Authorization`.

3. **Nowhere else.** The key is not written into the stored agent, the
   resolved document the server keeps, the agent's API JSON, the transcript,
   the audit trail or a log. The entry is left out of the MCP files written
   into the sandbox (Claude's `.mcp.json`, Gemini's `settings.json`), so the
   session's copy is the only one. The peer's `format_status/1` redacts
   header and env values, and the key is registered for output redaction as
   it already was.

4. **The application binds the key, not the header.** `GET /api/auth/me`
   returns `conversation_id`: the conversation whose row names the presented
   `sprite` key, or null for any other key and for a key its conversation
   has rotated away. An application checks the bearer there and uses that id;
   the `X-Managoat-Conversation-Id` header is a convenience, and an
   application that trusts it alone lets one conversation's key reach
   another conversation's tools.

5. **Rotation reaches the next spawn.** A fresh spawn reads the key the
   server holds now. An idle adapter whose session was opened with an older
   key does not carry the next turn (`Connection.stale_reason/4`,
   `"callback_key_rotated"`); the turn spawns afresh and resumes the session
   with the current key. The case is a reattach across a deploy, which mints
   a new key while the previous server's revoke has already taken the old
   one.

## Consequences

- The server that receives the key holds a `sprite`-scoped credential for
  the account, the same one the sandbox holds: it can read the account's
  agents, environments and vaults, and start, prompt and stream
  conversations (the manual's API page, "What a sandbox credential can do").
  Name only a server you would trust inside the sandbox. This is a different
  boundary from 0085's, where the server's own token never enters the
  sandbox; here the credential is Managoat's, and the sandbox already has it.
- A turn that is running when a deploy reattaches it keeps the key its
  session was opened with, which the previous server revoked as it stopped.
  Its calls to the application fail until the turn ends; the next turn
  spawns with the new key. The adapter's own `MANAGOAT_TOKEN` has the same
  limit. Unbuilt: re-sending the MCP list to a running session (#2835).
- Whether a runtime honours HTTP headers on `session/new` is the runtime's.
  The manual's MCP page records what each pinned adapter advertises.
- `"auth"` now takes two values, `"conversation"` and
  `{"connection": id}`. A third is a new decision.

## Alternatives considered

- **Leave `$${MANAGOAT_TOKEN}` to the runtime** — only Claude expands it, so
  the same agent works on one runtime of three.
- **Write the key into the resolved document at provision** — it would then
  sit in the server's long-lived state and in the files written into the
  sandbox, frozen at the key of that provision.
- **Mint a key per MCP server** — a second credential with the same scope
  and the same lifetime, and one more thing to revoke, for no boundary the
  sandbox key does not already draw.
- **Bind by the header alone** — any key the account holds would then
  reach any conversation's tools.

## History

- 2026-10-15 — Accepted and built (#1405).
