---
type: ADR
title: "Conversation requests pass through SDKs as API inputs"
description: "The TypeScript SDK separates API-shaped requests from local run settings, with wire models generated from the OpenAPI document."
tags: [api, sdk]
status: stable
adr: "0056"
adr_status: "Accepted"
date: 2026-09-15
---

# 0056 — Conversation requests pass through SDKs as API inputs

**Status:** Accepted, 2026-09-15.

## Context

A launch option was repeated in client signatures and JSON body builders even
though the API contract already describes it. Response fields cost less:
TypeScript derives them from the contract. Tracker #2227 targeted the
remaining request duplication.

## Decision

The TypeScript SDK offers `runRequest(request, options)`. The first argument
uses API names and IDs and is forwarded without a field projection; its type,
`ConversationInput`, is generated from the OpenAPI document. The second holds
local execution settings such as timeout and event collection. The existing
name-based helpers keep their signatures and semantics, and a new wire field
does not gain a convenience argument: it goes through `runRequest`.

The two paths cannot be combined. A raw request never resolves names or
merges legacy options, which removes precedence ambiguity. Absent, null,
false, zero and empty values are forwarded as supplied; the server validates
API semantics. A run handle follows a started turn, so `runRequest` refuses a
missing or blank prompt or queue opt-in before sending HTTP. Lower-level API
creation stays available for promptless and queued starts. A future field that
changes the response or the run lifecycle is audited before run support is
claimed for it.

`runRequest` and the convenience helpers both start through one private
`startConversation`, which creates the conversation, tells a new channel from
a resumed one, and submits a resumed channel's prompt once before following it
(a resume binds the existing conversation without submitting the prompt, so
the client captures the cursor and history first). The helpers keep their
argument translation at the boundary and their existing empty-value
behaviour. Durable identity under concurrent prompt submission is #1406.

The CLI's `managoat conv create --file <path|->` accepts API-shaped JSON and
prints the creation response without following a turn.

Server JSON serialization stays explicit. Generation covers the wire
representation, not stream following, permissions, retries or expected
behavioural test results.

## Consequences

- An additive input field reaches `runRequest` by regenerating the SDK's
  types. Nothing checks that it reaches the wire, or that `conv create
  --file` forwards it.
- The helpers are deliberately a subset; a caller wanting every API option
  uses the raw shape. First-party callers that already hold an agent ID use
  `runRequest`, as the server's first-request snippet does; the remaining
  helper callers use them on purpose.
- Conformance changes are needed for new behaviour, not for every optional
  field. The storage/API boundary stays two intentional declarations.

## Alternatives considered

- **Mirror every field in ergonomic signatures.** Repeats field registration.
- **Merge raw input with legacy options.** Adds collision and default
  precedence.
- **Generate all client behaviour.** The schema does not describe turn
  following.
- **Serialize database fields automatically.** Exposes the internal
  representation.

## History

- 2026-09-15 — Decided and built across the TypeScript (#2234), Python (#2235), Elixir (#2236) and Swift (#2240) SDKs, with the nullability repair (#2239), the CLI's `conv create --file` (#2237) and cross-client propagation probes (#2241); first-party callers migrated (#2249) and one TypeScript launch path (#2250).
- 2026-10-12 — The Python, Elixir and Swift SDKs removed ([0059](0059-independent-sdk-maintenance.md)); the decision stands for TypeScript and the CLI.
- 2026-10-15 — The remaining propagation probes removed with `sdk/contract` ([0059](0059-independent-sdk-maintenance.md)).
