# slack (connection)

> A platform provider. The operator registers one Slack app, and every
> tenant connects a workspace with it. The connection holds a user token,
> so an agent acts as the connected person, not as a bot.

## Summary

| | |
|---|---|
| Id | `slack`. |
| Kind | `oauth2`, platform. It has no row, and `platform: true` in the API. |
| Configured by | The operator, with `SLACK_OAUTH_CLIENT_ID` and `SLACK_OAUTH_CLIENT_SECRET`. |
| Scopes | `channels:history`, `channels:read`, `chat:write`, `im:history`, `im:write`, `users:read`, `search:read`. `SLACK_OAUTH_USER_SCOPES` overrides the list. |
| Env key | `SLACK_ACCESS_TOKEN`. A second account takes `SLACK_ACCESS_TOKEN_2`. |
| Token hosts | `slack.com`. |
| Redirect URI | `<PUBLIC_URL>/connections/slack/callback`. |
| Account label | The Slack handle, from `auth.test`. |
| Status | Beta. Only on a deployment that runs the egress broker. Read [Feature status](../../reference/feature-status.md). |

## Configure it

Create a Slack app with the redirect URL above. Set `SLACK_OAUTH_CLIENT_ID`
and `SLACK_OAUTH_CLIENT_SECRET` on the instance. Unset, the Connections
page says the provider is not configured. Read
[`SLACK_OAUTH_CLIENT_ID`](../../configuration.md#authentication).

The scopes are **user scopes**, not bot scopes. Fountain sends them in
Slack's `user_scope` parameter, and the token that comes back is the
person's own. List the same names under *User Token Scopes* in the Slack
app configuration.

## Endpoints

| | |
|---|---|
| Authorize | `https://slack.com/oauth/v2/authorize`. |
| Token | `https://slack.com/api/oauth.v2.access`. |
| Revoke | `https://slack.com/api/auth.revoke`. |
| Userinfo | `https://slack.com/api/auth.test`, path `user`. |
| Token endpoint auth | `client_secret_post`. |
| PKCE | Off. |

A tenant cannot edit these, and `slack` is a reserved slug. `PATCH` and
`DELETE` on `/api/connection-providers/slack` answer 404.

## Connect a workspace

1. Open **Account, then Connections** in the console.
2. Click **Connect** next to Slack, pick the workspace, and approve.
3. Copy the connection id from the page.

One connection covers one workspace. Connect again from another workspace
for a second token. The label is the Slack handle, so two workspaces with
the same handle replace each other. Reconnect the one you need.

## Use it

The broker holds the token, and the sandbox holds the placeholder
`__slack_access_token__`. The broker attaches the real token as a bearer on
requests to `slack.com`. An MCP server you run in the sandbox reads
`SLACK_ACCESS_TOKEN` from its environment, or the agent calls the Slack Web
API with it. There is no Fountain-served tool server for Slack. Read
[Connections](index.md).

## Token expiry

A Slack user token does not expire, and Slack issues no refresh token
unless the app opts in to rotation. The connection stays `active` until you
revoke it, or until Slack refuses the token. **Revoke** tells Slack to
forget the token, through `auth.revoke`.

## Related

- [Connections](index.md), the catalog hub.
- [Google](google.md) and [Microsoft](microsoft.md), the other platform providers.
- [Connect a service with your own OAuth app](../../guides/connect/own-oauth-app.md),
  for every other service.
