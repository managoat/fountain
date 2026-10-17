# Remaining broker download work

This is the #2948 inventory at `5e4256aac` (2026-10-17), after #2939 and #2940 merged.
It separates bytes avoided by existing work from optimizations still requiring
production measurements. File sizes below come from pinned bundle metadata,
not observed transfer counters or startup benchmarks.

| Traffic | Current handling | Remaining work |
|---|---|---|
| Claude adapter on eligible fresh Sprites | Host fetches and verifies the 7,317,052-byte gzip bundle once per node/pin, then pushes it through the provider API; the sandbox installer is offline | Measure the deployed preload success/fallback rate, full launch time and provider-transfer bytes |
| Codex adapter on eligible fresh Sprites | Same path, with a 2,232,346-byte gzip bundle | Same measurement; do not confuse the adapter with the much larger native CLI |
| Accepted image CLI on Sprites | Existing version/shape probe avoids the native CLI download | Track fallback cases after image updates; retain the pinned compatibility floor |
| Codex CLI on E2B | Image reuse landed in [#2940](https://github.com/managoat/managoat/pull/2940) | Validate the deployed change rather than introduce a second cache |
| Missing or explicitly versioned apt packages | Index update and install still traverse the broker | [#2850](https://github.com/managoat/managoat/issues/2850) owns successful cold measurements; [#2947](https://github.com/managoat/managoat/issues/2947) owns HTTP transport work |
| Requested apt packages already installed | Existing plain-name dpkg check skips acquisition | Preserve existing semantics; version/release selectors still need normal apt resolution |
| npm packages, repositories and tenant setup scripts | Existing ordinary provisioning paths | Inventory actual remaining transfer bytes before selecting another cache |

The bundle records are in `apps/fountain/priv/runtimes/acp/*.bundle.json`.
The [bundle procedure](acp-bundles.md) describes verification, image eligibility,
concurrent-fetch serialization, atomic installation and cold fallback. Host
preload removes these bundles from the sandbox's broker-download path, but does
not eliminate their transfer into each sandbox. Moving bytes to the provider
API is not the same as making all network bytes free.

## Decision for this pass

Do not recreate portable environment caching. [ADR 0090](../decisions/0090-portable-environment-layers.md)
was explicitly retired at the maintainer's direction: provider snapshots/clones
must supply that capability. The historical [#2916](https://github.com/managoat/managoat/issues/2916)
reported a 53.6-second restore for a tiny fixture, dominated by compatibility
probing; that is evidence against assuming a cache is beneficial, not a
benchmark of the current removed implementation. Images and provider-native
reuse remain candidates, with exact freshness, identity and isolation semantics
to qualify when a concrete provider capability is selected.

Do not add a managed shared package cache without a measured remaining package
workload. That creates another availability dependency and, for private
repositories, an authorization boundary. A cache cannot skip package signature
checks, change installation recommendations, omit security indexes or cross
private tenant boundaries. Measure the ordinary no-cache path and include
cache creation, refresh, storage, transfer and restore costs in any proposal.

Do not reverse the broker-home work merely to relocate public downloads.
[#2942](https://github.com/managoat/managoat/pull/2942) was open at the inventory
revision and removes the separate remote broker. Revisit placement only if
post-preload and post-transport measurements show that authenticated traffic
still justifies the extra service. Geographic proximity can reduce round trips;
a replacement proxy at the same location still carries the same bytes.

These are scope decisions, not claims that the remaining startup cost is solved.
A full production cold/warm comparison has not been run for this inventory.

## Required follow-through

Use the existing [conversation load-test procedure](../scripts/load-test/README.md)
and record the deployed release, provider/image, region, concurrency and package
selection. Run no-extra-package controls and actual missing-package cases,
checking the image's installed contents first. Keep successful samples and
failures distinct. Collect:

- Full provisioning wall time and tails, not sums of overlapping spans.
- Preload success/fallback and image-CLI reuse, plus actual bundle/CLI downloads.
- apt update, fetch and install separately, preserving package and security-update semantics.
- Broker payload bytes, host-origin fetch bytes and provider upload bytes separately.
- A cache-disabled control for any future provider snapshot/cache experiment.

The public-transfer/redirect runner introduced by
[#2951](https://github.com/managoat/managoat/pull/2951) can isolate individual
payload paths with integrity checks; it cannot replace a full provisioning
comparison or measure provider billing. Once these measurements exist, select
one remaining dominant workload instead of adding another general caching
subsystem. Keep #2948 open until that deployed evidence is recorded or its
remaining work is explicitly reassigned.
