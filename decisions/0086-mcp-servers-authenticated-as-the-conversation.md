---
type: ADR
title: "An HTTP MCP server can be authenticated as the conversation"
description: "An http or sse MCP entry with \"auth\": \"conversation\" gets, as headers on session/new on every ACP runtime, the conversation id and a conversation-scoped key minted from the callback key that reads that conversation and nothing else; GET /api/auth/me names the conversation; a turn running across a deploy keeps its keys until it ends, or an hour if no server takes it back."
tags: [mcp, acp, runtimes, security, api]
status: stable
adr: "0086"
adr_status: "Accepted"
date: 2026-10-15
---

# 0086 — An HTTP MCP server can be authenticated as the conversation

**Status:** Accepted, 2026-10-15. Decided by Jake. Built (#1405, #2835).
Amended 2026-10-17 (#2934): the server gets a key of its own that reads its
conversation and nothing else, not the sandbox's `sprite` key.

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
   `Authorization: Bearer <conversation key>` (item 7) and
   `X-Managoat-Conversation-Id: <conversation id>` in the list sent on
   `session/new`, `session/resume` and `session/load`, and drops the flag.
   Every ACP runtime receives plain headers; nothing depends on a runtime
   expanding `${VAR}`. A conversation with no callback key
   (`sandbox_api_access: "none"`) has no conversation key either, and sends
   the id and no `Authorization`.

3. **Nowhere else.** The key is not written into the stored agent, the
   resolved document the server keeps, the agent's API JSON, the transcript,
   the audit trail or a log. The entry is left out of the MCP files written
   into the sandbox (Claude's `.mcp.json`, Gemini's `settings.json`), so the
   session's copy is the only one. The peer's `format_status/1` redacts
   header and env values, and the key is registered for output redaction as
   it already was.

4. **The application binds the key, not the header.** `GET /api/auth/me`
   returns `conversation_id`: for a conversation key, the conversation it
   names (item 7); for a `sprite` key, the conversation whose row names it
   (as its live key, or as the key handed over to a running turn, item 6);
   null for any other key and for a `sprite` key its conversation has
   rotated away. An application checks the bearer there and uses that id;
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
   or any other stop, revokes as before. Handing a key over shortens its
   `expires_at` to an hour (`CallbackKey.handover_ttl_seconds/0`, #2934), so
   one that no server ever takes back dies then and not after the 30-day
   callback TTL; the reattach that takes the turn back gives it the full
   TTL again (`CallbackKey.keep_handover/2`), since that server revokes it
   when the turn ends. Both changes reach the conversation key minted from
   it (item 7) and are audited as `api_key.expiry_changed`.

7. **The server gets a conversation key, not the sandbox's (#2934).** The
   `sprite` key reads and drives the whole account: every transcript
   through `/api/search` and `/api/events/stream`, and every conversation
   to list, prompt, end or start. A server the agent's author named is a
   third party, and must not get that. So `for_session/2` sends a
   `"conversation"`-scoped key instead, minted from the server's current
   callback key (`Accounts.create_conversation_api_key/4`) the first time a
   turn's MCP list needs one (`ConversationKey.ensure/2`), and only then.
   The key names its conversation and its parent (`api_keys.conversation_id`,
   `parent_key_id`). `FountainWeb.Plugs.ConversationKeyScope`, in the
   `:api` pipeline, lets it make `GET /api/auth/me` and read its own
   conversation (show, turns, events, stream, turn images) and refuses
   everything else with 403 `insufficient_scope`, including every write to
   its own conversation and any route added later. It takes its parent's
   `expires_at`, revoking the parent revokes it
   (`Accounts.revoke_api_key/3`), and deleting the parent or the
   conversation deletes it, so every path above that gives the callback key
   back gives this one back with it. The next turn after a rotation mints a
   fresh one from the new parent.

## Consequences

- The server that receives the key can read its conversation, transcript
  included, and nothing else on the account (item 7). Name only a server
  you would trust with that transcript. This is a different boundary from
  0085's, where the server's own token never enters the sandbox; here the
  credential is Managoat's, and the adapter in the sandbox holds it.
- Unbuilt: a tool server that writes to its own conversation (a label, a
  prompt). Each would be its own entry in the allowlist, decided then.
- The sandbox's own `sprite` key is a separate, wider key: it reaches its
  conversation's tree, children included, and the read-only inputs to spawn
  ([0096](0096-sandbox-key-confined-to-its-conversation-tree.md), #2981).
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
- **Mint a key per MCP server** — the original reason against it was a
  second credential with the sandbox key's scope; with a narrower scope
  (item 7) one key per conversation is enough, since every
  `"auth": "conversation"` server of a conversation reads the same thing.
- **Remove `"auth": "conversation"`** (#2934's option 2) — the boundary is
  narrowable, and Salon's tools need the binding.
- **Send the `sprite` key and narrow the `sprite` scope instead** — the
  sandbox's fan-out workflow (the bundled `managoat` skill) lists, starts
  and streams other conversations with it.
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
- 2026-10-17 — Amended (#2934), decided by Jake: the server gets a
  `"conversation"`-scoped key minted from the callback key, which reads its
  own conversation and nothing else and dies with its parent (item 7); a
  handed-over key expires in an hour unless a server takes its turn back
  (item 6).
- 2026-10-17 — The sandbox's own key is confined to its conversation tree
  ([0096](0096-sandbox-key-confined-to-its-conversation-tree.md)); the
  Consequences bullet that said it read the whole account is replaced.
