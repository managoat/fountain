# Managoat Account

The first-party account OAuth app. The dependency-free static source lives in
`apps/fountain/priv/account_app/` so the server release includes a working copy.
The app shares the console’s blue/neutral design tokens and logo directly from
`priv/static`; there is no separate color palette to maintain. Light/dark mode
follows the OS until chosen with the theme control.
No LiveView connection or server session is used by the app. Open `/account`
on your server to reach it.

The app manages API keys, registered OAuth apps, remote MCP connections,
inference credentials, secret bindings, password changes and account deletion.
ChatGPT subscription authentication remains a server-side flow at `/auth/chatgpt`.
Admin keys remain session-protected at `/admin/keys`; an ordinary OAuth token
cannot mint them.

## Separate hosting

From the repository root:

```bash
docker build -f account/Dockerfile -t managoat-account .
docker run --rm -p 8080:8080 managoat-account
```

Terminate HTTPS at your ingress and serve the container on your account hostname.
Set the **Managoat server's** `ACCOUNT_APP_URL=https://account.managoat.com/`
(or your own hostname). Restart the server. `/account` now redirects there with
its public server URL and the selected settings section. The reserved OAuth
client `managoat-account` and its CORS origin are registered automatically from
that setting. Do not add a second entry to `OAUTH_CLIENTS`.

An unset or empty `ACCOUNT_APP_URL` uses the bundled app at
`/account-app/index.html`. HTTPS is required except for local development on
localhost; PKCE uses Web Crypto. A separately hosted copy can be shared by
multiple servers, but each server must configure that copy's URL.

OAuth uses S256 PKCE, single-use state, a ten-minute callback window and the
existing expiring API keys. Tokens are kept in sessionStorage for this tab,
never localStorage or URLs. Sign out revokes the app token; it does not sign
out the authorization server. A failed revocation leaves the session available
for retry. A 401 or expired token asks the user to sign in again. API requests
omit cookies and reject redirects. Password changes invalidate server browser
sessions but preserve API keys, including this app's token.

The server retains ownership of remote MCP OAuth callbacks. The callback
returns to Connections with a success/failure indicator; no provider token or
error payload crosses to the account host.

## Checks

```bash
node --test account/test/*.test.mjs
node --check apps/fountain/priv/account_app/app.mjs
npm ci --prefix account
account/node_modules/.bin/playwright install chromium
npm --prefix account run test:browser
```

CI runs these OAuth tests with the TypeScript SDK job. Server controller tests
cover redirects, automatic client registration and the retained authentication
flows. The existing API tests cover tenant ownership, scope gates and mutations.
