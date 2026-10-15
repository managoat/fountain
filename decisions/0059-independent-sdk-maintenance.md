---
type: ADR
title: "Independent SDK maintenance and source releases"
description: "TypeScript is the one maintained SDK; its openapi.ts is regenerated from the server in CI, and an SDK major follows each server release that removes or changes what it exposes."
tags: [sdk, distribution]
status: stable
adr: "0059"
adr_status: "Accepted"
date: 2026-09-17
---

# 0059 — Independent SDK maintenance and source releases

**Status:** Accepted 2026-09-17; amended 2026-10-12 to one SDK and
2026-10-13 to drop the catalog and conformance matrix; 2026-10-15 to state
what an SDK major promises, to mark the retired SDKs' registries and to remove
the contract layer. See the addenda at the
end: the text above them describes four SDKs, of which only TypeScript
remains.

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

## Addendum — 2026-10-12: TypeScript is the one SDK

Fountain stopped being sold as a hosted service on 2026-10-12 and became a
self-hosted app. Four clients for one API cost a CI job, a release gate, a
publisher, a contract manifest and a conformance adapter each, and in the 30
days before the decision the hosted instance had two active users. The
maintainer (Jake) decided to keep one SDK.

**Decision.** TypeScript (`@managoat/fountain-sdk`) is the one maintained SDK.
`sdk/python`, `sdk/elixir`, `sdk/swift` and the root `Package.swift` are
deleted, with their CI jobs (`python-sdk`, `elixir-sdk`, `swift-sdk`), release
gates and publishers, the release workflow's Swift snapshot job, their
contract manifests and propagation probes, their conformance matrix columns,
the Swift wire-model generator and their manual pages. The Go CLI (`cli/`) is
unaffected. The contract (`sdk/contract`), the omissions allowlist, the
conformance scenarios and `sdk/catalog.json` stay, with TypeScript as their
one registered client, so adding a client later is the same procedure as
before. Operations only the removed clients claimed are recorded in
`sdk/contract/omissions.json`.

**What stays published.** `fountain-agent-sdk` on PyPI, `fountain_sdk` on Hex
and the `sdk-swift-v*` and historical `v*` tags that SwiftPM resolves are left
where they are. They are not yanked, retired on their registries or moved;
they are no longer maintained or tested against new servers, and the manual
and `SDKs.md` say so. A deprecation notice in their own READMEs is not
possible without one more release, which this decision does not make.

**Consequences.** The independent-release machinery above (catalog, ownership,
release-tag recorder, gates) applies to TypeScript alone. Swift's
revision-pinned release scheme and its compatibility baseline are moot.
swift-goat, which consumes FountainKit (ADR 0041), keeps working at whatever
revision it pins and receives no further releases.
[ADR 0041](0041-typed-swift-client.md) is retired by this addendum.

## Addendum — 2026-10-13: no catalog, no shared conformance matrix

With one SDK, the machinery for registering several had nothing left to
check. `sdk/catalog.json`, the generated `SDKs.md` and `scripts/sdk-catalog.py`
are removed, with the catalog half of the maintenance tests. The
language-neutral conformance suite (`sdk/conformance`: its matrix, its lint
and its README) is removed too. Its 26 scenarios all ran on TypeScript, so
they move unchanged to `sdk/typescript/test/scenarios` and run in `npm test`,
and the lint's one check that guarded more than the format, every fixture
body against the schema `sdk/contract/contract.json` declares, moves into
that test.

What stays: the TypeScript package's own manifest, version, changelog,
release gate, publisher and release-tag recorder; `CODEOWNERS`; and
`sdk/contract` with its drift checks (`verify-contract`, the
`check-propagation.py` probes for TypeScript and the CLI), which catch real
API breaks. The procedure for adding an SDK above no longer applies; a new
client would bring its own CI job and checks.

## Addendum — 2026-10-15: what an SDK major promises

