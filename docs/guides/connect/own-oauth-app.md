# Connect a service with your own OAuth app

This guide shows you how to connect a service that Fountain has no OAuth
client for. You register an app at the service. Fountain runs the consent
flow with it, keeps the tokens, and the egress broker attaches the access
token to the agent's requests. The token never enters the sandbox. For the
model behind this, read [Connections](../../catalog/connections/index.md).

GitHub is the worked example. Notion and Linear work the same way, and the
console has a preset for each of the three. Google, Microsoft and Slack need
no app of yours: each is a
[platform provider](../../catalog/connections/index.md) with Fountain's own
client.

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

## 1. Register an OAuth app on GitHub

1. Open **Account, then Connections** in the console.
2. Click **Add an OAuth app** and pick the **GitHub** preset.
3. Copy the redirect URI the form shows. It has the shape
   `<PUBLIC_URL>/connections/<provider id>/callback`.
4. On GitHub, open **Settings, Developer settings, OAuth Apps** and register
   a new app.
5. Paste the redirect URI as the **Authorization callback URL**.
6. Copy the client id, and generate a client secret.

Fountain assigns the provider id when you save the form. The console shows
the exact redirect URI again after the save. If you registered the app
before the save, edit the app on GitHub and paste the final URI.

## 2. Add the provider in the console

The preset fills the endpoints. Paste the client id and the client secret,
then save.

| Field | GitHub preset | What it is for |
|---|---|---|
| Authorize URL | `https://github.com/login/oauth/authorize` | Where Fountain sends you for consent. |
| Token URL | `https://github.com/login/oauth/access_token` | Where Fountain exchanges the code and refreshes. |
| Revoke URL | blank | RFC 7009 revocation, if the service has it. Blank means a revoke is local only. |
| Userinfo URL | `https://api.github.com/user` | Where Fountain reads the account label. |
| Account label path | `login` | The JSON path into the userinfo response. |
| Scopes | `repo read:user` | What the consent asks for. |
| Token endpoint auth | `client_secret_post` | How the client authenticates at the token URL. The options are `client_secret_post`, `client_secret_basic` and `none`. |
| PKCE | off | S256 code challenge. Turn it on for a service that supports it. |
| Env key | `GITHUB_ACCESS_TOKEN` | The name the sandbox holds a placeholder under. Fountain derives it from the slug. |
| Token hosts | `api.github.com` | The hosts the broker attaches the token to. |

Fountain encrypts the client secret with your tenant key, like a vault
secret. The API and the console never show it again. A blank secret on an
edit keeps the stored one.

Every URL must be `https`, and it must name a public host. Fountain refuses
an IP literal, `localhost`, and a host that resolves to a private or
link-local address. A token host must be a hostname, and it cannot hold a
wildcard.

## 2b. Or add it with the API

The same provider, as one request.

```bash
curl -X POST "$FOUNTAIN_BASE_URL/api/connection-providers" \
  -H "Authorization: Bearer $FOUNTAIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "kind": "oauth2",
    "slug": "github",
    "name": "GitHub",
    "authorize_url": "https://github.com/login/oauth/authorize",
    "token_url": "https://github.com/login/oauth/access_token",
    "userinfo_url": "https://api.github.com/user",
    "account_label_path": "login",
    "scopes": ["repo", "read:user"],
    "client_id": "Iv1.0123456789abcdef",
    "client_secret": "...",
    "token_endpoint_auth": "client_secret_post",
    "pkce": false,
    "token_hosts": ["api.github.com"]
  }'
```

The response carries `redirect_uri` and `connect_url`. Register the first
one at GitHub. Open the second one in a browser to connect. The route needs
a key with full scope. Read
[Connection providers](../../api.md#connection-providers) in the API
reference.

## 3. Connect the account

1. On the Connections page, click **Connect** next to the GitHub provider.
2. Complete the GitHub consent screen.
3. Copy the connection id from the page.

Fountain reads the account label from the userinfo URL. The page then lists
the connection as `active`, with the GitHub login next to it.

## 4. Attach a GitHub MCP server that reads the token

An agent's `mcp_servers` can name a stdio server that runs in the sandbox.
The server reads `GITHUB_ACCESS_TOKEN` from its environment.

```json
{
  "mcp_servers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_ACCESS_TOKEN}" }
    }
  }
}
```

`GITHUB_ACCESS_TOKEN` is a synthetic secret. Fountain adds it to the merged
environment of every conversation of yours, while the connection is active.
You do not put it in an environment or a vault. Substitution resolves
`${GITHUB_ACCESS_TOKEN}` like any other name.

## What the broker does

The sandbox never holds the token. It holds the placeholder
`__github_access_token__`. The broker replaces the placeholder on each
request to a token host, `api.github.com` here, and sends the real token as
a bearer. A request to any other host keeps the placeholder.

You can bind the same name to a host of your own. Do it on
**Account, then Credential bindings**, and the broker sends the token there
instead. Read
[Bindings, when the broker is on](../../concepts/secrets.md#bindings-when-the-broker-is-on).

Fountain refreshes the token on the server, before it expires. It uploads the
new token to the broker at the start of the next turn. After the
conversation, `GET /api/conversations/:id/egress` lists each request that
left the sandbox, with the host and the credential the broker attached.

## When it stops

| The page says | What happened | What to do |
|---|---|---|
| `revoked` | The service refused the refresh, or you clicked **Revoke**. | Click **Connect** again. |
| `expired` | The service gave no refresh token, and the access token lapsed. | Click **Reconnect**. |

A GitHub OAuth app gives a token that does not expire, and no refresh token.
Fountain keeps it until you revoke. A service that gives an `expires_in` and
a refresh token gets refreshed. A service that rotates its refresh token on
each refresh gets the new one stored.

**Revoke** tells the service to forget the grant, at the revoke URL, when
the provider has one. With no revoke URL, Fountain forgets the token and the
service does not. Delete the grant on the service as well.

## Verify it worked

Start a conversation on the agent and ask it to list your repositories. The
transcript names the repositories. `GET /api/conversations/:id/egress` shows
requests to `api.github.com` with the `GITHUB_ACCESS_TOKEN` credential. A
`printenv` in the sandbox shows `__github_access_token__`, and not a token.

## Audit

Fountain records `connection_provider.created`, `connection_provider.updated`
and `connection_provider.deleted` with the slug and the kind. It records
`connection.created`, `connection.revoked` and `connection.expired` with the
provider, the scopes and the account label. No event holds a token or a
client secret.

## Related

- [Connect a remote MCP server](remote-mcp-server.md), for a server that
  implements MCP authorization.
- [Connections](../../catalog/connections/index.md), the catalog hub.
- [Where a secret comes from](../../concepts/secrets.md).
