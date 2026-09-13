# microsoft (connection)

> A platform provider. The operator registers one Microsoft Entra app, and
> every tenant connects a Microsoft account with it. One sign-in covers
> Outlook mail, calendar and Teams chat, all on the Graph API.

## Summary

| | |
|---|---|
| Id | `microsoft`. |
| Kind | `oauth2`, platform. It has no row, and `platform: true` in the API. |
| Configured by | The operator, with `MICROSOFT_OAUTH_CLIENT_ID` and `MICROSOFT_OAUTH_CLIENT_SECRET`. |
| Scopes | `openid`, `email`, `offline_access`, `User.Read`, `Mail.ReadWrite`, `Mail.Send`, `Calendars.ReadWrite`, `Chat.ReadWrite`. `MICROSOFT_OAUTH_SCOPES` overrides the list. |
| Env key | `MICROSOFT_ACCESS_TOKEN`. A second account takes `MICROSOFT_ACCESS_TOKEN_2`. |
| Token hosts | `graph.microsoft.com`. |
| Redirect URI | `<PUBLIC_URL>/connections/microsoft/callback`. |
| Account label | The user principal name, from the Graph `/v1.0/me` endpoint. |
| Status | Beta. Only on a deployment that runs the egress broker. Read [Feature status](../../reference/feature-status.md). |

## Configure it

Register a web app in Microsoft Entra with the redirect URI above, on the
`common` endpoint, so work and personal accounts both sign in. Set
`MICROSOFT_OAUTH_CLIENT_ID` and `MICROSOFT_OAUTH_CLIENT_SECRET` on the
instance. Unset, the Connections page says the provider is not configured.
Read [`MICROSOFT_OAUTH_CLIENT_ID`](../../configuration.md#authentication).

Keep `offline_access` in the scope list. Without it, Microsoft issues no
refresh token, and the connection expires with the first access token.

The default list stops at chats (`Chat.ReadWrite`). The Teams channel
scope, `ChannelMessage.Send`, needs admin consent on work tenants. Add it
with `MICROSOFT_OAUTH_SCOPES` if your audience accepts that consent screen.

## Endpoints

| | |
|---|---|
| Authorize | `https://login.microsoftonline.com/common/oauth2/v2.0/authorize`. |
| Token | `https://login.microsoftonline.com/common/oauth2/v2.0/token`. |
| Revoke | None. Microsoft publishes no OAuth revocation endpoint, so revoke is local only. |
| Userinfo | `https://graph.microsoft.com/v1.0/me`, path `userPrincipalName`. |
| Token endpoint auth | `client_secret_post`. |
| PKCE | On. |

A tenant cannot edit these, and `microsoft` is a reserved slug. `PATCH` and
`DELETE` on `/api/connection-providers/microsoft` answer 404.

## Connect an account

1. Open **Account, then Connections** in the console.
2. Click **Connect** next to Microsoft and complete the consent screen.
3. Copy the connection id from the page.

## Use it

The broker holds the token, and the sandbox holds the placeholder
`__microsoft_access_token__`. The broker attaches the real token as a
bearer on requests to `graph.microsoft.com`. An MCP server you run in the
sandbox reads `MICROSOFT_ACCESS_TOKEN` from its environment, or the agent
calls the Graph API with it. There is no Fountain-served tool server for
Microsoft. Read [Connections](index.md).

Mail, calendar and chat all answer on the Graph API, under `/v1.0/me`.
The granted scopes on the connection say which products you consented to.

## Token expiry

A Graph access token lasts about one hour. Fountain refreshes it on the
server near expiry, with the refresh token `offline_access` grants.
Microsoft rotates the refresh token, and Fountain stores each new one.
**Revoke** sets the connection to `revoked` in Fountain. To cut the grant
at Microsoft, remove the app from the account's app permissions.

## Related

- [Connections](index.md), the catalog hub.
- [Google](google.md) and [Slack](slack.md), the other platform providers.
- [Connect a service with your own OAuth app](../../guides/connect/own-oauth-app.md),
  for every other service.
