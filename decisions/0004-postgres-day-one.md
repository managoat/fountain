---
type: ADR
title: "Postgres from day one (drop the SQLite path)"
description: "Postgres is the only relational store, demos included; there is no ephemeral storage path or anonymous try-it."
tags: [data, infra]
status: stable
adr: "0004"
adr_status: "Accepted"
date: 2026-05-09
generated: { by: openai/gpt-6, at: 2026-09-14T09:12:00Z }
verified: { by: human:jhgaylor, at: 2026-08-02T23:13:41-04:00 }
---

# 0004 — Postgres from day one (drop the SQLite path)

**Status:** Accepted — 2026-05-09.

## Context

The Phase 2 engineering plan raised OQ-1b: SQLite + WAL on a persistent disk
for launch, or Postgres? The plan's working assumption was SQLite, justified by
aod-ex's existing use of it and by the modest launch scale, with Postgres as a
later cutover. Two facts pushed the decision the other way:

1. **The cutover has a real cost and risk profile.** A SQLite→Postgres
   migration mid-product means a downtime window, data-parity validation and
   infrastructure rework. Done well it is a sprint; done badly it is an
   incident. Doing it once, while the schema is still ink on paper, removes
   that risk.
2. **SQLite needed Litestream for any meaningful point-in-time recovery**,
   adding Litestream and S3 to the launch infrastructure. Postgres backups are
   a known commodity for the operator.

aod-ex's reference value ([0002](0002-aod-ex-as-reference.md)) is in the
schema and the contexts, not the storage adapter.

## Decision

Postgres is Managoat's only relational store, demos and first runs included.

- The Ecto repo uses `Ecto.Adapters.Postgres`. Schemas use `jsonb` where
  structured columns pay for it, `binary_id` primary keys (`Ecto.UUID`,
  UUIDv4), and `bigint` for append-only event keys. Postgres-specific
  features (`jsonb` operators, partial indexes, identity columns) are used
  without restraint when they pay for themselves.
- There is no ephemeral or database-free mode. In-memory or SQLite state
  would add a second storage path and an ongoing maintenance and CI
  obligation for the sake of a first impression (#1579).
- There is no anonymous try-it. A self-hosted first run means generating
  keys, starting Compose and Postgres, learning Agent, Environment, Vault and
  Conversation, and supplying inference credentials before the first reply.
  Managoat accepts that value arrives after commitment and competes on
  something other than time to first look.
- Backups are the operator's Postgres backups; the maintainer's instance runs
  CloudNativePG on the home-cloud cluster
  ([0032](0032-hosted-overlay-leaves-the-repo.md)).

## Consequences

- No pending storage migration and no abstraction layer keeping a SQLite
  option open.
- The operational floor rises slightly: every deployment runs Postgres.
- Primary keys are UUIDv4, not time-ordered. If time-ordered ids become
  necessary, that is a new decision and a migration.
- `managoat quickstart` (#1391) is the closest thing to a one-command path. It
  still needs an account and a Postgres database; collapsing registration
  through the first reply is not built, and is the option to revisit first if
  the on-ramp ever needs improving.
- goatherd runs the component libraries without signup; it is not Managoat's
  on-ramp or an exception to this decision
  ([0055](0055-hosted-fountain-and-local-control-planes.md)).
- An embedded single-binary product would be a separate product with its own
  storage decision.
- Reversal is a Postgres→SQLite migration on live data, materially worse than
  the cutover this avoided. Treat it as irreversible.

## Alternatives considered

- **SQLite + Litestream at launch, Postgres later** — pushes a known migration
  into a future sprint, needs Litestream tuning the operator had not done, and
  saves only the cost of a database.
- **SQLite with no Litestream** — a disk failure would lose data between
  snapshots.
- **A managed serverless Postgres (Neon, Supabase)** — an extra vendor
  relationship not justified by any evidence that the database is the
  bottleneck.
- **Ephemeral single-tenant demo mode** — rejected (#1579): a second storage
  path to maintain for a first impression.
- **Hosted try-it without signup** — rejected (#1579): throwaway identities
  and a pre-funded public instance create an abuse surface and real spend on
  strangers. There is no hosted service since 2026-10-12, so nothing would
  host it anyway.

## History

- 2026-05-09 — Decided: managed Postgres as the only store from launch; UUIDv7 keys and the host's managed backups planned.
- 2026-08-02 — UUIDv7 was never built (keys are UUIDv4); backups moved to CloudNativePG on the home-cloud cluster.
- 2026-09-14 — Reaffirmed for demos: no ephemeral mode, no anonymous hosted try-it ([#1579](https://github.com/managoat/fountain/issues/1579#issuecomment-5660991693), adoption tracker #1585).
