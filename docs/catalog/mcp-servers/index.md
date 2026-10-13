# MCP servers

An MCP server gives a runtime tools that it did not ship with. Fountain deals
with two kinds. They work differently enough to keep apart.

**Servers Fountain hosts.** One of them, listed below. Nobody declares these
and no operator configures them. Fountain injects them into a conversation
when that conversation qualifies.

**Servers you declare.** Everything else, through the `mcp_servers` field on
an [Agent](../../concepts/agent.md). Fountain passes the declaration through.

## The Fountain host

| Server | Injected when | Tools |
|---|---|---|
| [fountain-team](fountain-team.md) | The conversation is a teammate's. | `list_teammates`, `get_teammate`, `send_to_teammate`, `wait_for_teammate`, `read_teammate` |

It has three properties, and each property carries weight.

**The sandbox never holds an API key.** The teammate reaches its teammates
through tools alone. No key enters the sandbox, so an agent that leaks its
environment leaks nothing that can call the API.

**It authenticates with the token the sandbox already holds.** Fountain
serves it over HTTP at a URL for that one conversation, and the sandbox
presents its own callback token. There is no second credential to manage, and
the token reaches only that conversation's owner.

**Fountain recomputes the injection at each turn.** A capability granted
mid-session appears on the next turn, and not at the next provision. Add an
agent to the team while it works, and it can message its teammates on its
next reply. Read [Team](../../api.md#team).

Fountain scopes each call to one tenant. A message that goes through a tool
lands in the thread of the teammate who gets it. It lands exactly as a message
typed on the team page does, and it names the sender.

## How to declare your own

`mcp_servers` on an Agent takes a map of server definitions. Their `env` takes
`${VAR}` substitution, which Fountain resolves from the merged environment and
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

Note how that differs from the hosted servers above. A server you declare runs
**in** the sandbox, and it holds a real credential there. A server Fountain
hosts runs outside the sandbox and holds nothing there.

### One runtime does this differently

On `claude`, an upstream defect breaks session-scoped MCP delivery. So
Fountain provisions `.mcp.json` into the sandbox and starts the project
servers, and it does not pass them for each session. The effect is the same.
The mechanism matters only when you debug why a raw ACP probe behaves one way
and Fountain behaves another. Read [claude](../runtimes/claude.md).

## A remote server

A remote server is declared the same way, with a `url` and the headers it
needs. A bearer comes from a vault through `${VAR}`, and the sandbox holds
it in the clear: the broker carries only the GitHub and inference
credentials. Read
[What the broker holds](../../concepts/secrets.md#what-the-broker-holds).

```yaml
mcp_servers:
  linear:
    type: http
    url: https://mcp.linear.app/mcp
    headers:
      Authorization: "Bearer ${LINEAR_TOKEN}"
```

Fountain runs no OAuth flow for a remote server. Bring a token the service
issues, an API key or a personal access token.

## Every other server

Any server the runtime can launch will run, listed here or not. Whether it
is a good idea is between you and its author.

## Related

- [About agents](../../concepts/agent.md), where you declare `mcp_servers`.
- [Agents as teammates](../../concepts/teammates.md), which
  [fountain-team](fountain-team.md) serves.
- [Where a secret comes from](../../concepts/secrets.md).
