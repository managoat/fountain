---
type: ADR
title: "Account settings are a first-party OAuth app"
description: "Account settings use a static OAuth client, bundled for self-hosters or separately hosted; admin keys and provider authentication remain session-protected."
tags: [web, oauth, account]
status: stable
adr: "0087"
adr_status: "Accepted"
date: 2026-10-16
---

# 0087 — Account settings are a first-party OAuth app

**Status:** Accepted.

## Context

The account LiveViews duplicated the API's key, app, connection, credential,
binding, password and deletion operations. Conversations already uses the
[OAuth app boundary](0021-oauth-for-first-party-apps.md). Moving account settings
to that boundary makes the API the path used by our own settings interface.

## Decision

Account settings are a static first-party application using authorization-code
OAuth with S256 PKCE. The source ships in the server release, avoiding a new
required service for self-hosters. `ACCOUNT_APP_URL` selects a separately hosted
copy; otherwise `/account` redirects to the bundled static app. The reserved
`managoat-account` client is registered from that URL, including its CORS origin.
Tokens remain in per-tab sessionStorage; sign-out revokes the presented token.

The server retains login, consent, password recovery, device approval and remote
MCP callbacks. ChatGPT subscription linking keeps its server-side device flow at
`/auth/chatgpt`, linked from account settings. Admin-key issuance moves to
`/admin/keys` behind the existing admin session guard: the account OAuth client
has ordinary full scope and cannot acquire admin scope. Admin UI extraction is
not built by this decision.

## Consequences

Account mutations now carry API attribution. Password changes invalidate browser
sessions but preserve API keys, including the app token; the UI explains this.
The app handles loading, errors and validation locally. Deployment can use a
static host without an application backend, or the bundled copy. The legacy
account paths remain redirects, including section links and provider callbacks.
Hosting at `account.managoat.com` requires deploying the static host and setting
`ACCOUNT_APP_URL`; this change does not claim that DNS or deployment is live.

## Alternatives considered

- Keep account LiveViews: fewer browser-side concerns, but duplicate interfaces.
- Require a separate account host: simpler packaging, but adds infrastructure to
  every self-hosted installation.
- Let account OAuth tokens mint admin keys: breaks the deliberate boundary that
  prevents an admin's ordinary OAuth apps from obtaining operator powers.
