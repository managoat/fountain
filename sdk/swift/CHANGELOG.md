# Changelog

Notable changes to the Fountain Swift SDK follow
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Changed

- `LogEvent.conversationID` and `.agentID` now come from the contract's new
  `StreamLogEvent` schema instead of the handwritten `EXTRA_PROPERTIES` table,
  which is empty again. No public property, name or optionality changed (#2297).

- Generate agent, environment/vault, connection, team, account/catalog/apply and admin resource wire models from the contract. Preserve public names and dynamic JSON APIs; agent inputs support numeric permission policies and explicit nullable fields. Contract fields missing from the handwritten models are exposed as optional properties, including `Catalog.firstRequest`, `Catalog.mcpServers` and `ConnectionProvider.kind`, `.platform`, `.redirectURI`, `.scopes` and `.tokenHosts`, so a response from a server older than these fields still decodes (#2251).

- Generate the Sandbox, Runner and conversation-tree model families from the contract. Preserve public nested types, unknown enums and legacy optional decoding; Usage now includes additive fields from both turn and total schemas (#2251).

- Decode `APIErrorBody` through the generated `APIErrorPayload` (the contract's `Error` schema). Published members keep their names and optionality. `code` stays the body's `error` when that is already a code and `reason` only narrows it, so `credential_set_is_default`, `sandbox_not_resettable` and `broker_unavailable` are no longer reported as their `reason`; the key-auth and scope refusals, whose `error` is a sentence, still take `reason` as the code. New `APIErrorBody.reason` carries the body's `reason` as sent, and a new initializer overload takes it; the published initializer keeps its signature (#2324).

- Generate `PageMeta` from the contract's cursor envelope. `hasMore`, `limit` and `nextCursor` keep their Optional types; `offset` moves to the new `SearchResponse.Meta` (non-Optional members), since only `GET /api/search` ever sent it. `Page<T>` becomes `Page<Items, Meta>`: `audit.list` and `conversations.events` return `Page<[…], PageMeta>`, `search.search` returns `Page<[SearchHit], SearchResponse.Meta>`; `page.meta?.hasMore` reads as before. The generated `AuditEventListResponse`, `LogEventListResponse` and `SearchResponse` are public (#2300).

- Generate `TeamResource`'s `add`, `rename` and `message` request bodies from the contract. `TeamResource`'s public method signatures and wire behaviour are unchanged, including `rename` always sending an explicit JSON `null` for a `nil` name rather than omitting the key. The generated `TeamMessageRequest` additionally carries `labels`, a contract field neither method exposes yet (#2300).

## [0.17.1] - 2026-09-15

### Fixed

- Both products share conversation launch handling across `run` and `runRequest`. New channels follow turn one; resumed channels submit the prompt and images once before following the next turn (#2250).

### Added

- `runRequest` in both products forwards API-shaped conversation requests with
  local run options kept separate (#2231).
- FountainKit conversation wire models are generated from the committed contract;
  requests support explicit null, labels, queue and inference credentials. Numeric
  permission-policy values are available through `permissionPolicyValues` while
  the existing string-only property and initializer remain usable (#2231).

## [0.17.0] - 2026-09-14

### Breaking changes

`Team.commsStatus()` is removed from both products, with `TeamCommsStatus`,
`TeammateContact` and `Teammate.contact`. Teammate email and phone (Team
comms) is gone from the server: `GET /api/team/comms` and the
`/api/team/:agent_id/contact` operations no longer exist.

Replace `FountainError.Kind.subscriptionRequired` with
`FountainError.Kind.insufficientCredits` in the `Fountain` product, including
switches and stored raw kind strings. The raw value is now `insufficientCredits`.
Read `error.upgradeURL` for the purchase page. `FountainKit` already uses
`.insufficientCredits(body, upgradeURL:)`; its case and associated URL remain unchanged.
Both products retire the special `subscription_required` wire mapping.

This source API boundary (#2104) ships in Swift v0.17.0 alongside the
Fountain server. Earlier tags keep their original error names.

For billing error handling, use Fountain v0.13.0 or newer.
[v0.13.0](https://github.com/managoat/fountain/releases/tag/v0.13.0) is the first
release containing the credit-only server contract (`c3349343`).
`insufficient_credits` and a generic HTTP 402 identify the credit gate.
`subscription_required` has no special mapping; it follows the HTTP status.
The response still exposes its original code and purchase URL.

### Changed

- Both Swift clients assemble text as ACP chunks. Removed the legacy stdout row paragraph separators; text after a tool call still starts a new paragraph.

- `Agent.model` is `String?`. The `acp` runtime resolves no inference
  credential and reads no model, so the wire sends an explicit null there. A
  non-optional `model` threw `valueNotFound` on decode, and because a page is
  decoded whole, one such agent in the account broke `agents.list()` for every
  caller (#1634).

### Added

- `Agent.runtimeCommand` and `AgentInput.runtimeCommand`, the shell line the
  `acp` runtime launches inside the sandbox, and `Runtime.acp` (#1634).

- `FountainKit`, a second product in this package: the same API with
  `Codable` models, a namespace per resource, a `FountainError` enum, typed
  SSE (`LogEvent`/`Block`), a `TurnFollower` and a `Run` whose event stream
  replays from the beginning for every subscriber. It wraps admin, audit,
  runners, API keys and `apply`, which the untyped client leaves to its
  escape hatch. Contributed from swift-goat, where it grew as that app's
  client, and relicensed to Apache-2.0 by its author (ADR 0041).
- `FountainKit` runs the shared conformance suite as the `swift-kit` column,
  green on all 24 scenarios — including the timeout scenario `swift` skips
  (#1424), because it raises before re-reading the conversation.

### Fixed

- A timed-out or cancelled `Fountain.Run` stops before the final conversation status request. The shared timeout scenario now passes for both Swift products.

- `swift test` no longer traps at teardown on Linux with
  "Trying to access a behaviour for a task that in not in the registry"
  (#1410). Cancelling a `URLSessionTask` is unsafe in FoundationNetworking
  whenever the session carries a `URLCache`: the cache is read on a background
  queue before the task's `URLProtocol` exists, so a cancel that lands in that
  window reports its failure after the task has left the task registry, and
  `URLSession.behaviour(for:)` traps the process. Both clients now build the
  sessions they cancel tasks on, without a cache; the `session` a caller passes
  supplies the configuration rather than being used directly. Fountain sends no
  cache headers and an event stream must not be replayed from a cache, so
  nothing is cacheable in the first place.
- SSE connections share one `URLSession` per client instead of building one
  each. No session is invalidated from inside a delegate callback, and
  `invalidateAndCancel()`, which walks the task registry off the session's work
  queue, is gone.
- `URLSession.data(for:)` is no longer used. It holds the task in its
  cancellation handler for the whole call and never releases it on completion,
  so a Swift task cancelled just after a response arrived cancelled a
  `URLSessionTask` that had already finished.

## [0.16.0] - 2026-09-03

### Added

- Initial dependency-free Swift SDK with async run streaming, resumable
  conversations, permission answers, typed errors, resource CRUD, teammates,
  schedules, sandbox reads, global/team event feeds, and a raw API escape hatch.
- SwiftPM package metadata at the repository root for remote consumption.
- Linux-compatible incremental SSE transport with automatic cursor resume.
- Event streams that stay idle until they are iterated, so building one does
  not open a connection or buffer events the caller has not asked for.
- Construction that throws for a base or app URL with no scheme or no host,
  instead of falling back to the hosted deployment and sending the API key to
  a host the caller never named.
- Credentials-file reads only when an argument and the environment both miss.

### Changed

- Swift 6.1 is now both the declared package tools version and the minimum
  compiler version. The SSE iterator is safe under Swift 6 strict concurrency.
- The Fountain release pipeline resolves and builds the tagged package from a
  clean consumer before it creates the GitHub Release.
