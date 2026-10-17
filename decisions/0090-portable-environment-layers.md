---
type: ADR
title: "Optional portable environment layers"
description: "Retired 2026-10-17: removed; portable environment state must come from the sandbox provider (provider snapshot or clone), not something Managoat builds. Was: an optional encrypted environment cache that Managoat built, stored and restored itself."
tags: [sandbox, environments, security, performance]
status: deprecated
adr: "0090"
adr_status: "Retired"
date: 2026-10-16
---

# 0090 — Optional portable environment layers

**Status:** Retired 2026-10-17 (Jake): "we should rip environment checkpoints
back out. We need our sandbox providers to give us that functionality and we
shouldn't build it ourselves." The build pipeline, the encrypted artifact store,
the launch-time restore, the `managoat-layer` helper, and the environment
fields `cache_enabled` and `build_script` were removed. Portable environment
state must come from the sandbox provider, through a provider snapshot or
clone, and not from anything Managoat builds, stores or restores. Until a
provider offers that, every conversation's sandbox is set up cold under
[0073](0073-one-sandbox-per-conversation.md).

This ADR is kept as a tombstone so its number and links stay stable. Its full
text is
[at ee93c83c](https://github.com/managoat/managoat/blob/ee93c83ce0d16bfb68dc6bb9f3956d24835b00c0/decisions/0090-portable-environment-layers.md),
and the measurements it rested on are
[at the same commit](https://github.com/managoat/managoat/blob/ee93c83ce0d16bfb68dc6bb9f3956d24835b00c0/contributing/environment-layer-measurements.md).
