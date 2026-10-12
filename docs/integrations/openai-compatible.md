# OpenAI-compatible API (retired)

Fountain used to answer `POST /v1/chat/completions`, `GET /v1/models` and
`GET /v1/models/{model}`, so that any client or gateway with a base-URL field
could point at `https://your-fountain/v1` and treat a Fountain agent as a
model. **Those endpoints are gone.** They were removed in the release that
carries [ADR 0057](https://github.com/managoat/fountain/blob/main/decisions/0057-retire-public-compatibility-protocols.md),
having been alpha and off by default behind a feature flag for their whole
life.

This page stays because the URL is in other people's notes and bookmarks. It
is not a page about a feature you can turn on.

## What a call gets now

`/v1` matches no route, so every request answers `404` with the ordinary body:

```json
{"errors": {"detail": "Not Found"}}
```

That is the same for `GET` and `POST`, with or without an API key, and
whether the client asks for JSON or `text/event-stream`. There is no legacy
envelope, no `openai_compat_not_enabled` code, and no redirect.

## Continuing a thread you already have

**Do this before creating anything.** A conversation your old integration
opened is still there, with its sandbox and everything the agent worked out in
it. Creating a new one instead gets you a fresh sandbox and loses that.

The thread key you were sending — `X-Fountain-Thread`, else `user`, else
`safety_identifier` — was stored as the conversation's `channel_id`, prefixed
`openai:`. Find it, **check it is the one you mean**, then prompt it by id.

```bash
# 1. Find candidates. Filter by the agent too: a thread key is only unique
#    within the agent it was used against, and `--data-urlencode` keeps a key
#    containing /, ?, & or a space from breaking the query.
curl -G -H "Authorization: Bearer ftn_..." \
  --data-urlencode "channel_id=openai:<your-thread-key>" \
  --data-urlencode "agent_id=<agent-uuid>" \
  --data-urlencode "status=idle,running,pending" \
  "https://your-fountain/api/conversations"
```

**This is a list, not an answer.** It is ordered by `updated_at`, and without
the `status` filter it also returns `failed` and `terminated` conversations,
which cannot take a prompt.

```bash
# 2. For each candidate, fetch it by id. Only the show route loads the
#    sandbox — the list above renders `sandbox: null` for every row, so it
#    cannot tell you whether the machine is still there.
curl -H "Authorization: Bearer ftn_..." \
  "https://your-fountain/api/conversations/<id>"
```

Prompt a candidate only if all of this holds:

- `data.sandbox` is **not null**, and its `status` is not `terminated` or
  `failed`. An `idle` conversation can still point at a dead sandbox; prompting
  that one provisions a fresh machine, which is the outcome this whole section
  exists to avoid.
- `data.agent_id`, `data.environment_id` and `data.vault_id` are the identity
  the work was done under.

If several candidates come back, the thread key was reused across
configurations — pick by that identity, not by recency, and expect some of them
to have terminal sandboxes. If none survives both checks, there is nothing to
continue and a fresh conversation is the right answer.

```bash
# 3. Prompt it by id. Same sandbox, same history.
curl -X POST -H "Authorization: Bearer ftn_..." -H "Content-Type: application/json" \
  -d '{"prompt":"..."}' \
  "https://your-fountain/api/conversations/<id>/prompts"
```

**Do not replay your transcript.** The sandbox is the memory. Send only the new
message; replaying the history feeds the agent its own words back.

If you resume by `channel_id` instead of prompting an id, send the same
`agent_id`, `environment_id` and `vault_id` — an incomplete identity resolves
to a different machine, which is the same lost-sandbox outcome by another
route.

Existing `openai:` bindings are left intact by the retirement — nothing was
renamed or migrated.

## What to use instead

The native conversation API. It is not a drop-in for a chat-completions
client — that is the point of the shape that went away — so this is a
rewrite, not a base-URL change:

| You had | You want |
|---|---|
| `POST /v1/chat/completions` with `messages` | [`POST /api/conversations`](../api.md), then prompt the conversation |
| `stream: true` and SSE chunks | [`GET /api/conversations/:id/stream`](../api.md) |
| A thread key in a header | A conversation id, which Fountain returns when you create one |
| `model: "<agent>"` | `agent_id` on the conversation |
| `GET /v1/models` | [`GET /api/agents`](../api.md) |

The [TypeScript SDK](../sdk.md) wraps all of it, and
[Plug into Fountain](clients.md) is the shortest route in.

## What is not affected

**OpenAI and Codex as inference.** Fountain still runs agents on OpenAI
models, still stores OpenAI credentials, and still supports the Codex
runtime. Those share the vendor's name with the retired gateway and nothing
else — no provider-side `/v1` path was touched.

**Tools your agent calls on your application.** Configure them on the agent
as MCP servers, with `${VAR}` references resolved from the environment and
the vault. That path is unchanged and is not the retired request-defined
tool bridge. Read [Plug into Fountain](clients.md).

## What has no replacement

Pointing a stock OpenAI client or an AI gateway at Fountain with **no code**.
That was the whole value of the dialect, and retiring it removes it; nothing
in the native API gives it back. If that is what you needed, the honest
answer is that Fountain no longer offers it.
