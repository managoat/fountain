# Connect a remote MCP server

This guide shows you how to connect a remote MCP server that implements the
MCP authorization specification. You enter one URL. Fountain finds the
server's authorization server, registers a client there, and runs the
consent flow. You type no client id. For the model behind this, read
[Connections](../../catalog/connections/index.md).

For a service with a classic OAuth app, read
[Connect a service with your own OAuth app](own-oauth-app.md).

!!! note "Connections"

    Connections and credential binding management also need the `connections`
    feature flag. On your own instance, add `connections` to `FEATURE_FLAGS_ON`
    after configuring the broker and provider apps. Hosted accounts are enrolled
    separately; see [feature status](../../reference/feature-status.md).
    Connections exist only on a deployment that runs the egress broker
    (ADR 0019). On other accounts the Connections page and the routes are
    absent. The broker is on for every account on the hosted platform. On
    your own instance, read
    [Feature status](../../reference/feature-status.md).

## 1. Enter the server URL

1. Open **Account, then Connections** in the console.
2. Under **Connect a remote MCP server**, paste the server URL, for example
   `https://mcp.linear.app/mcp`. Or click one of the **Verified** chips,
   and the URL appears. The chips come from the
   [verified list](../../catalog/mcp-servers/index.md#what-verified-means).
3. Click **Discover**.

The page reports the authorization server it found. With client
registration, it says `Found <issuer> behind <name> and registered a
client. Connect it below.`

The URL must be `https`, and it must name a public host. Fountain refuses an
IP literal, `localhost`, and a host that resolves to a private or link-local
address. It applies the same rule to every URL the server sends back.

## What discovery does

Fountain walks the chain the MCP authorization specification defines.

1. It sends a `GET` to the server URL with no credential. A server that obeys the specification
   answers `401` with `WWW-Authenticate: Bearer resource_metadata="..."`.
2. It reads the protected-resource metadata at that URL (RFC 9728). When the server
   names none, Fountain tries `/.well-known/oauth-protected-resource` plus
   the path, then the origin's document.
3. It takes the first entry of `authorization_servers` as the issuer.
4. It reads the issuer's metadata (RFC 8414) at
   `/.well-known/oauth-authorization-server`, with OpenID discovery as the
   fallback. This gives the authorize, token, revocation and registration
   endpoints.
5. With a `registration_endpoint`, it registers a client there (RFC 7591).
   The redirect URI is `<PUBLIC_URL>/connections/<provider id>/callback`.

Each fetch has a timeout. The chain follows no redirects. Fountain stores
the endpoints and the raw metadata on the provider. The consent flow uses
PKCE with S256, and it sends the `resource` parameter (RFC 8707) so the
token binds to the server you named.

The authorization server chooses the client's auth method. A public client
comes back with no secret and `token_endpoint_auth: none`. Each provider
registers its own client, because a registration names one callback URL and
each provider has its own.

## 2. Connect

1. Click **Connect** next to the new provider.
2. Complete the consent screen of the authorization server.
3. Copy the connection id from the page.

The provider has no userinfo URL, so the page names the account after the
server.

## 3. Attach the server to an agent

Name the server by URL and connection in the agent's `mcp_servers`. The key
is the server name the agent sees.

```json
{
  "mcp_servers": {
    "linear": {
      "type": "http",
      "url": "https://mcp.linear.app/mcp",
      "connection": "3f6c1a2e-2b0e-4f8a-9d5b-7c1e2a9f0b44"
    }
  }
}
```

In the agent form, pick the **Connected account** server type, choose the
connection, and put the URL in **Remote server URL**.

At spawn, Fountain drops the `connection` key. It adds
`Authorization: Bearer __<env key lowercase>__` to the entry, with the env
key of the connection. The runtime sees a normal remote server with a
bearer header. A header you set yourself stays as it is.

## What the broker does

The bearer in the sandbox is a placeholder. The broker replaces it on each
request to the host of the server URL, `mcp.linear.app` here, and to no
other host. Fountain adds that host to the token hosts of the
connection's env key, next to the provider's own.

After the conversation, `GET /api/conversations/:id/egress` lists what left
the sandbox. Requests to the server host show the credential the broker
attached. Requests to other hosts show none.

Fountain refreshes the token on the server, before it expires. It uploads the
new token to the broker at the start of the next turn. Fountain drops an entry
whose connection is not active at spawn, and the agent runs without that
server.

## When the server offers no client registration

The page says `Found <issuer> behind <name>, but it offers no client
registration.` Register a client in the developer console of the service,
with the redirect URI the provider shows. Then edit the provider and paste
the client id and the client secret. A public client takes
`token_endpoint_auth: none` and no secret.

The same request with the API.

```bash
curl -X POST "$FOUNTAIN_BASE_URL/api/connection-providers" \
  -H "Authorization: Bearer $FOUNTAIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "kind": "mcp",
    "mcp_url": "https://mcp.example.com/mcp",
    "client_id": "...",
    "client_secret": "..."
  }'
```

With only `mcp_url` in the body, Fountain runs discovery and registration.
A discovery failure answers `422` with `error: discovery_failed` and a
`detail` in words. Read
[Connection providers](../../api.md#connection-providers) in the API
reference.

## Re-discover

A server can move its authorization server, or rotate its endpoints. Click
**Re-discover** on the provider, or call
`POST /api/connection-providers/:id/discover`. Fountain fetches the chain
again and updates the endpoints. It keeps the registered client while the
server names the same issuer.

## When it stops

| The page says | What happened | What to do |
|---|---|---|
| `revoked` | The authorization server refused the refresh, or you clicked **Revoke**. | Click **Connect** again. |
| `expired` | The server gave no refresh token, and the access token lapsed. | Click **Reconnect**. |

**Revoke** sends an RFC 7009 request to the revocation endpoint, when the
metadata has one. With none, Fountain forgets the token and the server does
not.

## Verify it worked

Start a conversation on the agent and ask it to call a tool on the server.
The transcript shows the tool result. `GET /api/conversations/:id/egress`
shows requests to the server host with the connection's credential, and no
other host with it.

## Related

- [Connect a service with your own OAuth app](own-oauth-app.md).
- [Connections](../../catalog/connections/index.md), the catalog hub.
- [MCP servers](../../catalog/mcp-servers/index.md), for the servers
  Fountain hosts and the verified remote servers.
