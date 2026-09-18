---
type: ADR
title: "Independent SDK maintenance and source releases"
description: "Keep native SDK manifests and independent releases, enforce ownership and support metadata, and publish Swift with revision-pinned source tags."
tags: [sdk, distribution]
status: stable
adr: "0059"
adr_status: "Accepted"
date: 2026-09-17
---

# 0059 — Independent SDK maintenance and source releases

## Context

[#1414](https://github.com/managoat/fountain/issues/1414) requires explicit ownership,
independent versions, consistent release tags and a checked support catalog.
TypeScript, Python and Elixir already publish separate registry packages. Swift
was stamped from the server version and resolved through the server's `v*` tags.
SwiftPM does not interpret a language-prefixed Git tag as a semantic version.
Keeping that resolver convention would leave Swift coupled to server releases.

## Decision

Keep each SDK's native package structure, manifest and independent version. Record
maintenance metadata in `sdk/catalog.json`; generate the root catalog from it,
the manifests and the shared conformance matrix. CI checks ownership, release and
contract hooks, and identifying versions. Source/packaging changes need a version
and changelog; tests and documentation do not. Retain the explicit, reviewed
`release:skip-sdk` exception for work intentionally held for a later release.

New releases use `sdk-<language>-v<version>` source tags. Registry uploads remain
CI-only, idempotent and independently serialized. Existing registry credentials
remain in their publishers: OIDC where supported, the dedicated Hex API key for
Hex, and the job token for Swift source tags. Historical tags stay valid.

Swift's two products share `sdk/swift/version.json`, beginning at 0.20.0, and an
independent CI publisher. Consumers use `revision:` with the language-qualified
tag or its commit SHA. Server tags remain consumable snapshots and stop bumping
the Swift constants. Swift's compatibility baseline follows Swift release tags,
with `v0.19.0` as the migration fallback. Maintainer choice for #1414 explicitly
accepts revision-pinned installs in exchange for independent Swift releases.

## Consequences

A server release and a change to one client no longer force another SDK version.
New SDKs need explicit ownership, support and release wiring before CI accepts
registration. The catalog describes checkout versions and declared conformance;
registry links and CI evidence establish publication and passing behavior.

Swift apps update pins deliberately instead of receiving independent SDK releases
through version ranges. SwiftPM prevents a version-based package from depending
on a revision-based package, so those library consumers retain the server snapshot
route or must also use revisions. This limitation is documented in the install
instructions. No new package repository or registry is introduced.

## Alternatives considered

- Retain server-coupled Swift releases — preserves version ranges but fails the
  requested independent-release contract.
- Split Swift into another repository or establish a Swift registry — would
  preserve semantic version resolution, but adds a distribution system outside
  this issue's scope.
- Centralize manifests and versions — would replace native packaging tools and
  force unrelated SDKs through one release mechanism.

## Implementation status

This change adds the catalog, ownership and gates, standardizes future registry
tags, and introduces Swift's independent publisher and consumer checks. The first
`sdk-swift-v0.20.0` release is not published until the implementation merges and
its publisher succeeds. Historical tags are unchanged.
