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

**Status:** Accepted, 2026-09-17. Built.

## Context

[#1414](https://github.com/managoat/fountain/issues/1414) asked for explicit
ownership, independent versions and consistent release tags for the SDKs. At
the time there were four (TypeScript, Python, Elixir, Swift), and Swift was
stamped from the server version and resolved through the server's `v*` tags,
which coupled it to server releases.

Managoat stopped being a hosted service on 2026-10-12. Four clients for one
API cost a CI job, a release gate, a publisher, a contract manifest and a
conformance adapter each, and in the 30 days before that decision the hosted
instance had two active users. The cross-client machinery (a catalog, a shared
conformance matrix, a contract layer) existed to keep several clients
consistent with one API, and has nothing to check with one generated client.

The SDK changelog also once promised the REST API was additive. Between
2026-09-13 and 2026-10-15 the server removed credits, Connections, outbound
webhooks, the compatibility protocols ([0057](0057-retire-public-compatibility-protocols.md)),
claimable principals, reapply, the runner and persistent sandboxes, and the
SDK went from 3.0.0 to 8.0.0 in a month
([#2669](https://github.com/managoat/fountain/issues/2669)). The promise was
false and nothing tested it.

## Decision

**TypeScript (`@managoat/sdk`) is the one maintained SDK.** It keeps its own
manifest, version, changelog, release gate, publisher and release-tag
recorder, and versions independently of the server. Releases are tagged
`sdk-typescript-v<version>`; registry uploads are CI-only and idempotent.
Source and packaging changes need a version and changelog entry; tests and
documentation do not. The reviewed `release:skip-sdk` exception remains for
work held for a later release. The Go CLI (`cli/`) is separate and unaffected.

**Its types are generated from the server.** `scripts/sdk-contract/generate.py`
exports the server's OpenAPI document, sorts its keys and regenerates
`sdk/typescript/src/generated/openapi.ts`; with `--check` it fails on a diff.
CI runs it in `release-and-contract`, and the release workflow uses its export
to attach `openapi.json` to a tag. A TypeScript change that breaks against the
document fails the SDK's typecheck. The wire scenarios live in
`sdk/typescript/test/scenarios` and run in `npm test`. Two document lints (a
property with a `default` listed as required, #1408; a `nullable: true`
wrapper whose composition refuses null, #1899) are ExUnit tests over
`FountainWeb.ApiSpec` in `schema_guardrail_test.exs`. `FountainWeb.SchemaGuard`
checks rendered responses against their declared schemas. The CLI has no
generated types and no automated check against the document.

**An SDK major promises this**, stated at the top of
`sdk/typescript/CHANGELOG.md` and in the manual's SDK page:

- A major version removes or changes public SDK API, generated types
  included. One follows each server release that removes or changes something
  the SDK exposes, and its entry names that server release.
- Each release is tested against the server built from the same commit and
  nothing else. An older major gets no fixes and has no support window; it
  works against a newer server only while the routes it calls survive.
- A breaking API change is announced under Upgrade notes in the server
  changelog of the release that makes it, then in the SDK major that follows.
- Release dates in the SDK changelog are the UTC day npm published the
  version.

The server's API keeps no compatibility window either: pre-1.0, a minor
release may remove an endpoint. A deprecation period before a removal is not
promised and not built.

**The retired SDKs stay where they were published, marked.** Python
(`fountain-agent-sdk`), Elixir (`fountain_sdk`) and Swift are deleted from the
repository with their CI jobs, gates and publishers, and listed as
unmaintained wherever this repository lists them (README, the manual's SDK and
open-source pages, `contributing/sdk-maintenance.md`).

- Hex: every `fountain_sdk` release (0.1.0 to 0.8.0) is retired with reason
  `deprecated` and a message pointing at the TypeScript SDK and the REST API.
  Retired releases stay installable; Mix warns when it resolves one. This ran
  once from a dispatch-only workflow that was then deleted.
- PyPI: the maintainer archives `fountain-agent-sdk` by hand; nothing in this
  repository does it. Archived releases stay installable.
- Swift: the `sdk-swift-v*` and historical `v*` tags stay. SwiftPM consumers
  pin a revision, so a new "unmaintained" tag would reach no existing pin, and
  moving or deleting a tag would break builds that pin it.

## Consequences

- A server release does not force an SDK release unless it removes or changes
  something the SDK exposes; when it does, an SDK major follows.
- Users of an older SDK major upgrade with the server; there is no
  compatibility window to rely on.
- Adding another client later means bringing its own CI job and checks; there
  is no registration procedure or shared conformance suite to join.
- swift-goat, which consumes FountainKit, keeps working at whatever revision
  it pins and receives no further releases;
  [0041](0041-typed-swift-client.md) is retired.

## Alternatives considered

- **Keep four SDKs**: a CI job, gate, publisher and adapter each, for an
  instance with two active users.
- **Keep the catalog, conformance matrix and contract layer for one client**:
  they cross-checked several clients against one API; the generated
  `openapi.ts` already covers the whole document.
- **Keep the additive-API promise**: it was false and untested.
- **Yank or move the retired packages and tags**: would break existing
  installs and pinned builds; marking them gives a signal without that.
- For Swift while it was maintained: server-coupled releases (fails
  independent releases), or a separate repository or registry (a distribution
  system outside #1414's scope).

## History

- 2026-09-17 — Accepted: four SDKs with native packaging and independent versions, `sdk/catalog.json`, `sdk-<language>-v<version>` tags, Swift's own publisher with revision-pinned installs.
- 2026-10-12 — TypeScript is the one SDK; Python, Elixir and Swift deleted from the repository and left published; [0041](0041-typed-swift-client.md) retired.
- 2026-10-13 — Catalog, `SDKs.md` and the shared conformance suite removed; its 26 scenarios moved into the TypeScript tests.
- 2026-10-15 — The additive-API promise replaced by a support policy (#2669); the retired SDKs listed as unmaintained.
- 2026-10-15 — Hex releases of `fountain_sdk` retired; PyPI archive left to the maintainer; Swift tags left as they are.
- 2026-10-15 — The contract layer (`sdk/contract`, propagation probes, `verify-contract`) removed; `generate.py --check` and the schema guardrail tests remain.
