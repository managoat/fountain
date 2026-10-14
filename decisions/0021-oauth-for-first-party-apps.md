---
type: ADR
title: "Fountain is the OAuth 2.0 authorization server for its own browser apps (code + PKCE, public clients, keys as tokens)"
description: "The standalone team and conversations apps on other origins sign in with a Fountain session instead of a pasted API key: authorization code + PKCE (S256), public clients, redirect URIs exact, tokens are ordinary expiring API keys. Amended 2026-09-10 (#1125): a tenant may register its own client, unpublished, which authorizes only its owner. No client secrets, no refresh tokens yet. Amended 2026-10-14 (#2660): an OAuth key never carries the admin scope."
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

**Status:** Accepted — built in [#819](https://github.com/BinaryBourbon/fountain/pull/819):
`Fountain.OAuth`, `GET/POST /oauth/authorize`, `POST /api/oauth/token`,
`POST /api/oauth/revoke`, `OAUTH_CLIENTS`.

**Amended 2026-09-10 ([#1125](https://github.com/managoat/fountain/issues/1125)):**
the config registry is no longer the only one. See
[Amendment: tenant-registered clients](#amendment-tenant-registered-clients-1125)
at the end; the two consequences it changes are marked below.

## Context

Two of Fountain's user surfaces now live outside the Phoenix app, on another
origin: the team app (fountain#810) and the conversations app (fountain#813,
#815), static sites talking only to `/api` over CORS with a bearer API key.
Until now the key had to be created under Account → API keys and pasted in.
That is fine for a CLI and wrong for an app: it teaches people to copy
long-lived secrets around, and it makes the first minute of the app a
scavenger hunt.

Fountain already has the two things a proper answer needs: a browser session
(email/password or GitHub via Ueberauth) and API keys with scopes, expiry
and revocation, checked by `TenantAPIAuth`. What was missing was the bridge
from one to the other with the user's consent.

## Decision

Fountain acts as the **OAuth 2.0 authorization server** for its own apps.

- **Grant:** authorization code with **PKCE, S256 only**, for **public
  clients** — what a browser app can do safely. No client secret exists; the
  code, the verifier and the exact `redirect_uri` are the whole proof.
- **Client registry in config**, not a table: `config :fountain,
  :oauth_clients` (runtime.exs reads `OAUTH_CLIENTS` as JSON) lists
  `{id, name, redirect_uris}`. Redirect URIs match **exactly**. Two clients
  are ours; a table and an admin UI come when a third party asks.
  *(Amended: the table exists — see below. Config clients remain, and are
  read as published.)*
- **Consent page** at `GET /oauth/authorize` behind the browser session:
  names the client, Allow / Deny. Signed out → the request is stashed
  (`FountainWeb.ReturnTo`) and the normal login — password or GitHub —
  returns to it. A request whose client or redirect does not check out is
  **rendered** as an error, never redirected: a redirect to an unregistered
  URI is exactly the open redirector the allowlist prevents.
- **Codes** are hashed at rest, bound to user + client + redirect_uri +
  challenge, live 5 minutes, and are single-use by a conditional update.
- **Tokens are API keys.** A successful exchange mints an ordinary key
  (`Accounts.create_api_key/3`) named `oauth:<client_id>`, full scope,
  expiring in 30 days. So it lists and revokes under Account → API keys,
  `TenantAPIAuth` and the audit trail need no change, and revoke on sign-out
  is `POST /api/oauth/revoke` with the token itself. `oauth.authorized` is
  recorded at consent; `api_key.created` at exchange.
- **One error for every wrong grant** at the token endpoint (`invalid_grant`),
  rate-limited per IP; the response never says which check failed.
- **No refresh tokens (yet).** 30-day keys and a fresh sign-in when they
  expire is enough for first-party apps; refresh rotation is a follow-up if
  the expiry annoys.

## Consequences

- The apps get "Sign in with Fountain" with ~80 lines of PKCE and a callback
  route; the paste-a-key path stays as the fallback and for the CLI
  (`POST /api/auth/token` is untouched).
- Every login method Fountain has now, or grows later, works for the apps for
  free — the OAuth layer sits on the session, not on a provider.
- Adding an app = one entry in `OAUTH_CLIENTS` (and `API_CORS_ORIGINS`).
  *(Amended: only for an app the operator vouches for. Anyone else registers
  their own, and one registration covers both.)*
- What this is **not**: a way for third parties to act as Fountain users. The
  registry is ours, consent is coarse (full scope), and there are no scopes
  narrower than what API keys already have. Doing that properly means a
  clients table, per-scope consent and refresh rotation — the shape is
  compatible, the work is not done.
  *(Amended: the clients table is done and a tenant may register into it, but
  only for itself. Per-scope consent and refresh rotation are still not
  built, and there is still no way for a stranger's app to act as a Fountain
  user without an operator publishing it.)*

## Amendment: tenant-registered clients (#1125)

**2026-09-10.** The consequence above said a third-party clients table would
come "when a third party asks". The ask arrived in the shape the product is
about: people build apps *inside* Fountain sandboxes, and pointing one at a
production Fountain meant asking an operator to edit `OAUTH_CLIENTS` and
`API_CORS_ORIGINS` and redeploy. That is not a first minute anybody finishes.

### The wrong answer, on the record

Wildcard the sandbox domain in both lists. Fine for CORS, a phishing kit for
OAuth: anyone with any sandbox could start a flow with their own PKCE
challenge and their own box as `redirect_uri`, and a consenting user's 30-day
full-scope key would land there. **PKCE does not help when the attacker
initiates the flow.**

### What was built

- **`oauth_clients`**, tenant-owned: `client_id` (generated, never supplied),
  `name`, `redirect_uris`, a derived `origin_keys` lookup column, `published`.
  `Fountain.OAuth.get_client/1` reads config first, so a row can never shadow
  a first-party client.
- **Development mode is the security boundary, not the redirect allowlist.**
  An unpublished client authorizes **only its owner**; every other account
  gets a rendered error page, never a redirect, and the identity check runs
  *before* the redirect check so a stranger's error page discloses no
  registration. Because the only account such a client can capture belongs to
  the person who registered it, its owner may name any HTTPS redirect URI or
  an HTTP loopback URI.
  `published` is an operator flip with no self-serve path. Once published, the
  owner can neither change nor delete the operator-approved registration
  through self-service. Deleting matters as much as editing: publication moved
  the trust boundary to every account, and the row's `client_id` is random, so
  a deletion would break sign-in for all of them with an id nobody can
  recreate.
- **RFC 8252 loopback matching**, for unpublished clients only: a
  `http://localhost` or `http://127.0.0.1` redirect matches on any port,
  because the port a local dev server lands on is not a fact anybody
  registered. Published clients get no such latitude.
- **CORS reads the same table.** `API_CORS_ORIGINS` first, then any registered
  client's redirect origin. A preflight carries no authentication, so the
  origin is the only key there is — which is exactly why "an origin some
  client registered" is the right predicate: admitting an origin admits
  nobody who does not already hold a bearer key, and no cookie crosses an
  origin either way. Loopback matches on any port here too, so the sign-in and
  the first API call cannot disagree.
- **`form-action` narrowed** from every client's origins to this request's
  validated redirect origin. With tenant-registered apps the old header would
  grow without bound and hand the whole registry to any visitor. The source is
  the requested URI rather than the registration, because a loopback port
  varies legally and a header naming the registered port has the browser block
  a redirect the server approved.
- **Full scope to manage clients.** `/api/oauth/clients` sits behind
  `:require_full_scope`, not the sprite scope #1125 originally proposed. A
  registered client is a standing way to obtain a full-scope 30-day key with
  one consent, which is the escalation the sprite scope exists to prevent
  (`Fountain.Accounts.ApiKey`); a sandbox token must not be able to leave one
  behind. Registering from the console, the CLI or the API with the owner's
  own key still removes the operator, which was the point.
- **Twenty-five clients per account**, an abuse ceiling rather than an
  allowance, because every row widens the deployment's CORS allowlist and
  registration is self-serve. An operator raises it by editing the constant;
  nobody has asked yet.
- **Audit**: `oauth_client.created`, `.updated`, `.deleted`, and
  `oauth.authorized` now carries the client's `resource_id`.

### Still not done

Per-scope consent, client secrets, refresh tokens, and a publish or review
workflow. Publishing is SQL or a `mix` task until somebody needs more.

**There is no operator switch that turns self-registration off.** Any verified
account on any deployment may register, which is deliberate: it is the whole
point of the amendment, and the CORS consequence admits nobody who does not
already hold a bearer key. A self-hoster who wants the old behaviour has no
setting to reach for, so if one is ever asked for, it is a new flag rather
than a change of mind here. Nothing
here auto-registers a sandbox's redirect at spawn: explicit registration is
one call, and auto-registration would leave stale origins admitted after the
sandbox is gone. The SDKs do not model the registration endpoints
(`sdk/contract/omissions.json`), because registering is a once-per-app setup
step rather than something a client does per run.

## Addendum — 2026-10-14: an OAuth key never carries admin powers (#2660)

*Decision* calls the token an ordinary full-scope API key. Full scope no
longer includes the operator surface: `/api/admin` requires the `admin` scope
as well as the admin role (ADR 0064, addendum of the same date), and
`Fountain.OAuth.Host` mints with `create_api_key/3`, which refuses that scope.
An admin who signs into an app, first-party or tenant-registered, gives it the
admin's account but not the power to act on other accounts.
