---
type: ADR
title: "Account deletion (and, until 2026-10-12, data export)"
description: "Account deletion is immediate and ordered: sandboxes destroyed best-effort, an audit row written, the account row deleted, crypto-shredding its key."
tags: [accounts, privacy, billing]
status: stable
adr: "0009"
adr_status: "Accepted"
date: 2026-08-03
generated: { by: human:jhgaylor, at: 2026-08-03T16:55:10-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-03T16:55:10-04:00 }
---

# 0009 — Account deletion (and, until 2026-10-12, data export)

**Status:** Accepted, 2026-08-03. Documents behavior built in #170/#288 and
refined through #450.

## Context

Deletion encodes legal commitments (erasure scope, what "unrecoverable"
means), but the reasoning lived only in the `Fountain.Accounts.Deletion`
moduledoc. A moduledoc reads as implementation detail: nothing marked these
as decisions future work must not casually reverse, and the 2026-08-03 story
assessment (#453) flagged exactly that. This ADR records the decisions; the
moduledoc keeps the mechanics.

## Decision

**Deletion is immediate and ordered.** `Deletion.delete_user/2` is the single
path for both triggers: self-serve deletion (the console, with typed-email
confirmation, or the API) and admin deletion.

1. Sandbox destruction, best-effort (`SandboxReaper` reconciles stragglers).
2. Audit event before the delete, with email and user id denormalized into
   metadata, because `audit_events.user_id` nilifies on delete.
3. Row delete. Cascades take agents, api_keys, conversations (turns, log
   events), environments, vaults, oauth_identities, inference_credentials
   and `user_data_keys`; `audit_events` and `sandboxes` nilify, keeping
   operational history that names nobody.

**Crypto-shred, with an honest boundary.** Deleting `user_data_keys` destroys
the wrapped per-tenant DEK, so ciphertext that outlives the cascade is
undecryptable rather than merely unreferenced. This does not reach database
backups taken before the deletion; backup expiry (14 days) is what erases
those, on its own schedule. User-facing copy must not promise more than this.

**There is no soft-delete or grace window, deliberately.** The mitigations
are up front instead: a typed-email confirmation, and a confirmation email
after the fact. A reactivation window would require retaining the DEK, which
hollows out the crypto-shred promise: "deleted" would mean "recoverable by us
for N days", which is a different promise. Revisit only with that trade-off
on the table.

**Who gets told.** Deletion sends a confirmation email to the departing
address, but only if it was verified: an address that never proved it was
someone's gets no mail from us, whoever triggered the deletion (#450).

**No data export.** There was a self-serve export (everything the account
owned except secret values); it was removed on 2026-10-12. No account had
ever requested one, and Managoat is a self-hosted application whose operator
holds the database. `/api/account/exports` and the session download answer
`404`.

## Consequences

- Support cannot undo a deletion; the answer to that request is the backup
  retention window and a restore drill, not an app feature.
- Legal questions have one page to point at, and changes to any of these
  properties (retention windows, shred scope) are ADR changes, not
  incidental code review comments.
- The moduledoc stays authoritative for mechanics and points here for the
  why.

## Alternatives considered

- **Soft-delete with a 30-day reactivation window.** Requires retaining the
  DEK, which converts "deleted" into "recoverable by the operator", a weaker
  promise. Rejected while crypto-shred is the promise.
- **Including decrypted secrets in the export** (while there was one). Would
  have made the export the most dangerous file the product produced.
  Secrets are reproducible by their owner; conversations are not. Rejected.

## History

- 2026-08-03 — Decided, recording behavior built in #170/#288/#450: Stripe
  cancellation first as the only aborting step, then sandboxes, audit, row
  delete; the Stripe customer kept for invoices; export beside deletion.
- 2026-10-12 — Stripe removed with credits (#2609), so deletion no longer
  cancels a subscription and starts at sandbox destruction.
- 2026-10-12 — Data export removed (`Fountain.Exports`, the `AccountExport`
  worker, the export routes and card); migration `20261012170000` drops
  `account_exports`.
- 2026-10-14 — The unverified-account pruner removed with the SaaS front door
  (#2633), leaving two triggers.
- 2026-10-15 — Usage metering removed ([0079](0079-usage-is-plain-counts.md));
  `usage_events` leaves the tables that nilify.
