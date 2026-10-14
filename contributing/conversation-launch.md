# Conversation launch ownership

Follow-up: [#2250](https://github.com/managoat/fountain/issues/2250).
Caller inventory and migration: [#2264](https://github.com/managoat/fountain/pull/2264).

The Python, Elixir and Swift SDKs this once covered were removed on 2026-10-12
([ADR 0059](../decisions/0059-independent-sdk-maintenance.md)); TypeScript is
the client this guidance applies to.

## One creation/admission implementation

Each public request API and convenience helper delegates to the same private
launch function, `startConversation`. The function creates the conversation,
distinguishes a new conversation from a resumed channel, and selects the turn
and stream cursor. Existing turn followers continue to own streaming,
permissions, deadlines and results.

A newly created channel follows turn one, even when `fresh` is set. Resuming a
channel does not submit its prompt during creation. The shared function captures
the cursor and next turn, submits the prompt and images once, then follows that
turn. Concurrent admission/turn identity remains
[#1406](https://github.com/managoat/fountain/issues/1406).

## Intentional argument translation

The caller inventory found active uses for the convenience APIs. This change
removes no public methods or options and introduces no deprecation period.
Their existing argument translation remains at the boundary; new API fields
should use the request API rather than acquire another convenience argument.

| Client | Retained convenience translation |
|---|---|
| TypeScript | Resolve `agent`, `vault`, `environment`; translate prompt, title, images, channelId, fresh, spriteName, sandbox, sandboxMode |

Timeout, cancellation and event collection remain local options where supported.
The request APIs preserve wire values and reject promptless launches.
The legacy helpers keep their existing empty-value behavior: they omit an empty
prompt, images and title, and a false `fresh`. Compatibility tests assert the exact request and
server validation error so consolidation cannot silently tighten these APIs.

The TypeScript 5.2.1 patch release carries the fix. Release ownership is
separate work in [#1414](https://github.com/managoat/fountain/issues/1414).
