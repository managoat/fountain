---
type: ADR
title: "Verified ACP transport bundles"
description: "Keep TSV dependency locks authoritative and optionally transport their image-reuse package trees as checksum-pinned bundles, pushed by the host and installed offline before the network floor, with download, package and npm fallbacks."
tags: [runtimes, provisioning]
status: stable
adr: "0092"
adr_status: "Accepted"
date: 2026-10-16
---

# 0092 — Verified ACP transport bundles

**Status:** Accepted — implementation and initial artifact publication are
complete. Production activation follows the server release process.

## Context

[#2918](https://github.com/managoat/managoat/issues/2918) investigates the
connection cost of installing many small pinned ACP dependencies. Increasing
workers benefits runtimes differently and adds TLS contention. The image CLI
reuse path already omits the largest native packages, leaving a portable tree
that can travel over one connection.

## Decision

Keep the existing TSV dependency lock as the sole package-resolution source.
Build optional immutable gzip and zstd transport bundles from its verified
package bytes and bind their checksums to the TSV digest in a reviewed sidecar.
Publish them as separate GitHub release assets. Use the image-reuse bundle only
on the validated Linux x64 glibc image path, verify before extraction, and retain
the package installer and npm fallbacks. Do not change worker concurrency or
introduce a runtime dependency resolver or permanent private artifact store.

On a fresh provision the host fetches the gzip bundle itself, verifies it,
keeps it in memory for the node's life, and pushes it into the sandbox through
the provider's file API. The sandbox verifies it again and installs it with an
offline installer that runs nothing reaching the network, so the install runs
beside the CA install and before the network policy without weakening
[ADR 0019](0019-egress-credential-brokerage.md)'s order. When the push or that
install fails, the sandbox downloads the bundle through the proxy after the
floor as before.

## Consequences

The project owns artifact publication and availability, while upstream package
contents and license notices remain unchanged. A missing or damaged artifact
adds a bounded failed attempt before fallback. Gzip permits operation without
provisioning zstd. Future pins can ship without a bundle. Artifact publication
and public-origin measurements must precede a server release enabling this path.
The contributor procedure in `contributing/acp-bundles.md` describes the build,
publication, validation, and fallback boundaries.

Pushing the bundle takes the install off the cold path. Measured on production
on 2026-10-17, the adapter step was 2.2 s at p50 and ended every cold provision,
because it waited for the CA install and the network policy (1.1 s, then 0.1 s)
and then downloaded through the broker (1.0 s, 0.3 s of it GitHub's redirect to
a second host). The host needs outbound HTTPS to the GitHub release; without it,
each provision falls back to the sandbox download. Each pinned bundle costs the
host its compressed size in memory (7.3 MB for claude and 2.2 MB for codex in
gzip).

## Alternatives considered

- More download workers: benefits differ by runtime and TLS setup rises.
- Runtime dependency resolution: gives up the existing reviewed dependency lock.
- Required zstd installation: adds provisioning work to the path being shortened.
- Native CLI bundles: enlarge artifacts and broaden platform scope; the existing
  manifest path remains responsible for sandboxes without an accepted image CLI.
- Starting the sandbox download before the floor: the sandbox would dial out
  before the CA and the policy (ADR 0019).
- Shipping bundles inside the server image: the image would carry adapter
  artifacts for every pin and grow with each one.

## History

- 2026-10-16 — Accepted: bundles downloaded by the sandbox through the proxy (#2932).
- 2026-10-17 — The host pushes the bundle and the sandbox installs it offline before the floor; the download becomes the fallback.
