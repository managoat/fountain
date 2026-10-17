---
type: ADR
title: "Connections come back as a user's OAuth grant to one remote MCP server, delivered through the broker"
description: "Built (#2831, #2832, #2833): a connection is a user's OAuth grant to one remote MCP server, discovered by the MCP authorization spec, used only through the broker and revoked when Managoat lets go of it."
tags: [connections, oauth, mcp, egress, security]
status: stable
adr: "0085"
adr_status: "Accepted"
date: 2026-10-15
---

# 0085 — Connections: OAuth-connected remote MCP servers, delivered through the broker

**Status:** Accepted, 2026-10-15. Decided by Jake. Built by #2831 (the
OAuth client, the table, the context and the API), #2832 (agent entries and
delivery through the broker) and #2833 (the `/account` section and the
manual), with the departures in the addendum of 2026-10-15 below.
The OAuth client is folded into the server from `managoat_mcp_auth`
(decision 11, from the #2746 spike).

## Context

[0033](0033-connections-platform-and-tenant-providers.md) built Connections
for a hosted service: three platform providers with Managoat's own OAuth
apps, tenant-defined generic OAuth providers, MCP discovery for remote
servers, extensions that contributed providers
([0054](0054-extensions-contribute-connection-providers.md)) and a verified
server catalog. The hosted instance held four connections in thirty days, and
#2617 removed all of it on 2026-10-12. The `connections` and
`connection_providers` tables were dropped by a later migration
(`20261012200000`).

Since then a remote MCP server can only be given a bearer from a vault
secret, through `${VAR}` and a binding on its host. That works for a static
API key. It does not work for a server that wants OAuth, which is now most
hosted MCP servers: the user has no token to paste, and if they did, it would
expire within hours and nothing would refresh it.

Two things changed since 0033. Brokerage is unconditional
([0019](0019-egress-credential-brokerage.md), since v0.29.0), so there is no
unbrokered arm to design for. And the ChatGPT subscription
([0070](0070-one-chatgpt-subscription-per-user.md), with its 2026-10-15
addenda) already does the hard part of holding a user's OAuth tokens: a
refresh under a row lease with the network call outside any transaction, a
compare-and-swap write-back, `revoked` on a terminal refusal, and revocation
at the provider when Managoat lets go.

The first target is Linear (`https://mcp.linear.app/mcp`). Checked on
2026-10-15: an unauthenticated `POST` answers `401` with
`WWW-Authenticate: Bearer resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp"`;
that document names `https://mcp.linear.app/mcp` as the resource and
`https://mcp.linear.app` as its authorization server; and the server's RFC
8414 metadata advertises `client_id_metadata_document_supported: true`, a
`registration_endpoint`, the `refresh_token` grant, a `revocation_endpoint`,
`S256` and `authorization_response_iss_parameter_supported`.

## Decision

1. **One kind of connection.** A connection is one user's OAuth grant to one
   remote MCP server, identified by the server's URL (its resource). There is
   no platform provider registry, no extension that contributes providers,
   and no generic OAuth provider. A new `connections` table holds the rows,
   each scoped by `user_id`; every user-facing read and write takes the
   signed-in user's id. Tokens, a pasted client secret and the PKCE verifier
   are encrypted under the user's DEK with an AAD naming the user, the row and
   the field, as vault secrets and the ChatGPT subscription are. Status is
   `pending` (created, consent not finished), `active`, `revoked` (the
   provider refused a refresh for good) or `expired` (the access token lapsed
   and there is no refresh token to renew it).

2. **Discovery** follows the MCP authorization spec. Managoat requests the
   server URL without a token and reads `resource_metadata` from the `401`'s
   `WWW-Authenticate`; failing that, the path-specific
   `/.well-known/oauth-protected-resource/<path>`; failing that, the origin's.
   From the protected-resource metadata it takes the authorization server and
   reads its RFC 8414 metadata, with OpenID Connect discovery as the fallback.
   The resource the metadata names becomes the connection's resource.

3. **Every URL fetched server-side is guarded.** https only; no IP literals;
   no host that resolves to a loopback, private, link-local, CGNAT or cloud
   metadata address; the connection is made to the address that was checked;
   redirects are not followed; responses are size-capped. URLs that come back
   inside metadata (authorization, token, registration, revocation and JWKS
   endpoints, the authorization servers listed) are checked by the same rules
   before use.

4. **Client registration** has three paths, all in the first release, tried
   in this order:
   - **Client ID metadata document**, when the authorization server
     advertises `client_id_metadata_document_supported`. Managoat publishes
     its client metadata at `<PUBLIC_URL>/connections/client.json` and uses
     that URL as the client ID. (`/oauth/<x>` is taken by the sign-in
     providers' `/oauth/:provider` route.)
   - **RFC 7591 dynamic registration**, when there is a
     `registration_endpoint`. The issued client is stored on the connection.
   - **A pasted client** otherwise: the user pastes a client ID and secret
     from an app they registered with the provider, plus optional extra
     authorize parameters. For Google these are `access_type=offline` and
     `prompt=consent`, without which Google issues no refresh token.

5. **Login** is the authorization-code flow with PKCE `S256` and the RFC 8707
   `resource` parameter on both the authorize and token requests. The
   redirect URI is `<PUBLIC_URL>/connections/callback`, one for every
   connection (see the addendum of 2026-10-15). `state` is signed,
   short-lived and names the connection and its user. The callback serves
   only a signed-in browser session whose user owns the pending connection; a
   signed-out browser goes through login first. Otherwise a person could be
   tricked into finishing someone else's consent and handing their grant to
   that account. Where the server advertises
   `authorization_response_iss_parameter_supported`, the callback checks
   `iss` (RFC 9207).

6. **Tokens are held the way the ChatGPT subscription holds them.** A refresh
   takes a short lease on the row by one conditional `UPDATE`, calls the
   token endpoint with no transaction open, and writes the rotated pair back
   by compare-and-swap on the lease and the spent refresh token, retrying the
   write. A refusal the provider names as terminal (`invalid_grant`) marks
   the connection `revoked`. Managoat revokes the token at the provider's
   `revocation_endpoint`, when there is one, whenever it lets go of it:
   disconnect, a relink that replaces it, a refresh a relink overtook, and
   account deletion. The call runs after the local write has committed,
   outside any transaction or lock, and its failure never undoes that write.

7. **An agent names a connection in `mcp_servers`:**

   ```json
   {"linear": {"type": "http", "url": "https://mcp.linear.app/mcp", "auth": {"connection": "<id>"}}}
   ```

   The agent changeset refuses an entry whose connection is not the agent
   owner's, or whose URL is not the connection's resource (same origin and
   path). The `auth` key also takes `"auth": "conversation"`, the
   conversation's own callback bearer ([0086](0086-mcp-servers-authenticated-as-the-conversation.md)). The old
   `"connection"` key stays refused.

8. **Delivery is through the broker only.** When a session is built, the
   entry is given an `Authorization: Bearer <placeholder>` header and the
   access token becomes a synthetic brokered secret, under a reserved key no
   tenant secret can take, with an implicit bearer binding to the server
   URL's host and no other. The real token never enters the sandbox, the
   agent record, the transcript or a log. Every runtime sees an ordinary HTTP
   MCP server with a header. A connection that is `pending`, `revoked`,
   `expired` or deleted fails the turn with `409
   connection_reconnect_required`, naming the connection.

9. **Refresh before each turn and during long ones.** Before each turn
   (`Egress.refresh_before_turn/1`) Managoat re-reads each named connection's
   token and refreshes it if it expires within ten minutes. During a turn a
   timer per conversation fires ten minutes before the earliest expiry,
   refreshes, and calls `Egress.refresh_live/1` to rewrite the live broker
   rules, because access tokens can be short-lived (Google's last an hour)
   and a turn can outlast one. There is no daily keepalive: a connection no
   conversation uses is refreshed at its next turn.

   The conversation's server never calls the token endpoint itself. It reads
   the stored tokens, exchanges the due ones in tasks, all at once, and waits
   for them for at most five seconds (`:connection_refresh_wait_ms`). A
   refresh still running after that finishes in its task and messages the
   server, which then rewrites the live rules. Meanwhile the turn carries
   the stored token, which is usually still valid because a refresh falls
   due ten minutes before expiry. A slow provider therefore delays a turn by
   that wait at most, and never pushes the server's other calls past their
   timeout.

10. **Surface.** A Connections section on the one `/account` page: connect
    (paste the server URL, and a client when asked), reconnect, disconnect.
    `/api/connections` for Arugula and the SDK: list; create from a URL,
    which runs discovery and registration and returns the authorize URL to
    open; get; delete. Audit `connection.created`, `.revoked`, `.deleted`
    and `.expired` on the user's trail, with caller attribution, after the
    transaction commits, never carrying a token or a client secret.

11. **The OAuth client is folded into the server, not taken from ex_mcp.**
    The archived `managoat_mcp_auth` 0.2.0 comes back as
    `Fountain.Connections.OAuth` with its `UrlGuard`, trimmed to what this
    ADR uses and moved onto Req. Over the old library it adds:
    - pinning the connection to the address the guard resolved (Req's
      `connect_options`, keeping the hostname for TLS and SNI);
    - ex_mcp's broader list of non-public address ranges (MIT, credited in
      the source), with IP literals and loopback refused;
    - an issuer comparison that ignores one trailing slash, because Google
      publishes `https://accounts.google.com/` in one place and
      `https://accounts.google.com` in another;
    - client ID metadata documents (decision 4).

    ex_mcp 1.6.0 was spiked on 2026-10-15 against Linear and Gmail and
    needed four workarounds: its `WWW-Authenticate` parser ignores
    `resource_metadata`; it matches the issuer byte for byte; its
    same-origin endpoint policy refuses Google's token and JWKS hosts; and
    its `SecureHTTP` allows loopback by default. It also brings about 102k
    lines, Cowboy beside Bandit, a cowlib bump and about twelve supervised
    processes at boot, from one maintainer releasing every one to three
    weeks. The implementation PR closes #2746.

12. **First target: Linear**, which needs only the URL. Gmail
    (`gmailmcp.googleapis.com`, preview-gated by Google, with a pasted client)
    follows. Consent needs a person once per connection; after that the agent
    works unattended until the provider refuses a refresh.

## Consequences

- A user connects an OAuth-protected MCP server by pasting its URL, and any
  runtime can use it. No Managoat release is needed per server.
- Managoat owns no OAuth app registration and carries no provider's
  verification burden. Servers without client ID metadata documents or
  dynamic registration need the user to register an app, as Google does.
- The bearer is protected from the sandbox, not from the server: the binding
  sends it on every request to that host, so an endpoint on the host that
  reflected it back would hand it to the sandbox. That is the same bargain
  0070 makes for `chatgpt.com`.
- A server whose token endpoint, revocation endpoint or JWKS sits on a
  private address cannot be connected. That rules out self-hosted MCP servers
  on a private network, by design.
- Connecting needs a browser signed in to Managoat for the callback, even
  when Arugula started it through the API.
- `expired` is a real state for providers that issue no refresh token; the
  user reconnects.
- Not checked: Gmail's MCP endpoint and its
  metadata (an unauthenticated probe of the host on 2026-10-15 got a `400`
  and no protected-resource metadata at the origin); Google's OpenID
  configuration lists a `revocation_endpoint` and no `registration_endpoint`,
  so it takes a pasted client.

## Alternatives considered

- **Revive 0033 whole.** Its platform providers, tenant-defined providers,
  extensions and catalog were built for a hosted service and saw almost no
  use. A remote MCP server is the one case that is worth an OAuth client.
- **Tokens in the sandbox env.** Works with no broker change, but puts a
  refreshable credential where the agent can read and exfiltrate it, which
  0019 exists to prevent.
- **Refresh only before each turn**, as 0033 did. A Google token lasts an
  hour and a turn can run longer, so the server would start refusing calls
  mid-turn.
- **The broker fetches tokens from Managoat lazily**, per request or on a
  `401`. It would refresh only when needed and need no timer, but it is a
  bigger broker change: a callback into Managoat from the proxy, with its own
  auth and failure modes. A possible later step if the timer proves fragile.
- **Build on ex_mcp** (#2746's first candidate). Its authorization modules
  cover the flow, but the spike needed four workarounds for Linear and Gmail,
  and the dependency is far larger than the five files it replaces; see
  decision 11.

## Addendum, 2026-10-15: as built

Three departures from the decisions above, made while building it
(#2831), for the maintainer to keep or reverse:

- **One redirect URI, `<PUBLIC_URL>/connections/callback`**, not one per
  connection. A client ID metadata document lists its redirect URIs and
  providers match them exactly, so a per-connection path cannot be listed
  in it; and a pasted client (Google's) would need a redirect URI
  registered at the provider for every connection. `state` already names
  the connection, its user and the login in progress.
- **A pasted client wins.** When the user gives one, it is used even where
  the server offers a client ID metadata document or dynamic registration.
  Otherwise the order is decision 4's. The client ID metadata document is
  used only when `PUBLIC_URL` is `https://`, because the provider fetches it.
- **One more audit event, `connection.connected`**, when the callback stores
  a grant (first connect or reconnect). `connection.deleted` records whether
  the provider confirmed the revocation.

The login in progress is held on the row (a nonce and the encrypted PKCE
verifier), not in process memory. Delivery uses the reserved key range
`MANAGOAT_CONNECTION_<id>`, which no environment, vault or binding key may
take.

## History

- 2026-10-15 — Decided (#2824); built (#2831, #2832, #2833).
- 2026-10-17 — Refreshes leave the conversation's server: they run in tasks, all at once, behind a bounded wait (decision 9), because a slow token endpoint had blocked the server past its callers' 30-second timeout.
