---
type: ADR
title: "A second Swift client in the SDK package: typed for applications, untyped for scripts"
description: "Retired 2026-10-12: sdk/swift was removed when TypeScript became the one maintained SDK (ADR 0059 addendum). sdk/swift ships two products from one package — `Fountain`, the JSONObject client shaped like its TypeScript, Python and Elixir siblings, and `FountainKit`, a Codable-model client for applications, contributed from swift-goat under Apache-2.0. Both run the shared conformance suite; FountainKit is the `swift-kit` column, green on all 24. They share no code yet, and unifying their HTTP and SSE layers is not built."
tags: [sdk, swift, clients, licensing]
status: deprecated
adr: "0041"
adr_status: "Retired"
date: 2026-09-03
generated: { by: claude-opus/5, at: 2026-09-03T00:00:00-04:00 }
verified: { by: claude-opus/5, at: 2026-09-03T00:00:00-04:00 }
stale_after: 2026-12-03
---

# 0041 — A second Swift client in the SDK package: typed for applications, untyped for scripts

**Status:** Retired 2026-10-12; see the addendum at the end. The text above
the addendum is history. Was: Accepted, 2026-09-03. Built in the PR that adds this file: the
`FountainKit` product, its 26 sources and its tests, the `swift-kit` column in
the conformance matrix, and the version constant CI and the release bump now
stamp. **Not built:** the two clients share no HTTP, SSE or error code. That
duplication is deliberate for now and is the thing to revisit; see
Consequences.

## Context

`sdk/swift` was built to the shape the other three SDKs have: one `Fountain`
object, `JSONObject` in and out, a `run` that hands back text. That shape is
right for what the SDKs are for — a script, a CI step, an agent calling
Fountain from inside a sandbox — and its sameness across four languages is a
feature, because the docs, the contract manifest and the conformance
scenarios all describe one client per language.

It is the wrong shape for an application. swift-goat, the macOS client, needs
models it can bind to a view: `Identifiable` for a list, `Hashable` for a
diff, `Sendable` across an actor boundary, and an enum error it can branch on
to decide what to show. Rather than decode `JSONObject` into its own structs,
it grew a full client of its own — `FountainKit`, about 3,000 lines: Codable
models for every resource, a namespace per API area, a `FountainError` enum
that maps the four error-body shapes, an incremental SSE parser with
`Last-Event-ID` resume, and a `TurnFollower` ported from the TypeScript
SDK's `turn.ts`.

That left two Swift clients for one API, maintained by the same person, one
of them outside this repository and outside the conformance suite. The
question this ADR settles is which one is *the* Swift client.

## Decision

**Both, from one package, for different jobs.** `sdk/swift` declares two
products:

- `Fountain` — unchanged. The SDK, in the shape its siblings have.
- `FountainKit` — the typed client, moved here from swift-goat and
  relicensed to Apache-2.0 by its author, who holds the copyright on every
  commit of it.

They are separate modules that share no types, so neither constrains the
other's API and the published `Fountain` surface does not move. An
application imports one of them; there is no reason to import both.

**Neither is a wrapper over the other.** The typed client is not `Fountain`
with a decoding layer bolted on, and the untyped one is not the typed one
with the types erased. They are two readings of the same wire, and the thing
that keeps them honest is not shared code but shared tests.

**The conformance suite is what makes two clients safe.** FountainKit runs
the same 24 scenarios as its siblings, as the `swift-kit` column in
`sdk/conformance/matrix.json`, from the same files — no vendored copy. A
scenario with no verdict for it fails, in `lint.py` and again in Swift. It is
green on all 24, including `run-timeout-raises-and-keeps-partial-text`, which
`swift` skips (#1424): FountainKit raises the timeout before re-reading the
conversation, so the request the scenario forbids is never sent.

**They release together.** `fountainKitVersion` sits beside
`fountainSDKVersion`; CI asserts both equal `mix.exs`, and the release bump
stamps both. A Swift client that lags the server it names is a support
question nobody can answer.

**The typed client keeps the SDK's platform floor** — macOS 12, iOS 15 —
which cost it `Task.sleep(for:)`, `URL.appending(path:)` and `Never:
Encodable`, and bought it every deployment target the SDK already promises.

## Consequences

The duplication is real and it is the price. Two SSE parsers, two HTTP
layers, two error types, and a wire change that lands in one and not the
other is a bug the conformance suite catches only where a scenario covers
it. The alternative — one client with a typed layer over shared plumbing —
is the better end state and a breaking change to a published API
(`JSONValue` is `Decimal` in one and `Double` in the other; `FountainError`
is a struct in one and an enum in the other), so it wants its own decision
and its own release. Revisit by `stale_after`: either unify, or record that
the duplication has paid for itself.

`sdk/contract/manifests/swift.json` still describes what `Fountain` wraps.
FountainKit wraps more of the API than that manifest claims — admin, audit,
runners, API keys, `apply` — which the contract check tolerates, because it
fails on an operation no manifest claims *and* `omissions.json` does not
match, and those operations are omitted today. Claiming them properly is a
follow-up, not a gap in what ships here.

swift-goat becomes the first consumer, depending on this package instead of
carrying the client. It stays the worked example: a real application on the
typed client, with its own docs mapping the operation surface.

## Addendum — 2026-10-12: retired

`sdk/swift`, with both the `Fountain` and `FountainKit` products, the root
`Package.swift`, the `swift` and `swift-kit` conformance columns, the Swift
contract manifest and the generated wire models, was removed when TypeScript
became Fountain's one maintained SDK
([ADR 0059's addendum](0059-independent-sdk-maintenance.md#addendum--2026-10-12-typescript-is-the-one-sdk)).
The published `sdk-swift-v*` tags stay, unmaintained. The unification this
ADR deferred will not happen here.
