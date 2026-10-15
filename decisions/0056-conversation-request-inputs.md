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

## Context

A launch option is repeated in client signatures and JSON body builders even
though the API contract already describes it. Response fields are less costly:
TypeScript derives them and Python/Elixir use maps. Tracker #2227 targets the
remaining request duplication and Swift wire models.

## Decision

Offer a separate `runRequest(request, options)` (or `run_request`) entry point.
The first argument uses API names and IDs and is forwarded without a field
projection. The second contains local execution settings such as timeout and
event collection. Typed wire inputs derive from the API contract. Existing
name-based helpers keep their signatures and semantics; new wire fields do
not acquire convenience aliases automatically.

The two paths cannot be combined: raw requests never resolve names or merge
legacy options. This removes precedence ambiguity. Forward absent, null,
false, zero and empty values as supplied; the server validates API semantics.
A run handle specifically follows a started turn, so this entry point refuses
a missing/blank prompt or queue opt-in before sending HTTP. Lower-level API
creation remains available for promptless and queued starts. Audit future
fields that change response or run lifecycle before claiming run support.

Keep server JSON serialization explicit. Generate wire representation, not
stream following, permissions, retries or expected behavioral test results.

## Implementation status

The foundation is implemented in TypeScript (#2234), Python (#2235), Elixir
(#2236), and both Swift products (#2240). TypeScript derives `ConversationInput`
from the generated document; FountainKit's conversation models derive from the
committed contract. The published nullability repair landed in #2239.

CLI `conv create --file <path|->` (#2237) accepts API-shaped JSON and prints the
creation response without following a turn. The unified generation/check command
and cross-client propagation probes landed in #2241. The probe changes a temporary
contract, including nested referenced request types, rather than publishing a
synthetic API field. Existing behavioral conformance stays independently authored.

The new run paths distinguish newly created channels from resumed channels. A
resume binds the existing conversation without submitting the prompt, so the
client captures the cursor/history and submits the prompt once before following
it. Durable identity under concurrent prompt submission remains #1406.

This does not finish removing duplication: legacy convenience builders remain,
first-party caller migration is #2249, shared launch implementation is #2250,
and remaining Swift wire models are #2251. Tracker #2247 owns that follow-through;
#2248 records package availability and rollout evidence. Independent SDK release
policies remain in force; merging the foundation did not itself release new
Swift or CLI artifacts.

## Consequences

An additive input field can flow through a stable client method. Existing
helpers remain usable but are deliberately a subset; callers wanting every
API option use the raw shape. SDK changes still follow independent release
policies. Conformance changes are needed for new behavior, not every optional
field. The explicit storage/API boundary remains two intentional declarations.

## Alternatives considered

- Mirror every field in ergonomic signatures: repeats field registration.
- Merge raw input with legacy options: adds collision/default precedence.
- Generate all client behavior: the schema does not describe turn following.
- Serialize database fields automatically: exposes internal representation.

## Addendum — 2026-10-12: one SDK

The Python, Elixir and Swift SDKs were removed
([ADR 0059's addendum](0059-independent-sdk-maintenance.md#addendum--2026-10-12-typescript-is-the-one-sdk)).
The decision stands for TypeScript's `runRequest` and for the CLI's
`conv create --file`; the Swift wire-model generator and the Python, Elixir
and Swift propagation probes went with their clients.

## Addendum — 2026-10-15: no propagation probes

The TypeScript and CLI propagation probes (`check-propagation.py`) were
removed with the rest of `sdk/contract`
([ADR 0059's addendum](0059-independent-sdk-maintenance.md#addendum--2026-10-15-the-contract-layer-is-removed)).
The decision stands: `runRequest` takes the generated `ConversationInput`, so
a new optional field reaches it by regeneration. Nothing now checks that it
reaches the wire, or that `fountain conv create --file` forwards it.

## Addendum — 2026-10-15: the follow-through, recorded

Three one-off records in `contributing/` were deleted on 2026-10-15; what
stays true from the two that concern this decision is here. (The third, the
#2393 actor status audit, is carried by `Fountain.Conversations.ActorStatus`
and `actor_status_binding_test.exs`.)

- **Callers (#2249, closed 2026-09-15).** First-party callers that already
  hold an agent ID use `runRequest`; the server's first-request snippet does.
  The name-based helpers stay: their remaining callers use them on purpose.
- **One launch path (#2250, closed 2026-09-15).** In the TypeScript SDK,
  `runRequest` and the convenience helpers both start through one private
  `startConversation`, which creates the conversation, tells a new channel
  from a resumed one, and submits a resumed channel's prompt once before
  following it. The helpers keep their argument translation at the boundary
  and their existing empty-value behaviour; a new API field goes through
  `runRequest` rather than gaining another convenience argument.
