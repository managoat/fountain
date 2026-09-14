# Connections

A connection is a provider account you signed in to once, whose tokens
Fountain holds. Fountain encrypts the refresh token with your tenant key,
like a vault secret. An agent gets the capability, and never the credential.

A **connection provider** says where a connection's tokens come from. It
holds the OAuth client, the endpoints, the scopes, and the hosts the token
goes to.

!!! note "Connections"

    Connections and credential binding management also need the `connections`
    feature flag. On your own instance, add `connections` to `FEATURE_FLAGS_ON`
    after configuring the broker and provider apps. Hosted accounts are enrolled
    separately; see [feature status](../../reference/feature-status.md).
    Connections exist only on a deployment that runs the egress broker
    (ADR 0019). Without the broker, a token would have to enter the sandbox
    in the clear, so the page and the routes are absent. The broker is on for
    every account on the hosted platform. On your own instance, read
    [Feature status](../../reference/feature-status.md).

## Platform and tenant providers

| | Platform | Tenant |
|---|---|---|
| Who owns the OAuth client. | The operator of the instance. | You. |
| Where you define it. | Instance configuration. | The Connections page, or `POST /api/connection-providers`. |
| Which exist. | Google, Microsoft and Slack, when the instance installs the `fountain_google`, `fountain_microsoft` and `fountain_slack` extensions; the slug is the id. A core distribution lists none. | As many as you define. |

Fountain owns an OAuth client for each platform provider. It cannot own an
app at every service, and a restricted scope needs verification of each app
anyway. So every other service is a tenant provider.

One platform connection covers several products. The Google account carries
Gmail and Calendar. The Microsoft account carries Outlook mail, calendar
and Teams chat. The granted scopes on a connection say which products you
consented to.

## The two kinds of tenant provider

| Kind | You give Fountain | Fountain learns the endpoints from | Guide |
|---|---|---|---|
| `oauth2` | Your app registration at the service. The client id and secret, the scopes, and the token hosts. | You. The console has presets for GitHub, Slack, Notion and Linear. | [Connect a service with your own OAuth app](../../guides/connect/own-oauth-app.md). |
| `mcp` | The URL of a remote MCP server. | Discovery, from the server's metadata. Fountain registers a client there when it can. | [Connect a remote MCP server](../../guides/connect/remote-mcp-server.md). |

Both kinds share one connection model. Each provider has an env key, such
as `GITHUB_ACCESS_TOKEN`, and a list of token hosts. Fountain derives the
env key from the slug. A second account on the same provider takes the next
numbered key, `GITHUB_ACCESS_TOKEN_2`.

## How an agent uses a connection

The sandbox holds a placeholder for the env key, `__github_access_token__`
for `GITHUB_ACCESS_TOKEN`. The broker replaces it with the real token on a
request to a token host. Three shapes use that.

**A stdio server in the sandbox.** The server reads the env key from its
environment, as it would read a personal access token. The value it reads is
the placeholder.

```json
{ "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
              "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_ACCESS_TOKEN}" } } }
```

A Node server needs one more variable. The built-in `fetch` in Node ignores
`HTTP_PROXY` and `HTTPS_PROXY`. Its requests do not reach the broker, so the
broker never replaces the placeholder. The server fails with `fetch failed`.
Set `NODE_USE_ENV_PROXY` to `1` in the same `env` block. A Python server
obeys the proxy variables and needs no change.

```json
{ "slack": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-slack"],
             "env": { "SLACK_BOT_TOKEN": "${SLACK_ACCESS_TOKEN}",
                      "NODE_USE_ENV_PROXY": "1" } } }
```

**A remote MCP server.** The entry names a URL and a connection. At spawn it
gets a placeholder bearer, and the broker attaches the token to that host.

```json
{ "linear": { "type": "http", "url": "https://mcp.linear.app/mcp", "connection": "<id>" } }
```

**A server an extension hosts.** Only for Google today. The entry names the
connection alone, and the token stays on the server. The Google extension,
part of the standard distribution, serves it. Its page is `fountain-gmail` in
the Catalog section of this manual.

## Status

| Status | Meaning |
|---|---|
| `active` | Fountain can get an access token. |
| `revoked` | The provider refused the refresh, or you revoked. Connect again to replace it. |
| `expired` | The provider gave no refresh token, and the access token lapsed. Reconnect to replace it. |

Fountain refreshes a token on the server before it expires. A response with
no `expires_in` means the token does not expire. A response with a new
refresh token replaces the stored one.

## Entries

- Google, a platform provider from the `fountain_google` extension. Gmail and Calendar. Its page, `google (connection)`, is in this section when the extension is installed.
- Microsoft, a platform provider from the `fountain_microsoft` extension. Outlook mail, calendar and Teams chat. Its page, `microsoft (connection)`, is in this section when the extension is installed.
- Slack, a platform provider from the `fountain_slack` extension. A user token per workspace. Its page, `slack (connection)`, is in this section when the extension is installed.
