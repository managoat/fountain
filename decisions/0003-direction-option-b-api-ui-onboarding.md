---
type: ADR
title: "Fountain targets Option B: API + Hosted UI with Self-Serve Onboarding"
description: "Retired 2026-10-12: Fountain is no longer sold as a hosted service. G0: Fountain targets Option B, a multi-tenant REST API plus hosted LiveView UI plus self-serve onboarding; org/team features are deferred."
tags: [framing, scope, gates]
status: deprecated
adr: "0003"
adr_status: "Retired"
date: 2026-05-10
generated: { by: human:jhgaylor, at: 2026-05-09T22:38:48-04:00 }
---

# 0003 — Fountain targets Option B: API + Hosted UI with Self-Serve Onboarding

**Status:** Retired 2026-10-12; see the addendum at the end. The text above the addendum is history. Was: Accepted — 2026-05-10.

## Context

The `phase-0-framing` slice produced a side-by-side scope comparison at `plan/phase-0-framing/scope-comparison.md`. Two options were framed:

- **Option A** — API-only multi-tenant core. Faster to ship; narrower TAM; targets developer integrators.
- **Option B** — API + Hosted UI + Self-Serve Onboarding. Broader TAM; higher engineering cost; opens to non-developer users.

The G0 gate required the human operator to choose a direction before engineering and design work begins. The success metric is 100 weekly active users by month 6.

## Decision

Fountain will pursue **Option B — API + Hosted UI with Self-Serve Onboarding**:

- All aod-ex primitives (environments, vaults, agents, conversations, secrets, sandbox, turns, log events) are carried forward and rebuilt with tenant scoping across three surfaces: REST API, Phoenix LiveView dashboard, CLI.
- Multi-tenancy additions in scope: per-user identity and API keys, resource isolation by tenant, per-tenant secret envelope encryption, sandbox quotas, usage events, billing surface, self-serve onboarding wizard, in-browser log viewer, scoped admin tooling.
- Org/team features (shared environments and agents within a team) are deferred post-launch unless scope review changes this.

## Consequences

- The growth-marketer drafts a press-release-first spec anchored to Option B before engineering scope is locked (G1).
- Designer and engineer work will cover all three surfaces.
- Engineering complexity is higher than Option A; auth UX, LiveView multi-tenant refactor, and onboarding flow are all in scope.
- If Option B proves too slow to reach early users, revisit Option A scope as a fallback at G2.

## Alternatives considered

- **Option A (API-only)** — Rejected at G0. Faster to ship but the 100 WAU target is harder without a visual surface and guided onboarding.

## Addendum — 2026-10-12: retired, Fountain is not a hosted service

Fountain is no longer sold as a hosted service (2026-10-12). It is a
self-hosted application: an operator runs it for themselves or the people
they let in. The direction this ADR chose was a hosted, multi-tenant product
reached through self-serve onboarding and measured against a 100-WAU goal.
That goal is withdrawn, and so is the product reason for this decision.

What stays is what was built, because a self-hosted instance with more than
one account still needs it: the three surfaces (REST API, LiveView console,
CLI), per-user tenant scoping of every primitive, per-user API keys and
secret encryption, the sandbox concurrency cap, `usage_events`, the admin
console, and the first-run page for a new account. What went with the
hosted business: the billing surface (credits and Stripe, ADR 0010, 0030,
0031), the product analytics (ADR 0025) and claimable principals (ADR 0044).

Org/team features are not planned. The "deferred post-launch" line above no
longer means "until traction shows": there is no traction goal, and
`CLAUDE.md` now says what Fountain is instead.
