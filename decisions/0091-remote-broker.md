---
type: ADR
title: "A remote broker consults home for every HTTP admission"
description: "Superseded 2026-10-17 by 0093. Was: an optional standalone broker on Fly streamed payloads off home, fetching destination-scoped credentials from home on each HTTP request."
tags: [broker, deployment, security]
status: deprecated
adr: "0091"
adr_status: "Superseded by 0093"
date: 2026-10-16
---

# 0091 — A remote broker consults home for every HTTP admission

**Status:** Superseded 2026-10-17 by [0093](0093-the-broker-runs-inside-managoat.md): the remote node held the broker CA seed and admitted credentials, and every request waited on home, to buy faster large downloads that are now kept off the broker instead. Was: an optional standalone broker on Fly streamed payloads off home, fetching destination-scoped credentials from home on each HTTP request.

This ADR is kept as a tombstone so its number and links stay stable. Its full
text, with the original context, decision and alternatives, is
[at ee93c83c](https://github.com/managoat/managoat/blob/ee93c83ce0d16bfb68dc6bb9f3956d24835b00c0/decisions/0091-remote-broker.md).
