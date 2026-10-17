# Connect Linear to an agent

Many hosted MCP servers sign in with OAuth rather than an API key. Linear's
is one. A **connection** is your OAuth grant to one such server. You connect
it once, in a browser, and then any agent on your account can name it. This
page connects Linear's MCP server and gives it to an agent. Any server that
follows the MCP authorization spec works the same way.

Managoat never puts the token in the sandbox. The egress broker holds it and
adds it to the agent's requests to the server. The runtime sees an ordinary
HTTP MCP server with an `Authorization` header that holds a placeholder.

## Connect the server

Open **Connections** on `/account`, paste `https://mcp.linear.app/mcp` and
choose **Connect**. Managoat then does three things:

1. It asks the server where it signs in. It reads the server's
   protected-resource metadata, then that authorization server's metadata.
2. It registers itself as a client. Linear accepts Managoat's client ID
   metadata document, which is published at
   `<your instance>/connections/client.json`, so you register nothing.
3. It sends your browser to Linear to sign in and approve access.

Linear sends you back to `/connections/callback`, and the connection shows
as **connected**. Finish within ten minutes, in the browser you are signed in
to Managoat with. The callback only accepts the account that started the
sign-in, so nobody can hand you their grant, or take yours.

From the API, `POST /api/connections` does the same and returns the URL to
open. Open it in a browser signed in to Managoat as the same account:

```bash
curl -s "$MANAGOAT_BASE_URL/api/connections" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://mcp.linear.app/mcp"}'
```

```json
{
  "connection": {"id": "6f1c…", "status": "pending", "resource": "https://mcp.linear.app/mcp", "...": "..."},
  "authorize_url": "https://mcp.linear.app/authorize?…"
}
```

The TypeScript SDK has the same call as `managoat.connections.create({ url })`.

## Give it to an agent

Name the connection in the agent's `mcp_servers`, on an `http` entry whose
`url` is the connection's resource:

```yaml
mcp_servers:
  linear:
    type: http
    url: https://mcp.linear.app/mcp
    auth:
      connection: 6f1c…
```

Managoat refuses the agent if the connection is not yours, if the URL is not
the connection's resource (the same origin and path), or if the entry also
sets its own `Authorization` header.

## What happens on each turn

When a conversation starts, the entry reaches the runtime with
`Authorization: Bearer __managoat_connection_…__`. The broker replaces that
placeholder with the access token, and only on requests to the server's
host.

Before each turn, Managoat reads the stored token and refreshes it if it
expires within ten minutes. During a long turn a timer refreshes it ten
minutes before it expires and updates the broker, so the server does not
start refusing calls halfway through. A connection that no conversation uses
is not refreshed until its next turn.

## When a turn is refused

A turn fails with `409 connection_reconnect_required`, with the
`connection_id`, when the connection:

- is still **not finished** (you have not approved it yet),
- was **refused by provider** (the provider refused a refresh for good, for
  example because you revoked Managoat's access at Linear),
- has **expired** (the token lapsed and the provider issued no refresh
  token), or
- was deleted.

Choose **Reconnect** on `/account` (or `POST /api/connections/:id/authorize`)
and send the prompt again. Reconnecting keeps the same connection id, so no
agent changes. Managoat revokes the replaced grant at the provider.

## A server that lets no client register itself

Some providers, Google among them, accept neither a client ID metadata
document nor dynamic registration. Connecting then asks for a client.
Register an OAuth app with the provider, with
`<your instance>/connections/callback` as its redirect URI, and paste its
client ID and secret. Add any extra authorize parameters the provider needs,
one `name=value` per line. Google issues no refresh token without
`access_type=offline` and `prompt=consent`.

## Disconnect

**Disconnect** deletes the connection and then revokes the grant at the
provider, if the provider has a revocation endpoint. Deleting your account
does the same for every connection. Agents that still name it fail their
next turn with `connection_reconnect_required`.

## What Managoat will not connect

Every URL Managoat fetches while connecting must be `https` on a public
hostname. An IP address, `localhost`, an internal name, or a name that
resolves to a private, loopback, link-local or cloud metadata address is
refused, and Managoat follows no redirect. So an MCP server on a private
network cannot be connected. Bind a vault secret to it instead, as
[the MCP servers catalog](../catalog/mcp-servers/index.md#a-remote-server-with-an-api-key)
describes.

The token is kept from the sandbox, not from the server. The broker sends it
on every request to the server's host, so an endpoint on that host that
echoed the header back would hand it to the agent.

## Related

- [MCP servers](../catalog/mcp-servers/index.md)
- [Where a secret comes from](../concepts/secrets.md)
- [API reference: Connections](../api.md#connections)
