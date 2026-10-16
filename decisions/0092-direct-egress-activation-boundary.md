---
type: ADR
title: "Activate direct-egress policy only across confirmed machine destruction"
description: "Proposed, unbuilt: version policy changes and confirm old provider machines are absent before activating protected policy; qualify restrictive creation separately."
tags: [security, sandbox, egress, lifecycle]
status: draft
adr: "0092"
adr_status: "Proposed"
date: 2026-10-16
---

# 0092 — Direct-egress policy activation boundary

**Status:** Proposed, not implemented. Ordinary conversations remain broker-only
under [0019](0019-egress-credential-brokerage.md). This proposal does not enable
direct egress or change existing mutation API behavior.

## Context

[Issue #2889](https://github.com/managoat/managoat/issues/2889) investigates
selective direct downloads. [The qualification report](https://github.com/managoat/managoat/blob/155248893/contributing/selective-egress-investigation.md)
records live failures of policy-update acknowledgement as a revocation barrier:
Sprite admitted fresh requests after acknowledgement; hosted E2B retained
working HTTP connections after deny-all. Waiting a fixed interval does not
establish enforcement. Replacing proxy environment variables does not close
sockets or constrain adversarial processes.

The current `Fountain.Machines.Destroy` protocol fences work and retires the
row even when provider destruction fails, leaving the reaper to retry. That is
an operational retirement result, not proof that remote code and sockets no
longer exist. `status = terminated`, a local process exit, broker-session
revocation, and absence from a truncated provider list are not deletion proof.

A bounded follow-up experiment destroyed live synthetic clients on both
providers. After successful deletion and absence checks, the origin's request
count remained unchanged through a three-second observation. Fresh restrictive
replacements failed all three test requests per provider. This supports pursuing
recreation, but neither proves a universal provider contract nor qualifies
Sprite's post-create policy update as an atomic startup barrier.

## Proposed decision

For the first direct-egress implementation, make the effective direct policy
immutable for a machine's lifetime. Any potentially relevant policy change
requires ending the affected direct machines and confirming their absence at
the provider before activating the new generation. Do not update a running
direct machine into a newly protected policy. Do not silently preserve or
restore its process memory or sockets.

### Versioned activation operation

Persist an operation with owner, requested generation, expected active
generation, sanitized change metadata, affected immutable provider identities,
per-machine deletion evidence and state. Store secret-bearing proposed values
only in the existing encrypted storage model, never in the operation journal.
Use these externally distinguishable states:

| State | Meaning |
|---|---|
| `pending` | Desired change stored; old generation remains active; new direct admissions blocked. |
| `retiring` | Affected machines fenced and deletion being attempted. |
| `blocked` | Deletion or provider absence is uncertain; no activation or direct admissions. |
| `active` | All deletion barriers passed and generation committed. |
| `superseded` | A newer desired change replaces this operation; it cannot activate. |

The initial implementation may conservatively fence all direct machines for
the owner instead of computing a fragile minimal dependency set. Scope every
lookup by `user_id`. Serialize generation changes and direct admissions through
an owner-level database lock, using the repository's established lock order.
A launch reserves its generation and machine identity under this same fence;
recheck the generation before tenant execution. Include in-flight provisioning,
running and suspended machines. An unknown outcome from provider creation is an
unresolved machine identity that blocks activation until reconciled.

Relevant changes include environment destination rules and assignments, explicit
bindings, built-in/inference/MCP credential destinations, vault/environment
secret delivery and agent/runtime settings affecting those inputs. Operator
eligibility changes need an instance-wide admission fence and per-owner fanout.
All mutation entry points, including imports and background updates, must use
the protocol before direct mode can be enabled. Unknown overlap means revoke
conservatively. A deploy that changes the policy compiler also changes its
version and invalidates incompatible direct generations.

### Retirement barrier

1. Commit the pending operation and admission fence before remote side effects.
2. Use the existing machine ownership/lease protocol to fence commands, file
   operations, turns and wake. Cancel affected runs explicitly; revoke broker
   sessions as defense in depth. Local fencing alone does not stop remote code.
3. Request provider destruction for every recorded identity. Keep the retirement
   operation independently durable even if the normal machine row becomes terminal.
4. Require a successful provider deletion (or explicit not-found), followed by
   an authoritative identity lookup returning not-found. Authentication errors,
   timeouts, inconsistent results and incomplete listings are unknown, never
   absent. Do not recreate or reuse a name while absence is being established.
   The current E2B name lookup/listing must not substitute for an immutable-ID
   check in the production contract.
5. Record the evidence against the exact machine identity and pending generation.
   A worker crash retries idempotently; it must not lose an unresolved machine
   when the ordinary lifecycle finalizes its row.
6. In one database transaction, compare-and-swap the expected generation, verify
   every required barrier and commit the desired change plus active generation.
   Audit the actual activation afterward, with caller attribution and no values.

Activation is not retroactive: traffic may continue under the previous policy
while deletion is pending. The API/UI must say that revocation is pending and
must not present the desired change as enforced. A failed deletion leaves it
blocked with retry/reconciliation, not falsely successful. Cancellation cannot
revive destroyed machines. If a later operation supersedes one already retiring,
finish cleanup and use the latest desired generation; do not resurrect an old one.

Do not hold a database transaction open across provider calls. An API accepting
a potentially asynchronous change returns an operation identifier and a pending
status; clients poll/read its actual activation state. Existing synchronous
success responses must not be reused to imply enforcement. This is an API
contract change requiring OpenAPI, SDK generation and client behavior tests.

### Fresh-machine admission

After activation, a later run obtains a new machine identity and a policy
compiled from the active generation. Provider capability qualification must
establish that restrictive networking is effective before any tenant process,
startup hook or credential is introduced. Only a trusted base and trusted
bootstrap helper may run before that boundary.

[Hosted E2B supports network settings in the create request](https://docs.e2b.dev/network/internet-access); the prototype used
that path successfully. The current Managoat E2B adapter does not send those
settings at creation and needs an explicit, tested capability before admission.
Use immutable provider IDs rather than adopting an existing named machine with
unknown history. Qualify the actual configured provider; hosted E2B evidence
does not certify Loam or a custom template.

The [documented Sprite create request](https://docs.sprites.dev/api/dev-latest/sprites/)
exposes no network-policy field, and our
adapter applies policy after creation. The three blocked fresh-Sprite probes
are not an atomic enforcement guarantee. Keep direct mode unavailable on Sprite
until a provider-supported startup barrier is established and tested. Do not
turn a handful of denied requests into a production readiness test.

First-slice direct machines do not resume or restore memory. Any resume path
requiring a changed policy retires the old machine and requires a new run.
Copying a filesystem or invoking a checkpoint can introduce startup hooks and
credentials; it is not an implicit exception to admission. Broader disk/state
migration and transparent conversation continuation are separate work.

### The environment artifact exception

[0090](0090-portable-environment-layers.md) fetches on the machine that later
receives keys and executes tenant code. Its narrow-before-key boundary cannot
rely solely on a network-update response. Destroying that machine loses the
staged artifact, so recreation is not a drop-in implementation of that sequence.

For its first safe implementation, retain brokered delivery to the final
machine, or design a separate disposable fetcher with a qualified handoff of
only authenticated artifact bytes to an already restricted destination. A
second fetch must not reopen direct access on that destination. This proposal
does not accept a new artifact transport or amend 0090's decision by implication.

## Implementation slices and acceptance

1. **Deletion evidence contract:** add an outcome separate from ordinary
   retirement, backed by exact provider identity and authoritative absence.
   Test delete failure, lost acknowledgement, not-found, provider-list
   truncation, worker crash and ordinary terminal-row cleanup. Preserve the
   existing operational finalization behavior for other callers.
2. **Generation coordinator:** durable operation, admission fence, idempotent
   cleanup and activation CAS. Test a launch racing a binding change, two
   concurrent changes, a suspended direct machine, restart after fencing,
   deletion failure and crash before/after activation. No test may accept a
   merely terminal database row as proof.
3. **Qualified creation:** E2B create-time policy and immutable identity contract,
   safe template qualification and retry reconciliation. Keep Sprite capability
   false. Test that no credentials or tenant exec occur before admission and
   that provider configuration changes invalidate qualification.
4. **Public contract and integration:** pending/blocked/active UX and API,
   tenant-scoped audit, generated SDK types, meaningful wire behavior tests,
   complete mutation-path inventory and explicit cancellation of affected runs.
5. **Enablement gate:** rerun adversarial destination/client/injection tests,
   lifecycle fault injection and full cold-start measurements before any opt-in
   production deployment. The recreation prototype passes neither this gate nor
   the still-missing shared-CDN/Host isolation qualification.

## Consequences

Policy changes can interrupt work and discard local machine state. That cost
must be explicit when direct mode is introduced; users must not discover a
silent destructive migration on a routine binding edit. Until the full protocol
exists, keep direct mode disabled and prefer the remote broker in
[0091](0091-remote-broker.md).

The system gains a durable distinction between requested policy, active policy
and a machine that remains remotely alive after local retirement. Provider
outages can delay activation indefinitely; availability does not override the
revocation guarantee. This mechanism cannot recover secrets already sent under
an earlier permission or revoke out-of-band upstream credentials.

## Alternatives considered

- **Policy-update acknowledgement:** disproved as a revocation barrier by the
  qualification tests.
- **Sleep or poll a canary until it fails:** detects some delay; cannot prove all
  established flows, ports and address families have been revoked.
- **Kill the runtime or suspend:** descendants, services and restored sockets
  are not reliably covered; not equivalent to machine destruction.
- **Trust terminal database status:** provider deletion can fail after local
  fencing; the reaper's future retry is not present enforcement.
- **Provider enforce-and-disconnect primitive:** preferable if its contract and
  behavior are established; neither current adapter exposes a qualified one.
- **Keep all payloads brokered:** remains the production default, and remote
  placement improves delivery without introducing this direct-access lifecycle.