The TypeScript changelog used to say the REST API is additive, so a given
SDK release keeps working against later servers. Since 2026-09-13 the server
has removed credits, Connections, outbound webhooks, the compatibility
protocols (ADR 0057), claimable principals, reapply, the runner and
persistent sandboxes, and the SDK went from 3.0.0 to 8.0.0 in a month
([#2669](https://github.com/managoat/fountain/issues/2669)). The promise was
false and nothing tested it.

**Decision.** The TypeScript SDK states a support policy in place of the
promise, at the top of `sdk/typescript/CHANGELOG.md` and in the manual's SDK
page:

- A major version removes or changes public SDK API, generated types
  included. One follows each server release that removes or changes
  something the SDK exposes, and its entry names that server release.
- Each release is tested against the server built from the same commit and
  nothing else. An older major gets no fixes and has no support window; it
  works against a newer server only while the routes it calls survive.
- A breaking API change is announced under **Upgrade notes** in the server
  changelog of the release that makes it, then in the SDK major that follows.
- Release dates in the SDK changelog are the UTC day npm published the
  version.

The server's API keeps no compatibility window either: pre-1.0, a minor
release may remove an endpoint, as the server changelog's header already
says. A deprecation period before a removal is not promised and not built.

**The retired SDKs.** `fountain-agent-sdk` (PyPI), `fountain_sdk` (Hex) and
the `sdk-swift-v*` tags are listed as unmaintained wherever this repository
lists them (README, the manual's SDK and open-source pages,
`contributing/sdk-maintenance.md`). Nothing in this repository publishes
them any longer, so no in-repo change reaches their registry pages. Marking
the registries themselves (`mix hex.retire`, a final PyPI or Swift release
saying "unmaintained") is an outward-facing action left to the maintainer
and is not done by this addendum.

## Addendum — 2026-10-15: the registries are marked

This revises "What stays published" in the 2026-10-12 addendum and the
maintainer action left open under "The retired SDKs" above. Users of the
retired SDKs got no signal at install time
([#2669](https://github.com/managoat/fountain/issues/2669)), and two of the
three registries can carry one without a new release. The maintainer (Jake)
approved marking them.

- **Hex.** Every published `fountain_sdk` release (0.1.0 to 0.8.0) is retired
  with reason `deprecated` and the message "Unmaintained since 2026-10-12: use
  the TypeScript SDK @managoat/fountain-sdk or the REST API,
  https://managoat.com/docs/api". Retired releases stay installable; Mix warns
  when it resolves one. The retirement ran once from a dispatch-only workflow
  using the repository's `HEX_API_KEY` secret, and the workflow was deleted
  afterwards.
- **PyPI.** The maintainer archives the `fountain-agent-sdk` project by hand.
  Archived releases stay installable and the project page says it is
  archived. Nothing in this repository does it.
- **Swift.** The `sdk-swift-v*` and historical `v*` tags stay as they are.
  SwiftPM consumers pin a revision, so a new "unmaintained" tag would reach no
  existing pin, and moving or deleting a tag would break builds that pin it.

## Addendum — 2026-10-15: the contract layer is removed

This revises "What stays" in the 2026-10-13 addendum. `sdk/contract` existed
to cross-check several clients against one API: a shape-only projection of
the OpenAPI document (`contract.json`), a manifest per client naming the
operations and fields its handwritten code reached for, an omissions list
for operations no client wrapped, and probes that injected a field and
watched it reach each client's requests. With one generated SDK there is
nothing left to cross-check. The generated `openapi.ts` already covers the
whole document, and a TypeScript change that breaks against it fails the
SDK's typecheck. The maintainer (Jake) decided on 2026-10-15 to remove the
layer.

**Decision.** Removed: `sdk/contract` (`contract.json`, `manifests/`,
`omissions.json`, `propagation/`, its README),
`scripts/sdk-contract/build.py` and `build.sh`, `check-propagation.py`,
the SDK's `verify-contract` script, and the CI steps "SDK wire contract is
current", "Additive conversation fields" (TypeScript and CLI) and
"TypeScript SDK contract". Two checks that read `contract.json` went with it:
the wire scenarios no longer validate fixture bodies against the declared
response schema, and the `Block.body` JSON Schema test is gone. `build.py`'s
two document lints, a property with a `default` listed as required (#1408)
and a `nullable: true` wrapper whose composition refuses null (#1899), moved
to ExUnit tests over `FountainWeb.ApiSpec` in `schema_guardrail_test.exs`.

**What stays.** `scripts/sdk-contract/generate.py` exports the server's
OpenAPI document, sorts its keys and regenerates
`sdk/typescript/src/generated/openapi.ts`; with `--check` it fails on a
diff. CI runs it in `release-and-contract`, and the release workflow uses its
export to attach `openapi.json` to a tag. The CLI has no generated types and
no automated check against the document. The Elixir schema guard
(`FountainWeb.SchemaGuard`), which checks rendered responses against their
declared schemas, is unaffected.
