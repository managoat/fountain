# Conversation launch ownership

Follow-up: [#2250](https://github.com/managoat/fountain/issues/2250).
Caller inventory and migration: [#2264](https://github.com/managoat/fountain/pull/2264).

## One creation/admission implementation per client

Each public request API and convenience helper delegates to the same private
launch function. The function creates the conversation, distinguishes a new
conversation from a resumed channel, and selects the turn and stream cursor.
Existing turn followers continue to own streaming, permissions, deadlines and
results. FountainKit reuses `ConversationsResource.run` for resumed prompts.

| Client | Before | After | Shared launch function |
|---|---:|---:|---|
| TypeScript | 2 | 1 | `startConversation` |
| Python | 2 | 1 | `_start_conversation` |
| Elixir | 2 | 1 | `start_conversation` |
| Swift Fountain | 2 | 1 | `startConversation` |
| Swift FountainKit | 2 | 1 | `startConversation` |
| **Total creation/admission implementations** | **10** | **5** | |

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
| Python | Resolve `agent`, `vault`, `environment`; translate prompt, title, images, channel_id, fresh, sprite_name, sandbox, sandbox_mode, sandbox_api_access |
| Elixir | Resolve `:agent`, `:vault`, `:environment`; translate prompt, :title, :images, :channel_id, :fresh, :sprite_name, :sandbox, :sandbox_mode, :sandbox_api_access |
| Swift Fountain | Resolve agent, vault, environment; translate prompt, title, images, channelID, fresh, spriteName, sandbox, sandboxMode, sandboxAPIAccess |
| Swift FountainKit | Accept agent/vault/environment IDs; translate prompt, title, images, permissionPolicy, sandboxMode, sandboxID, channelID, fresh into the generated request |

Timeout, cancellation and event collection remain local options where supported.
The request APIs preserve wire values and reject promptless or queued launches.
The legacy helpers keep their existing empty-value behavior: for example, the
map clients omit an empty prompt/images and false `fresh`, while FountainKit
encodes supplied empty values and false. TypeScript also omits an empty title;
the other clients retain it. Compatibility tests assert the exact request and
server validation error so consolidation cannot silently tighten these APIs.

Patch releases carry the fixes in TypeScript 5.2.1, Python 0.5.1 and Elixir 0.5.1.
Swift changes remain Unreleased until the server-aligned tag tracked in
[#2248](https://github.com/managoat/fountain/issues/2248). Release ownership is
separate work in [#1414](https://github.com/managoat/fountain/issues/1414).
