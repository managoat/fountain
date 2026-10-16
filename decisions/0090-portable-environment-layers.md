---
type: ADR
title: "Optional portable environment layers"
description: "Build an optional encrypted environment cache, separate from conversation identity and platform tooling; runtime integration is not yet built."
tags: [sandbox, environments, security, performance]
status: stable
adr: "0090"
adr_status: "Accepted"
date: 2026-10-16
---

# 0090 — Optional portable environment layers

**Status:** Accepted direction, 2026-10-16. The maintainer asked to pursue the
cache after the [fresh measurements](https://github.com/managoat/managoat/blob/main/contributing/environment-layer-measurements.md).
The experiment and the bounded artifact/helper and store primitives are built.
The production cache catalog, builder and provisioning integration are **not yet
built**; no environment currently selects a cached artifact. Delivery is tracked by
[#2530](https://github.com/managoat/managoat/issues/2530).

## Context

A new conversation gets a new sandbox under
[0073](0073-one-sandbox-per-conversation.md). Packages, repositories and setup
work are repeated even when an environment has not changed. The removed
checkpoint path cannot be re-enabled: it could not restore one Sprite's
checkpoint onto another. Provider-native cloning is not a dependency of this
work.

On 2026-10-16, Managoat's repository setup took 269.4 seconds including
verification. An experimental portable layer restored onto three fresh Sprites;
one fully timed restore, including bootstrap and verification, took 13.0
seconds. Removing rebuildable caches reduced a compressed layer from 580.8 MB
to 245.4 MB. Network cost remains real: downloads of the final 245.5 MB artifact
to `/dev/null` took 3.3, 3.1 and 54.0 seconds. These are small samples, without
production encryption or broker policy, not a launch-latency promise.

The October proposal on #2530 predates two changes: [0023](0023-persistent-agent-sandbox.md)
is now superseded, and normal provisioning writes credentials and runtime files
before setup. An archive of that machine is not a reusable environment template.
This decision extends 0073 and qualifies the restore ordering in
[0019](0019-egress-credential-brokerage.md); it does not revive persistent homes.

## Decision

Implement an optional portable filesystem cache for explicitly opted-in
environments, starting with Sprites and a private Tigris/S3 store. No store,
no opt-in, no compatible artifact, or an unavailable cache leaves cold
provisioning available. Every conversation still owns a separate machine.
No warm pool, retained builder machine, or provider-native fork is required.

### Build inputs and ownership

Build a template in a disposable, separately owned machine using only the
selected environment's declared build inputs. Builders obey the existing
provider fleet ceiling and the machine ownership/lifecycle rules in
[0058](0058-the-machine-has-one-owner.md). Persist build ownership, timeout and
cleanup state; an abandoned builder must be reaped. Deduplicate concurrent
builds for the same input generation without holding a database transaction
across provider or object-store operations.

Do not capture a conversation after setup or after its first turn. Do not pass
vault overrides, inference credentials, callback tokens, conversation history,
agent MCP configuration or runtime auth into the template build. Environment
build credentials remain subject to brokerage; use a build-only session and
revoke it before publishing the artifact. A service or setup script can retain
a credential in an arbitrary file, so filename exclusions are not sufficient
isolation.

Opt-in makes the split explicit: reusable environment setup completes in the
build; a separate boot step starts services and performs per-conversation work
with that conversation's values. Existing setup scripts that depend on vault
values or conversation identity keep the cold behavior until adapted. A build
must wait for its work and quiesce its services before export. Background work
continuing after a setup script returns is not a complete artifact.

### Identity, invalidation and retention

Cache lookup is scoped by both user and environment. Fingerprint a canonical
manifest of provider, architecture, immutable base-image identity, builder
format/version, packages, repository locations and resolved revisions, build
script, and the effective environment values/secret revisions the build sees.
Never expose an unkeyed hash of low-entropy secret values: use a tenant-scoped
keyed digest. Unknown base identity means cold provisioning, not a guessed
compatible restore based only on `/etc/os-release`.

Keep networking policy, runtime adapter pins, broker CA and conversation
identity out of the tenant artifact identity. Apply current networking policy
on every boot. This does not make network access optional during a build: a
policy change must cancel/revalidate an in-flight build that is using an old
policy. Keep platform tooling (bootstrap helper, decompressor, adapters, Node
and trust setup) separate, so updating it does not rebuild a tenant layer.

Revalidate the input generation before publishing or selecting an artifact;
an obsolete builder cannot replace a newer artifact. Repository refresh must
check out the requested revision and invalidate/rebuild when cached build
outputs no longer match it; `git fetch` alone does not update a worktree.
Explicit rebuild and expiry are needed for unpinned external dependencies.

Bound artifact size, build time, transfer time, retries and retention. User or
environment deletion removes access immediately and schedules object cleanup.
Stored artifacts consume storage, not a live sandbox slot. Audit lifecycle
mutations in their context, outside transactions, without secret values,
presigned URLs, encryption keys or command output.

### Encrypted artifacts and restore ordering

Each artifact has a fresh data key wrapped under the owner's envelope key,
bound to user, environment, fingerprint and artifact version. Use authenticated
encryption, tenant-scoped object keys and short-lived presigned URLs. Never
hand the tenant's envelope key or bucket credentials to a sandbox. Authenticate
the entire artifact before extracting it; unauthenticated streaming plaintext
must never reach `tar`.

On a fresh Sprite, use this sequence:

1. With no tenant/session credentials installed, apply a temporary floor
   permitting only the broker and configured object-store endpoint. Run only
   Managoat's trusted fetch helper to stage the encrypted object. Disable
   redirects to other destinations and bound bytes and time. A presigned GET
   capability is the narrowly scoped exception needed for this fetch.
2. Await fetch completion, then narrow the floor to broker-only. If narrowing
   fails, destroy the machine. No extraction, tenant code or artifact decryption
   key is allowed during the wider window.
3. Deliver the one-artifact key, authenticate, validate the archive and its
   manifest, and extract with trusted tooling. Reject unsafe paths, unsupported
   entries and writes to provider control state or the restore helper. Handle
   deletions explicitly, or refuse cache publication when a build requires
   deletions the format cannot represent. A ctime-only tar is not the production
   format. Resource bounds cover decompressed size and entry counts too.
4. Remove transfer/key material; write fresh machine identity, credentials,
   broker trust, skills and runtime configuration. Refresh/check repository
   revisions and run the environment's boot step under the current policy.
5. Report ready only after all required steps complete.

This tightens the earlier “fetch-and-unpack, then narrow” sketch: restored files
can contain credentials and executable hooks, so unpacking belongs after the
floor narrows. The benchmark's streaming timing is therefore not an estimate
for the final authenticated restore path. Measure that path before enabling it.

Before extraction, a missing/expired artifact or failed transfer may take the
ordinary cold path once the floor is confirmed narrow and staged material is
removed. Once extraction has begun, any failure destroys that machine and
starts a fresh cold attempt through the existing owner protocol. Never run
cold setup on a partially restored root filesystem. Permit one cache attempt
per launch; fallback cannot loop back into the same broken artifact.

### Delivery and evidence

The first production slice is the optional cache mechanism and its lifecycle,
not the general snapshot-resource API in closed
[#2595](https://github.com/managoat/managoat/issues/2595). Do not reopen that API
or add arbitrary conversation snapshots to deliver this cache.

Implement and test in this order:

1. A bounded, authenticated artifact format/helper and optional private store;
   tenant/environment isolation, tampering/truncation, archive traversal and
   wrong-base tests precede any provisioning integration.
   Implemented primitives: `cli/cmd/managoat-layer` uses age X25519 encryption
   over a bound manifest and zstd tar; restore verifies the controller's stored
   ciphertext digest and authenticated EOF before archive validation or writes.
   `Fountain.EnvironmentLayers.Store` issues tenant-scoped S3 capabilities and
   `Envelope` wraps each artifact's private identity with metadata as associated
   data. These are internal building blocks, not a configured or packaged cache.
2. A separately owned build lifecycle, explicit build/boot semantics, generation
   invalidation, single-builder coordination, cancellation and retention.
3. Fresh-provision integration before config/skills writes, the two-step floor,
   and fresh-machine fallback after partial extraction. Test provider failures,
   cancellation and key cleanup at every boundary, not only the happy path.
4. A live encrypted/policy-constrained Managoat run, including cache miss, hit,
   input change, repository change, corrupted artifact, transfer timeout and
   disabled storage. Record bytes and each phase, plus cold fallback success.

Preserve `checkpoint_restore` stage events (`started`, `done`, `failed`) for
existing consumers, with sanitized warm/cold reasons and separate build, fetch,
authentication, extraction, boot and fallback timings. Only a completed restore
is warm. A failed cache build must not turn an otherwise usable cold launch
into a failure. A second matching launch must skip the reusable setup work;
a changed build input must produce a new artifact before reuse.

## Consequences

The reusable state lives in encrypted object storage rather than occupying a
machine. Optional caching adds storage, a build lifecycle and cleanup work;
operators without a store retain existing behavior. Setup authors must separate
reusable work from per-boot work to opt in. Generic exclusion of `~/.cache` is
not safe: some projects keep runtime-required browsers or tools there. Exclusions
must be declared or proven rebuildable and covered by post-restore validation.

Cache hits still pay transfer, authentication, extraction and process startup.
Timeouts and cold fallback are part of correctness, not a claim that a slow
transfer can always be hidden. The measured experiment establishes value, not
production readiness or a tail-latency target.

## Alternatives considered

- **Wait for provider-native forks:** an optional later optimization behind the
  same compatibility and lifecycle checks; not required for portable layers.
- **Keep a warm machine pool:** consumes slots and adds replenishment/ownership
  complexity; unnecessary for the measured benefit.
- **Archive a live conversation:** mixes reusable files with vault, identity,
  runtime and user-work state; exclusions cannot reliably separate them.
- **Always rebuild:** remains the default and fallback, but repeats expensive
  toolchain and compilation work for stable environments.
