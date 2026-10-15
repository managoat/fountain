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
and Managoat behaves another. Read [claude](../runtimes/claude.md).

## A remote server

A remote server is declared the same way, with a `url` and the headers it
needs. A bearer comes from a vault through `${VAR}`; bind that secret to the
server's host and the sandbox holds only a placeholder. Read
[Bindings](../../concepts/secrets.md#bindings).

```yaml
mcp_servers:
  linear:
    type: http
    url: https://mcp.linear.app/mcp
    headers:
      Authorization: "Bearer ${LINEAR_TOKEN}"
```

Managoat runs no OAuth flow for a remote server. Bring a token the service
issues, an API key or a personal access token.

## Every other server

Any server the runtime can launch will run, listed here or not. Whether it
is a good idea is between you and its author.

## Related

- [About agents](../../concepts/agent.md), where you declare `mcp_servers`.
- [Where a secret comes from](../../concepts/secrets.md).
