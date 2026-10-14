---
type: ADR
title: "`jhgaylor/aod-ex` is the reference implementation Fountain forks from"
description: "Retired 2026-10-14: Fountain has long outgrown aod-ex and is now a self-hosted product, so nobody reads aod-ex before proposing scope and there is no multi-tenant delta to focus on. Was: jhgaylor/aod-ex is the single-tenant reference implementation Fountain rebuilds from; design work focuses on the multi-tenant delta, not the baseline."
tags: [framing, reference-implementation]
status: deprecated
adr: "0002"
adr_status: "Retired"
date: 2026-05-09
generated: { by: human:jhgaylor, at: 2026-05-09T21:18:50-04:00 }
---

# 0002 — `jhgaylor/aod-ex` is the reference implementation Fountain forks from

**Status:** Retired 2026-10-14; see the addendum at the end. The text above
the addendum is history. Was: Accepted — 2026-05-09.

## Context

[`jhgaylor/aod-ex`](https://github.com/jhgaylor/aod-ex) is a working single-tenant implementation of the capability set Fountain needs: managing agents, repos, secrets, conversations, MCP servers, and skill setups for sandboxed coding-agent instances. It exists, it runs, and the maintainer (jhgaylor) is the same person driving Fountain.

Fountain's reason for existing is not that aod-ex's capabilities are wrong. It's that aod-ex targets a different user (single-operator, local) and rebuilding around a multi-tenant API/UI for external users requires a different shape — auth, isolation, billing surface, onboarding UX, debugging affordances — even when the underlying primitives stay the same.

Without a written marker, future specialists (especially customer-researcher in `phase-0-framing` and engineers later) risk re-deriving the capability set from scratch, missing prior art, or rebuilding decisions aod-ex already made well.

## Decision

Treat `jhgaylor/aod-ex` as Fountain's **reference implementation**. Specialists doing framing, design, or engineering work on Fountain should:

1. Read aod-ex's code and docs before proposing scope or architecture for an equivalent capability.
2. Default to preserving aod-ex's primitives (agents, repos, secrets, conversations, MCP/skill config) unless there's a multi-tenancy reason to change them.
3. Make the *delta* the focus of design discussion — what has to change for multi-tenant, multi-user, API-first use — rather than re-litigating the single-tenant baseline.

This is **not** a license to copy code wholesale. Fountain is a new repo with a new architecture; aod-ex is the spec, not the substrate.

## Consequences

- `phase-0-framing` and subsequent slices have a concrete starting point, reducing wasted exploration.
- Decisions that diverge from aod-ex should be captured as ADRs (e.g. "0003 — drop aod-ex's X because multi-tenant requires Y") so the lineage stays traceable.
- If aod-ex evolves materially after Fountain forks conceptually, this ADR may need a refresh — flag it at the next gate review.
- Implicit dependency on aod-ex remaining accessible to the team. If that changes (private, deleted, abandoned), this ADR loses force.

## Alternatives considered

- **Treat Fountain as a clean-sheet design.** Rejected — discards working prior art and forces re-derivation of capabilities the operator already validated single-tenant.
- **Fork aod-ex directly and refactor toward multi-tenant.** Rejected — aod-ex's shape is tuned for a different user; bolting multi-tenancy onto it tends to produce worse outcomes than rebuilding around the new shape with aod-ex as a reference.
- **Leave the relationship implicit (status quo before this ADR).** Rejected — captain-picard dispatches read these files cold and need the lineage made explicit, not buried in a description paragraph.

## Addendum — 2026-10-14: retired, aod-ex is history, not a reference

The three instructions above no longer apply, and an agent reading this ADR
cold should not follow them.

- **Read aod-ex first.** Fountain's own code, ADRs and manual are the
  reference for every capability it has; aod-ex has not changed since
  2026-05-10 and is archived. Proposals start from this repository.
- **Focus on the multi-tenant delta.** Fountain is no longer sold as a hosted
  service (2026-10-12, [0003](0003-direction-option-b-api-ui-onboarding.md)'s
  addendum). It is a self-hosted application with per-user scoping and no
  org/team features planned, so there is no multi-tenant product whose delta
  from a single-tenant baseline is the design question.
- **Default to aod-ex's primitives.** The four primitives in `CLAUDE.md` are
  Fountain's own now, decided and amended in this bundle.

The lineage is kept: [0004](0004-postgres-day-one.md) and
[0008](0008-byo-inference-credentials.md) cite this ADR for where Fountain
started, and those references remain true as history.
