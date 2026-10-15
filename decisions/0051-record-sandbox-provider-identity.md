---
type: ADR
title: "Record trusted sandbox provider identity"
description: "Retired 2026-10-13: its column and writer are gone. Was: an optional provider-issued sandbox identity."
tags: [sandboxes, security]
status: deprecated
adr: "0051"
adr_status: "Retired"
date: 2026-09-10
generated: { by: agent:codex, at: 2026-09-10T11:42:46+00:00 }
verified: { by: agent:codex, at: 2026-09-10T11:42:46+00:00 }
stale_after: 2026-10-10
---

# 0051 — Record trusted sandbox provider identity

**Status:** Retired 2026-10-13; see the addendum. Was: Proposed. This PR implements storage and internal recording. Worker
integration and conditional provider writes remain separate work in
[#1754](https://github.com/managoat/fountain/pull/1754).

## Context

A sandbox name alone cannot establish which provider instance was observed.
Keeping a provider-issued identity separately lets later lifecycle work compare
that observation with its saved intent. General sandbox attributes are not a
trusted source for this identity.

## Decision

Store an optional `provider_instance_id` on the sandbox row. A trusted caller may
record it once from provider control metadata. The writer locks and rechecks the
row's tenant, provider and name; retired or changed rows refuse the write. The
same provider and ID cannot belong to two retained rows, including retired rows.
Different providers may use the same ID.

Lookup and binding refuse an enclosing database transaction: provider I/O runs
outside locks, and the best-effort audit follows the binding commit. General
sandbox changesets cannot set the identity. Rollback refuses to discard populated
identities; existing rows receive a null value on migration.

## Consequences

This records an observation. It does not authorize a later provider mutation:
a lookup followed by a name-based delete still races replacement. Existing
lifecycle callers are unchanged. Provider operation journals need their own
ownership and incarnation checks. Deleting the sandbox row removes this record;
it is not a durable cleanup obligation independent of that row.

## Alternatives considered

- Store identity in general provider metadata: ordinary changesets can replace that map.
- Re-fetch before each deletion: does not make a subsequent write atomic.

## Addendum — 2026-10-13: the storage is dropped

Nothing records or reads the identity any more. Its only writer,
`SandboxIdentity.bind/2`, had no caller and went with ADR 0058 stage 8b, and
#1754, the provider-journal integration this pointed to, closed unmerged.
Migration `20261013200000` drops `sandboxes.provider_instance_id` and its
partial unique index on `(provider, provider_instance_id)`. A later need for a
trusted provider identity starts from a new decision, not from this column.
