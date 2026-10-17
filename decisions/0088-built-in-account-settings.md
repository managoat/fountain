---
type: ADR
title: "Account settings belong to the server console"
description: "Account settings use session-authenticated LiveViews with section navigation; the account APIs remain, and admin stays separately protected."
tags: [web, account]
status: stable
adr: "0088"
adr_status: "Accepted"
date: 2026-10-16
---

# 0088 — Account settings belong to the server console

**Status:** Accepted. Supersedes [ADR 0087](0087-account-as-an-oauth-app.md).

## Context

Extracting account settings simplified the LiveView code but added another
OAuth flow, origin, deployment configuration and visual shell. For a self-hosted
server, managing its own credentials is part of the console. The improved
section navigation does not require a separately deployed client.

## Decision

Serve `/account` as a session-authenticated LiveView under the shared user header.
Use persistent section navigation on desktop and a picker on mobile; show one
section at a time, preserving component state across navigation. Security holds
password changes and deletion. Keep account APIs and their authorization tests.
An admin mints admin keys in the API keys section: the checkbox is shown only to
admins, and the context checks the role of the user as stored at mint time.
ChatGPT subscription linking is part of the inference credentials section.
Conversations remains a separate app.

Remove the static account client and its automatic OAuth/CORS registration.
`ACCOUNT_APP_URL` is no longer read. Server paths that predate the standalone
app redirect to built-in sections. The standalone app's own URLs and fragment
links are not kept: they were live for about 100 minutes. The maintainer's
account hostname becomes a redirect in home-cloud, after the server release is
deployed.

## Consequences

Account settings require no OAuth consent or separate deployment. Mutations use
shared contexts with UI attribution. Browser password changes renew this session
and invalidate other browser sessions; API behavior is unchanged. Existing API
keys, including previously issued account-app keys, are not silently revoked.
The account UI no longer exercises OAuth as a first-party consumer; Conversations
and the API/OAuth tests retain that coverage.

## Alternatives considered

- Keep the standalone account app: preserves API dogfooding but retains extra
  authentication and deployment concerns for server settings.
- Embed the OAuth client in the console: retains two authentication mechanisms
  and client state models for the same server.

## History

- 2026-10-17 — Admin-key issuance moved from `/admin/keys` into the account's
  API keys section, and ChatGPT linking from `/auth/chatgpt` back into
  inference credentials. Both pages existed only because of the standalone app.
  The `/account-app` redirects and the `#section` fragment rewrite were removed.
