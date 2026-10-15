---
type: ADR
title: "Fountain is the OAuth 2.0 authorization server for its own browser apps (code + PKCE, public clients, keys as tokens)"
description: "Managoat is the OAuth 2.0 authorization server for browser apps on other origins: code + PKCE S256, public clients, exact redirect URIs, tokens are expiring API keys without the admin scope."
tags: [auth, oauth, api, spa]
status: stable
adr: "0021"
adr_status: "Accepted"
date: 2026-08-18
generated: { by: human:jhgaylor, at: 2026-08-18T14:00:00-04:00 }
verified: { by: claude-code/opus-5, at: 2026-09-10T23:40:00-04:00 }
stale_after: 2026-12-10
---

# 0021 — Fountain is the OAuth 2.0 authorization server for its own browser apps

**Status:** Accepted — 2026-08-18.

## Context

Some of Managoat's user surfaces live outside the Phoenix app, on another
origin: static sites talking only to `/api` over CORS with a bearer API key.
Without OAuth the key has to be created under Account → API keys and pasted
in. That is fine for a CLI and wrong for an app: it teaches people to copy
long-lived secrets around, and it makes the first minute of the app a
scavenger hunt.

Managoat already has the two things a proper answer needs: a browser session
(email/password or GitHub via Ueberauth) and API keys with scopes, expiry
and revocation, checked by `TenantAPIAuth`. What was missing was the bridge
from one to the other with the user's consent.

