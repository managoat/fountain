---
type: ADR
title: "Conversation requests pass through SDKs as API inputs"
description: "Separate wire requests from local run settings. TypeScript implements the first path; other clients and generated Swift models are tracked follow-ups."
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

TypeScript implements `runRequest` and derives `ConversationInput` from the
existing generated document in #2228. Python (#2229), Elixir (#2230), Swift
models/request paths (#2231), CLI JSON input (#2232), and the integrated
verification workflow (#2233) remain unbuilt in this revision.

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
