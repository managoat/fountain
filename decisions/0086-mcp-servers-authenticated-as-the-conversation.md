---
type: ADR
title: "An HTTP MCP server can be authenticated as the conversation"
description: "An http or sse MCP entry with \"auth\": \"conversation\" gets the conversation's callback key and id as headers on session/new, on every ACP runtime, and GET /api/auth/me names the conversation that key belongs to; a turn running across a deploy keeps its key valid until it ends, and the next turn spawns with the current key."
tags: [mcp, acp, runtimes, security, api]
status: stable
adr: "0086"
adr_status: "Accepted"
date: 2026-10-15
---

# 0086 — An HTTP MCP server can be authenticated as the conversation

**Status:** Accepted, 2026-10-15. Decided by Jake. Built (#1405, #2835).

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
provision and reattach, revoked when its server stops (or handed over, item
6), and named by the conversation row (`conversations.callback_api_key_id`). The sandbox has it
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
   `sprite` key (as its live key, or as the key handed over to a running
   turn, item 6), or null for any other key and for a key its conversation
   has rotated away. An application checks the bearer there and uses that id;
   the `X-Managoat-Conversation-Id` header is a convenience, and an
   application that trusts it alone lets one conversation's key reach
   another conversation's tools.

5. **Rotation reaches the next spawn.** A fresh spawn reads the key the
   server holds now. An idle adapter spawned with an older key does not
   carry the next turn (`Connection.stale_reason/4`,
   `"callback_key_rotated"`), whether or not the agent names an
   `"auth": "conversation"` server, because its `MANAGOAT_TOKEN` holds that
   key too; the turn spawns afresh and resumes the session with the current
   key. The case is a reattach across a deploy, which mints a new key.

6. **A running turn keeps its key across a graceful stop (#2835).** ACP has
   no call that replaces a live session's MCP servers, and a running
   process's env cannot change, so a turn reattached across a deploy goes
   on with the key it was spawned with. A server that stops gracefully
   (`:shutdown`) with a turn running does not revoke its key; it writes it
   to `conversations.handover_callback_api_key_id`
   (`CallbackKey.hand_over/2`), only while the row still names that key.
   The server that reattaches the turn keeps it valid until the turn ends
   and then revokes it (`CallbackKey.release_handover/2`, audited as
   `api_key.revoked` by `system:conversation_server`); a reattach that does
   not take the turn back, and a fresh provision, revoke it at once. It
   revokes only the key in that column, never the row's live key, so a
   duplicate server (#367) is never left without its credential. A crash,
   or any other stop, revokes as before. The key's `expires_at` is the
   backstop when no server reattaches.

## Consequences

- The server that receives the key holds a `sprite`-scoped credential for
  the account, the same one the sandbox holds: it can read the account's
  agents, environments and vaults, and start, prompt and stream
  conversations (the manual's API page, "What a sandbox credential can do").
  Name only a server you would trust inside the sandbox. This is a different
  boundary from 0085's, where the server's own token never enters the
  sandbox; here the credential is Managoat's, and the sandbox already has it.
- A turn that is running when a deploy reattaches it keeps working on the
  key its session was opened with, for both its MCP headers and its
  `MANAGOAT_TOKEN`, and that key stays valid for as long as the turn runs,
  beside the new server's own. A turn running through a crash still loses
  its key until it ends. Unbuilt: re-sending the MCP list to a running
  session, which ACP cannot do.
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
- **Re-send the MCP list to a running session** (#2835) — ACP has no call
  for it, and `session/resume` with new `mcpServers` makes the adapters
  tear the session down; the adapter's env would still hold the old key.

## History

- 2026-10-15 — Accepted and built (#1405).
- 2026-10-16 — Amended (#2835): a graceful stop mid-turn hands the key over
  to the reattaching server, which revokes it when the turn ends (item 6);
  every reattached idle peer is closed before the next turn (item 5).
