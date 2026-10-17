---
type: ADR
title: "Verified ACP transport bundles"
description: "A pinned ACP adapter reaches a sandbox only as its verified transport bundle, which the server release carries, the host checks against the compiled SHA-512 and uploads for the sandbox installer; every provider runs the image's CLI, and any failure fails provisioning."
tags: [runtimes, provisioning]
status: stable
adr: "0092"
adr_status: "Accepted"
date: 2026-10-16
---

# 0092 — Verified ACP transport bundles

**Status:** Accepted — built. The bundle has been the only install path since
2026-10-17.

## Context

[#2918](https://github.com/managoat/managoat/issues/2918) investigated the
connection cost of installing many small pinned ACP dependencies. The image CLI
reuse path already omits the largest native packages, leaving a portable tree
that can travel as one archive.

The first version of this decision made that archive optional: the sandbox
downloaded it through the broker after the network floor and, on any failure,
fell back to the package-by-package manifest installer and then to
`npm install <package>@<version>`. That last fallback ignored the reviewed
lock, so a damaged or mismatched bundle ended in whatever npm resolved that
day. The download was also the largest part of the adapter step: measured on
production on 2026-10-17, the step was 2.2 s at p50 and ended every cold
provision, because it waited for the CA install and the network policy
(1.1 s, then 0.1 s) and then downloaded through the broker (1.0 s, 0.3 s of it
GitHub's redirect to a second host).

## Decision

The TSV lock in `apps/fountain/priv/runtimes/acp/` stays the sole
package-resolution source. Every pinned adapter has a reviewed `.bundle.json`
sidecar binding its gzip and zstd transport artifacts to the lock's SHA-256,
and the artifacts are published as immutable GitHub release assets. A pin
without a sidecar, or a sidecar that no longer matches its lock, fails to
compile.

The bundle is the only way an adapter gets into a sandbox, and neither the
sandbox nor the running server downloads it. Building the server release
fetches each pinned gzip artifact from its release tag, refuses one whose size
or SHA-512 differs from the compiled record, and puts it in the release's
`priv/`. The host reads it once per node, verifies its size and SHA-512 again
before keeping it in memory, and uploads it through the provider file API.
The sandbox verifies the file against the compiled SHA-512 before extracting
it into staging, and publishes staging only after successful extraction,
swapping the versioned directory and launcher atomically.

On a fresh provision this runs beside the CA install, before the network
policy, with an installer that runs nothing reaching the network, so
[ADR 0019](0019-egress-credential-brokerage.md)'s order holds. If that does not
install the pin, the host uploads and installs once more after the floor; a
reattach or a repair before spawn does the same after its pin check misses.

The bundle carries no native CLI, so every provider runs the image's `claude`
or `codex` at or above the pinned floor: Sprites already did, and E2B does
from 2026-10-17. Any failure of the final attempt fails the install and the
provision with a message naming the step and no URL or credential: a bundle
the release does not carry or that does not verify, a file upload the sandbox refuses, no usable image
CLI, a sandbox that is not Linux x64 glibc, a SHA-512 mismatch in the sandbox,
or an archive that does not extract. There is no manifest, npm or sandbox
download fallback.

## Consequences

- One install path, measured by one set of phases, that honours the lock in
  every outcome. Install timing reports `lock_wait`, `image_probe`,
  `bundle_extract` (unpacked and hashed together), `finalize` (with
  `node_wait`) and `link`; the span carries the total and the outcome.
- The adapter install needs no sandbox egress, so a `limited` allowlist needs
  no entry for it.
- A provision depends on no network fetch of its own: no deadline, lock or
  GitHub outage sits in front of a cold provision (#2970). The release build
  needs outbound HTTPS to the GitHub release instead, and fails when a pinned
  bundle is missing or does not verify.
- The server image grows by the pinned bundles' compressed size, about 9.5 MB
  for claude 0.81.2 and codex 2.2.2. Only the current pins ship.
- Each pinned bundle costs the host its compressed size in memory (7.3 MB for
  claude and 2.2 MB for codex in gzip), held once and sent in 256 KB stdin
  chunks. A bundle carrying native CLIs (the codex platform package alone is
  163 MB) is out of scope: it would make the host hold and send that per pin.
- An image without a working CLI at the floor can no longer provision that
  runtime. A self-hosted E2B template must install current `claude` and
  `codex`, as `images/e2b/e2b.Dockerfile` does.
- A pin bump needs its bundle published before a server release carries it,
  or every provision of that runtime fails.
- Gzip needs no decompressor beyond `tar`; zstd is published but unused.

## Alternatives considered

- Keep the manifest and npm fallbacks: they hide a broken bundle, and the npm
  one ignores the lock.
- Keep the sandbox download as a fallback: a second delivery path to keep
  working, which a `limited` allowlist blocks unless it names GitHub.
- Native CLI bundles for images without one: hundreds of megabytes held by
  the host and sent per provision.
- More download workers, runtime dependency resolution, required zstd: each
  adds work or gives up the lock.
- Fetching the bundle at runtime, once per node, under a cluster-wide lock
  (the first built version): every cold provision after a deploy waited on
  one unbounded GitHub download, and a GitHub outage failed them all (#2970).
  A deadline plus a retry would have bounded the wait but kept the dependency.
- Committing the bundles to the repository: about 9.5 MB of binaries per pin
  bump in history, where a build-time fetch checked against the compiled
  SHA-512 gives the same bytes.

## History

- 2026-10-16 — Accepted: optional bundles downloaded by the sandbox through the
  proxy on the Sprites image-reuse path, with manifest and npm fallbacks (#2932).
- 2026-10-17 — The host pushes the bundle and the sandbox installs it offline
  before the floor; the download becomes the fallback (#2939).
- 2026-10-17 — The bundle streams into the installer's stdin instead of a file
  write followed by an extract (#2956).
- 2026-10-17 — Bundle only, fail closed: the manifest installer, its shard and
  retry lanes, the npm fallback and the sandbox download removed; a pin without
  a bundle fails to compile; E2B runs the image CLI too.

- 2026-10-17 — Revert #2956's stdin delivery, concurrent image probe, Node
  resolution shortcut and first-launch pin-check skip to isolate the cold-turn
  stalls in #2964. Bundle delivery again uses the provider file API, the image
  probe runs before extraction, Node is resolved through its shim, and every
  launch checks the installed pin. Preserve #2954's bundle-only, fail-closed
  policy and E2B image CLI reuse. This is an isolation experiment; it does not
  establish that #2956 caused the stalls.
- 2026-10-17 — Each install gets a directory of its own and is published by
  moving the PATH link alone; a repair no longer deletes the directory a running
  adapter uses. The lock wait is bounded at 30 s, the installer stops itself
  before the host's exec deadline, and a failure stops the background Node
  lookup (#2969). The `swap` phase is gone with the directory swap.
- 2026-10-17 — The server release carries the pinned bundles, fetched and
  verified when it is built; the host's runtime fetch and its `:global` lock
  are removed (#2970).
