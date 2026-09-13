# google (connection)

> A platform provider. The operator registers a Google Cloud client
> once, and every tenant connects a Google account with it. One sign-in
> covers Gmail and Google Calendar.

## Summary

| | |
|---|---|
| Id | `google`. |
| Kind | `oauth2`, platform. It has no row, and `platform: true` in the API. |
| Configured by | The operator, with `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET`. |
| Scopes | `openid`, `email`, `https://www.googleapis.com/auth/gmail.modify`, `https://www.googleapis.com/auth/calendar`. `GOOGLE_OAUTH_SCOPES` overrides the list. |
| Env key | `GOOGLE_ACCESS_TOKEN`. A second account takes `GOOGLE_ACCESS_TOKEN_2`. |
| Token hosts | `gmail.googleapis.com`, `www.googleapis.com`. |
| Redirect URI | `<PUBLIC_URL>/connections/google/callback`. |
| Account label | The email address, from the OpenID userinfo endpoint. |
| Status | Beta. Only on a deployment that runs the egress broker. Read [Feature status](../../reference/feature-status.md). |

## Configure it

Register a Web client in Google Cloud with the redirect URI above, and
enable the Gmail and Calendar APIs. Set `GOOGLE_OAUTH_CLIENT_ID` and
`GOOGLE_OAUTH_CLIENT_SECRET` on the instance. Unset, the Connections page
says the feature is not configured. Read
[`GOOGLE_OAUTH_CLIENT_ID`](../../configuration.md#authentication).

Google names `gmail.modify` a restricted scope, and `calendar` a sensitive
one. An unverified Google app serves its test users only, so a self-hosted
instance adds each account to the test users of its Google Cloud project.
If your app verification does not cover a scope, remove it with
`GOOGLE_OAUTH_SCOPES`. A scope you do not request is a product that does
not light up, not an error.

Fountain sends `include_granted_scopes=true`, so consent is incremental.
When the operator adds a scope, a connection keeps its old grants, and the
tenant connects again to add the new one.

Fountain sends `access_type=offline` and `prompt=consent` on every
authorize URL. Without the two, Google returns no refresh token on a second
consent, and a connection with no refresh token would expire in an hour.

## Endpoints

| | |
|---|---|
| Authorize | `https://accounts.google.com/o/oauth2/v2/auth`. |
| Token | `https://oauth2.googleapis.com/token`. |
| Revoke | `https://oauth2.googleapis.com/revoke`. |
| Userinfo | `https://openidconnect.googleapis.com/v1/userinfo`, path `email`. |
| Token endpoint auth | `client_secret_post`. |
| PKCE | Off. |

A tenant cannot edit these, and `google` is a reserved slug. `PATCH` and
`DELETE` on `/api/connection-providers/google` answer 404.

## Connect an account

1. Open **Account, then Connections** in the console.
2. Click **Connect** next to Google and complete the consent screen.
3. Copy the connection id from the page.

## Use it

Two shapes use a Google connection.

**The Fountain-served Gmail server.** The agent's `mcp_servers` names the
connection alone. The token stays on the server. Read
[fountain-gmail](../mcp-servers/fountain-gmail.md).

**A brokered token.** The sandbox holds `__google_access_token__`, and the
broker attaches the real token as a bearer on requests to the token hosts.
An MCP server you run in the sandbox reads `GOOGLE_ACCESS_TOKEN` from its
environment. The Calendar API lives on `www.googleapis.com`, which the
token hosts cover, so a calendar call works the same way. Read
[Connections](index.md).

## Token expiry

A Google access token lasts one hour. Fountain refreshes it on the server
near expiry, and uploads the new token to the broker at the start of the
next turn. **Revoke** tells Google to forget the grant.

## Related

- [Connections](index.md), the catalog hub.
- [fountain-gmail](../mcp-servers/fountain-gmail.md).
- [Connect a service with your own OAuth app](../../guides/connect/own-oauth-app.md),
  for every other service.
