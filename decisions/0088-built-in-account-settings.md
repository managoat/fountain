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
Keep admin-key issuance in `/admin/keys` behind the admin session guard, and
provider authentication at `/auth/chatgpt`. Conversations remains a separate app.

Remove the static account client and its automatic OAuth/CORS registration.
`ACCOUNT_APP_URL` is no longer read. Legacy server paths redirect to built-in
sections; old fragment links select the same section. The maintainer's account
hostname becomes a redirect in home-cloud, after the server release is deployed.

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
