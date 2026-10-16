---
type: ADR
title: "Verified ACP transport bundles"
description: "Keep TSV dependency locks authoritative and optionally transport their image-reuse package trees as checksum-pinned bundles; initial publication and live validation are pending."
tags: [runtimes, provisioning]
status: draft
adr: "0092"
adr_status: "Proposed"
date: 2026-10-16
---

# 0092 — Verified ACP transport bundles

**Status:** Proposed — implementation is under test; initial publication and
public-origin live validation are pending.

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

## Consequences

The project owns artifact publication and availability, while upstream package
contents and license notices remain unchanged. A missing or damaged artifact
adds a bounded failed attempt before fallback. Gzip permits operation without
provisioning zstd. Future pins can ship without a bundle. Artifact publication
and public-origin measurements must precede a server release enabling this path.
The contributor procedure in `contributing/acp-bundles.md` describes the build,
publication, validation, and fallback boundaries.

## Alternatives considered

- More download workers: benefits differ by runtime and TLS setup rises.
- Runtime dependency resolution: gives up the existing reviewed dependency lock.
- Required zstd installation: adds provisioning work to the path being shortened.
- Native CLI bundles: enlarge artifacts and broaden platform scope; the existing
  manifest path remains responsible for sandboxes without an accepted image CLI.
