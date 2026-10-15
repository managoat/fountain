---
type: ADR
title: "Spawn depth ceiling"
description: "Each conversation stores its spawn depth, and a start deeper than CONVERSATION_MAX_DEPTH (default 5) is refused with 422 conversation_depth_exceeded."
tags: [conversations, sandboxes, limits]
status: stable
adr: "0083"
adr_status: "Accepted"
date: 2026-10-15
---

# 0083 — Spawn depth ceiling

**Status:** Accepted when the PR that adds it merges (#1269). Built in that
PR.

## Context

An agent can start another conversation from inside its sandbox, and the
conversation it starts can do the same. Before this decision nothing bounded
how deep that went. The credit balance was the backstop, and since
2026-10-12 there are no credits, so there was no backstop at all. A loop is
discovered from the provider invoice, after the spend, and nothing says
which chain was looping.

The fleet ceiling (`SANDBOX_FLEET_CEILING`, ADR 0042's 2026-10-13 addendum)
bounds how many sandboxes run at once across the deployment. It stops a
runaway chain eventually, but only by refusing everyone's starts once the
fleet is full.

Two things identify the conversation a start came from:

- the `X-Managoat-Parent-Conversation-Id` header, which a client sets and so
  can leave out;
- the sandbox's callback token (`$MANAGOAT_TOKEN`, a `sprite`-scoped API key,
  ADR 0045), which the conversation row records as `callback_api_key_id`. A
  sandbox cannot start a conversation without some credential, and this is
  the one it is given.

## Decision

`conversations.depth` is a stored, non-negative integer. A conversation
started with neither a parent header nor a sandbox token is depth 0. A
start that names either is one deeper than the conversation it names, and
when it names both, one deeper than the deeper of the two. The parent header
alone still decides `parent_conversation_id` and `source`; the token only
counts.

`Launch.start_conversation/2` refuses a start whose depth would exceed
`CONVERSATION_MAX_DEPTH` (default 5) with `{:error,
{:conversation_depth_exceeded, depth, max_depth}}`, rendered as
`422 conversation_depth_exceeded` with `depth` and `max_depth` in the body.
The check runs before the sandbox reservation, so a refused start costs
nothing. `0` lets no sandbox start a conversation.

The migration backfills existing rows from `parent_conversation_id`, the only
lineage they recorded.

## Consequences

- A runaway chain stops at a known depth with an error that says so, rather
  than at the fleet ceiling with an error that blames capacity.
- Any future door that creates a conversation must compute depth the same
  way. Today `Launch.start_conversation/2` is the only one.
- Leaving the parent header out no longer resets the count, because the
  token carries it. A sandbox that holds the owner's full-scope key (put in
  an environment or vault by the owner) and omits the header is still
  counted as depth 0; the server cannot tell that start from one made
  outside a sandbox.
- 422, not 503: retrying never helps, because the chain does not get
  shallower.
- Fan-out, one conversation starting many children, is not bounded. A
  depth-5 tree with wide fan-out is still large; the fleet ceiling remains
  the bound on how much of it runs at once.

## Alternatives considered

- **Compute depth by walking `parent_conversation_id` at launch** — no
  migration, but it trusts only the header, which a client can omit, and it
  walks the chain on every start.
- **Set `parent_conversation_id` from the token when the header is absent** —
  would also close the gap, but changes `source` and the list's
  sub-conversation filter for every client that does not send the header;
  that is a provenance change, not a depth change, and can be made on its
  own.
- **Refuse with 503 like `fleet_full`** — a retryable status would invite the
  looping agent to retry.
- **Bound fan-out too** — out of scope for #1269; depth first.
