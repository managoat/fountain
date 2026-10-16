# MCP servers

An MCP server gives a runtime tools that it did not ship with. You declare
them through the `mcp_servers` field on an
[Agent](../../concepts/agent.md), and Managoat passes the declaration
through. Managoat hosts no MCP server of its own.

## How to declare your own

`mcp_servers` on an Agent takes a map of server definitions. Their `env` takes
`${VAR}` substitution, which Managoat resolves from the merged environment and
vault secrets at spawn time.

```yaml
mcp_servers:
  github:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PAT}"
```

The credential comes from a [vault](../../concepts/vault.md). Nobody writes it
into the agent. Read
[Where a secret comes from](../../concepts/secrets.md).

A server you declare runs **in** the sandbox, and it holds a real credential
there.

### One runtime does this differently

On `claude`, an upstream defect breaks session-scoped MCP delivery. So
Managoat provisions `.mcp.json` into the sandbox and starts the project
servers, and it does not pass them for each session. The effect is the same.
The mechanism matters only when you debug why a raw ACP probe behaves one way
and Managoat behaves another. Read [claude](../runtimes/claude.md). A server
with `auth: conversation` is the exception: it is not written to `.mcp.json`
and reaches Claude in the session only, with its headers. Read
[Your application's own server](#your-applications-own-server).

## A remote server that signs in with OAuth

A remote server that wants OAuth, such as Linear's, is connected once on
`/account` and then named under `auth`:

```yaml
mcp_servers:
  linear:
    type: http
    url: https://mcp.linear.app/mcp
    auth:
      connection: <connection id>
```

Managoat runs the OAuth flow, keeps the token refreshed, and the egress
broker adds it to the server's requests; the sandbox holds a placeholder.
Read [Connect Linear to an agent](../../guides/connect-an-mcp-server.md).

## A remote server with an API key

A remote server that takes an API key or a personal access token is declared
with a `url` and the headers it needs. A bearer comes from a vault through
`${VAR}`; bind that secret to the server's host and the sandbox holds only a
placeholder. Read [Bindings](../../concepts/secrets.md#bindings).

```yaml
mcp_servers:
  internal:
    type: http
    url: https://mcp.example.com/mcp
    headers:
      Authorization: "Bearer ${EXAMPLE_TOKEN}"
```

## Your application's own server

An application that gives an agent its own tools serves them as a remote MCP
server, and it needs to know which conversation is calling. Give the entry
`auth: conversation`:

```yaml
mcp_servers:
  salon:
    type: http
    url: https://salon.example/mcp
    auth: conversation
```

Each time a turn opens its runtime session, Managoat sends that server two
headers:

```text
Authorization: Bearer <the conversation's sandbox key>
X-Managoat-Conversation-Id: <the conversation id>
```

The key is the conversation's `MANAGOAT_TOKEN`. Managoat puts the header on
the session itself, so it reaches Claude, Codex and Gemini the same way, and
no runtime has to expand `${MANAGOAT_TOKEN}`. The agent keeps the
`auth: conversation` you wrote. The key is not stored in it, and it is not in
the API's agent JSON, the transcript, the audit trail, a log or any file in
the sandbox.

The agent is refused if the entry is a stdio server, or if it has an
`Authorization` header of its own.

### Check the key, not the header

Before your server trusts a call, it sends the bearer to
`GET /api/auth/me`. For a sandbox key the answer has `conversation_id`, the
conversation the key belongs to. For any other key `conversation_id` is null.

```bash
curl -s -H "Authorization: Bearer $KEY" https://managoat.example/api/auth/me
# {"id": "...", "conversation_id": "7c1e...", ...}
```

Act on that `conversation_id`, not on the `X-Managoat-Conversation-Id`
header. An agent can send any header it likes from its sandbox, but the key
it holds belongs to its own conversation. Use the header for routing
and logs at most. If you check only the header, one conversation's key can
reach another conversation's tools. Cache the answer for a short time if you
must, because the key changes:

- Managoat mints a new key each time it provisions or reattaches the
  conversation's sandbox, which includes a wake and a deploy. It revokes the
  old key when the conversation's server stops, or, when a deploy stops it
  in the middle of a turn, when that turn ends. A revoked key gets `401`
  from `/api/auth/me`.
- When the conversation has rotated away from a key, `conversation_id` is
  null for it. A key kept for a turn running across a deploy still names
  its conversation until the turn ends.

### What your server is trusted with

The key has `sprite` scope, the same as the sandbox's own key. With it your
server can do what an agent in the sandbox can do: read the account's
agents, environments and vaults, and start, prompt and stream its
conversations. It cannot change an agent, an environment or a vault, and it
cannot mint keys. Read
[What a sandbox credential can do](../../api.md#what-a-sandbox-credential-can-do).
Name only a server that you would trust inside the sandbox.

A conversation started with `sandbox_api_access: "none"` has no key. Its
server gets `X-Managoat-Conversation-Id` and no `Authorization`.

### What each runtime does with it

All three pinned adapters accept an HTTP server with headers on
`session/new` and send the headers on every request:

| Runtime | Adapter | `http` | `sse` |
|---|---|---|---|
| `claude` | claude-agent-acp 0.81.2 | yes | yes |
| `codex` | codex-acp 2.2.2 | yes | no: the adapter refuses the whole session |
| `gemini` | gemini-cli 0.59.0, or the image's own (0.63.0 on Sprites) | yes | yes, after it tries HTTP first |

Use `type: http` for a server that every runtime must reach.

Gemini skips every MCP server, these included, in a folder it does not
trust, and newer releases turn folder trust on by default. Managoat sets
`GEMINI_CLI_TRUST_WORKSPACE=true` for the agent's own workspace, so its
servers start.

### Limits

A turn that is running during a deploy keeps the key its session started
with, because a running adapter cannot be given a new one. The stopping
server leaves that key valid, and the server that picks the turn up after
the deploy revokes it when the turn ends; if nothing picks the turn up, the
key stops working when it expires. The next turn opens a new session with
the current key, on every runtime
([#2835](https://github.com/managoat/managoat/issues/2835)).

If the conversation's server crashes during a turn, rather than stopping
cleanly, the key is revoked as it goes down. The turn is picked up again,
but its calls to your server get `401` until it ends.

## Every other server

Any server the runtime can launch will run, listed here or not. Whether it
is a good idea is between you and its author.

## Related

- [About agents](../../concepts/agent.md), where you declare `mcp_servers`.
- [Where a secret comes from](../../concepts/secrets.md).