People also build apps inside Managoat sandboxes, and pointing one at a
running deployment should not need an operator to edit `OAUTH_CLIENTS` and
`API_CORS_ORIGINS` and redeploy (#1125).

## Decision

Managoat acts as the OAuth 2.0 authorization server for browser apps
(`Fountain.OAuth`, `GET/POST /oauth/authorize`, `POST /api/oauth/token`,
`POST /api/oauth/revoke`).

- **Grant:** authorization code with PKCE, S256 only, for public clients —
  what a browser app can do safely. No client secret exists; the code, the
  verifier and the exact `redirect_uri` are the whole proof.
- **Two client registries.** Operator clients live in config
  (`config :fountain, :oauth_clients`, read from `OAUTH_CLIENTS` as JSON:
  `{id, name, redirect_uris}`) and are treated as published. Tenant clients
  live in the `oauth_clients` table: `client_id` (generated, never supplied),
  `name`, `redirect_uris`, a derived `origin_keys` lookup column, and
  `published`. `Fountain.OAuth.get_client/1` reads config first, so a row can
  never shadow an operator client.
- **Development mode is the security boundary, not the redirect allowlist.**
  An unpublished client authorizes only its owner; every other account gets a
  rendered error page, never a redirect, and the identity check runs before
  the redirect check so a stranger's error page discloses no registration.
  Because the only account such a client can capture belongs to the person
  who registered it, its owner may name any HTTPS redirect URI or an HTTP
  loopback URI. `published` is an operator flip with no self-serve path; once
  published, the owner can neither change nor delete the registration through
  self-service, because publication moved the trust boundary to every account
  and the row's random `client_id` could not be recreated.
- **Redirect matching** is exact, except RFC 8252 loopback matching for
  unpublished clients: a `http://localhost` or `http://127.0.0.1` redirect
  matches on any port, because the port a local dev server lands on is not a
  fact anybody registered. Published clients get no such latitude.
- **Consent page** at `GET /oauth/authorize` behind the browser session:
  names the client, Allow / Deny. Signed out, the request is stashed
  (`FountainWeb.ReturnTo`) and the normal login returns to it. A request
  whose client or redirect does not check out is rendered as an error, never
  redirected: a redirect to an unregistered URI is exactly the open
  redirector the allowlist prevents.
- **Codes** are hashed at rest, bound to user + client + redirect_uri +
  challenge, live 5 minutes, and are single-use by a conditional update.
- **Tokens are API keys.** A successful exchange mints an ordinary key
  (`Accounts.create_api_key/3`, via `Fountain.OAuth.Host`) named
  `oauth:<client_id>`, full scope, expiring in 30 days. It never carries the
  `admin` scope: `create_api_key/3` refuses it, and `/api/admin` requires that
  scope as well as the admin role, so an admin who signs into an app gives it
  the admin's account but not the power to act on other accounts. The key
  lists and revokes under Account → API keys, and revoke on sign-out is
  `POST /api/oauth/revoke` with the token itself.
- **One error for every wrong grant** at the token endpoint (`invalid_grant`),
  rate-limited per IP; the response never says which check failed.
- **CORS reads the same registries.** `API_CORS_ORIGINS` first, then any
  registered client's redirect origin, loopback on any port, so the sign-in
  and the first API call cannot disagree. A preflight carries no
  authentication, so the origin is the only key there is; admitting an origin
  admits nobody who does not already hold a bearer key, and no cookie crosses
  an origin either way.
- **`form-action`** names only this request's validated redirect origin, taken
  from the requested URI rather than the registration, because a loopback
  port varies legally and a header naming every client would grow without
  bound and hand the registry to any visitor.
- **Managing clients needs full scope.** `/api/oauth/clients` sits behind
  `:require_full_scope`, not the sprite scope #1125 proposed: a registered
  client is a standing way to obtain a full-scope 30-day key with one
  consent, which is the escalation the sprite scope exists to prevent
  (`Fountain.Accounts.ApiKey`). Registering from the console, the CLI or the
  API with the owner's own key still removes the operator.
- **Twenty-five clients per account**, an abuse ceiling rather than an
  allowance, because every row widens the deployment's CORS allowlist. An
  operator raises it by editing the constant.
- **Audit:** `oauth.authorized` at consent, carrying the client's
  `resource_id`; `api_key.created` at exchange; `oauth_client.created`,
  `.updated`, `.deleted`.

## Consequences

- An app gets "Sign in with Managoat" with ~80 lines of PKCE and a callback
  route; the paste-a-key path stays as the fallback and for the CLI
  (`POST /api/auth/token` is untouched).
- Every login method Managoat has, or grows later, works for the apps for
  free: the OAuth layer sits on the session, not on a provider.
- An app the operator vouches for is one entry in `OAUTH_CLIENTS` (and
  `API_CORS_ORIGINS`). Anyone else registers their own client, and one
  registration covers both OAuth and CORS.
- There is no operator switch that turns self-registration off. Any verified
  account may register, which is the point; a setting to disable it would be
  a new flag, not a change of mind here.
- Nothing auto-registers a sandbox's redirect at spawn: explicit registration
  is one call, and auto-registration would leave stale origins admitted after
  the sandbox is gone.
- The SDKs do not model the registration endpoints
  (`sdk/contract/omissions.json`): registering is a once-per-app setup step.
- Not built: per-scope consent, client secrets, refresh tokens, and a publish
  or review workflow. Consent is coarse (full scope), a 30-day key and a
  fresh sign-in when it expires is the whole token lifecycle, publishing is
  an operator action outside the product (SQL), and a stranger's app cannot
  act as another user without an operator publishing it.

## Alternatives considered

- **Paste an API key into each app** — kept only as a fallback; it teaches
  copying long-lived secrets and makes the first minute a scavenger hunt.
- **Wildcard the sandbox domain in `OAUTH_CLIENTS` and `API_CORS_ORIGINS`** —
  fine for CORS, a phishing kit for OAuth: anyone with any sandbox could start
  a flow with their own PKCE challenge and their own box as `redirect_uri`,
  and a consenting user's 30-day full-scope key would land there. PKCE does
  not help when the attacker initiates the flow.
- **Config registry only** — the original choice; it put an operator and a
  redeploy in front of every app built in a sandbox.

## History

- 2026-08-18 — Decided and built: code + PKCE, config registry, tokens are API keys (#819).
- 2026-09-10 — Tenant-registered clients in an `oauth_clients` table, development mode as the boundary, loopback matching, CORS and `form-action` from the registry (#1125).
- 2026-10-14 — An OAuth key never carries the `admin` scope (#2660, [0064](0064-an-admin-opens-accounts-for-a-platform.md)).
