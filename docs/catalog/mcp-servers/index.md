# MCP servers

An MCP server gives a runtime tools that it did not ship with. Fountain deals
with two kinds. They work differently enough to keep apart.

**Servers Fountain hosts.** Two of them, listed below. Nobody declares these
and no operator configures them. Fountain injects them into a conversation
when that conversation qualifies.

**Servers you declare.** Everything else, through the `mcp_servers` field on
an [Agent](../../concepts/agent.md). Fountain passes the declaration through.
For remote servers with OAuth discovery, it keeps the dated list below. The
authorization chain completed against each entry on the date shown.

## The two Fountain hosts

| Server | Injected when | Tools |
|---|---|---|
| [fountain-team](fountain-team.md) | The conversation is a teammate's. | `list_teammates`, `get_teammate`, `send_to_teammate`, `wait_for_teammate`, `read_teammate` |
| `fountain-buzz` | The conversation's vault holds a Buzz identity. | `buzz_send_message`, `buzz_react` |

Both share three properties, and each property carries weight.

**The sandbox never holds the credential.** That is the whole point.
`fountain-buzz` is the clearest case. Fountain holds the Buzz identity, and
the teammate reaches the network through tools alone. No key enters the
sandbox, so an agent that leaks its environment leaks nothing that can post.

**They authenticate with the token the sandbox already holds.** Fountain
serves each one over HTTP at a URL for that one conversation, and the sandbox
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

## Remote servers verified with discovery

Paste one of these URLs into **Connect a remote MCP server** on the
Connections page, or click its chip there, and the connection flow
completes. Read
[Connect a remote MCP server](../../guides/connect/remote-mcp-server.md)
for the flow itself.

| Server | URL | Client registration | Verified |
|---|---|---|---|
| [asana](asana.md) | `https://mcp.asana.com/sse` | Automatic. | 2026-09-01. |
| [cloudflare](cloudflare.md) | `https://mcp.cloudflare.com/mcp` | Automatic. | 2026-09-01. |
| [github](github.md) | `https://api.githubcopilot.com/mcp` | Your own app. | 2026-09-01. |
| [linear](linear.md) | `https://mcp.linear.app/mcp` | Automatic. | 2026-09-01. |
| [notion](notion.md) | `https://mcp.notion.com/mcp` | Automatic. | 2026-09-01. |
| [paypal](paypal.md) | `https://mcp.paypal.com/mcp` | Automatic. | 2026-09-01. |
| [sentry](sentry.md) | `https://mcp.sentry.dev/mcp` | Automatic. | 2026-09-01. |
| [square](square.md) | `https://mcp.squareup.com/sse` | Automatic. | 2026-09-01. |
| [stripe](stripe.md) | `https://mcp.stripe.com/mcp` | Automatic. | 2026-09-01. |
| [webflow](webflow.md) | `https://mcp.webflow.com/sse` | Automatic. | 2026-09-01. |

The same list reaches clients through the `mcp_servers` key of
`GET /api/catalog`, so an app on another origin renders it without
hard-coded URLs. Read [Catalog](../../api.md) in the API reference.

## What verified means

One checkable claim, and no more. The MCP authorization chain, which is
RFC 9728, then RFC 8414, then RFC 7591, completed against the URL on the
date shown. A script makes the claim, not a person. The probe script,
`scripts/mcp-catalog-probe.exs` in the repository, walks the chain with
the same code the console uses. A green run is what re-dates an entry.

The list is a menu, not a gate. Paste any URL and Fountain runs the same
discovery. An entry here saves you the guess, and nothing more.

The claim stops at authorization. Fountain does not verify the tools a
server offers, and it does not endorse the server. **Automatic** in the
table means the server's authorization server registers a client for
Fountain, so you type no credentials. **Your own app** means you paste a
client id from an app registration of your own.

## Every other server

Any server the runtime can launch will run, listed here or not. Whether it
is a good idea is between you and its author.

## Related

- [About agents](../../concepts/agent.md), where you declare `mcp_servers`.
- [Agents as teammates](../../concepts/teammates.md), which
  [fountain-team](fountain-team.md) serves.
- [Where a secret comes from](../../concepts/secrets.md).
