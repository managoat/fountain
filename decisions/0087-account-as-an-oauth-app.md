---
type: ADR
title: "Account settings are a first-party OAuth app"
description: "Superseded by built-in session-authenticated account settings; the account APIs remain supported."
tags: [web, oauth, account]
status: deprecated
adr: "0087"
adr_status: "Superseded by 0088"
date: 2026-10-16
---

# 0087 — Account settings are a first-party OAuth app

**Status:** Superseded on 2026-10-16 by [ADR 0088](0088-built-in-account-settings.md).

Separate account hosting added OAuth, deployment and navigation complexity to
settings that belong to the server. The account APIs remain; the built-in UI
uses the browser session. [Last full decision](https://github.com/managoat/managoat/blob/4335846d7/decisions/0087-account-as-an-oauth-app.md).
