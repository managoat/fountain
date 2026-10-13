# Wire scenarios

`sdk/contract/` pins the *shape* of the wire. These pin the *behaviour*: what
the client does with an SSE frame split across two TCP writes, which error
class a 429 becomes, whether a dropped stream resumes from the right cursor,
and what `run` returns when the turn fails. None of that is in an OpenAPI
document.

Each scenario is a JSON file describing bytes in and observations out.
`../scenarios.test.ts` serves those bytes over a real socket to the public
client, records what it saw, and compares that with the scenario's `expect`.
It also checks every `json` response body against the schema the server
declares for that operation in `sdk/contract/contract.json`, so a fixture
cannot quietly encode a response the real server would never send.

They run with the rest of the SDK's tests (`npm test` in `sdk/typescript`).
To run only these: `node --test test/scenarios.test.ts`.

These scenarios were once a language-neutral suite shared by four SDKs
(`sdk/conformance`). TypeScript is the one SDK left, so they live with its
tests; the format below is unchanged.

## A scenario

```jsonc
{
  "name": "sse-multiline-data",
  "title": "A data field split over several lines joins with newlines",
  "contract": "sse-framing",
  "why": "One sentence on what would break in a client that got this wrong.",

  "client": { "api_key": "conformance-key" },

  "http": [
    {
      "match": { "method": "POST", "path": "/api/conversations" },
      "respond": { "status": 201, "json": { "data": { "id": "c1", "status": "running" } } }
    },
    {
      "match": { "method": "GET", "path": "/api/conversations/c1/stream" },
      "respond": {
        "status": 200,
        "headers": { "content-type": "text/event-stream" },
        "sse": ["id: 1\nevent: output\ndata: {\"id\":1,...}\n\n"],
        "close": "end"
      }
    }
  ],

  "steps": [{ "op": "run", "agent": "…", "prompt": "hello" }],

  "expect": {
    "requests": [
      { "method": "POST", "path": "/api/conversations", "headers": { "authorization": "Bearer conformance-key" } },
      { "method": "GET", "path": "/api/conversations/c1/stream" }
    ],
    "events": [{ "type": "text", "text": "line one\nline two" }],
    "result": { "state": "done", "text": "line one\nline two" }
  }
}
```

### `http`: the bytes going out

An ordered list of exchanges. For each incoming request the test server takes the
**first not-yet-consumed** entry whose `match` fits, and consumes it. Order
matters only between entries that match the same request, which is how a
reconnect scenario says "this stream dies, the next one resumes".

A request matching no remaining entry is a failure, reported as an unmatched
request rather than answered — a client asking for something the scenario did
not anticipate is a finding, not a 404 to be swallowed.

`match` takes `method`, `path`, and optionally `query` (a subset: every named
parameter must be present with that value) and `headers` (a subset, names
lower-cased). `path` is exact; no patterns, because a scenario that cannot say
which conversation it means is not pinning much.

`respond` is one of two shapes.

**A whole response.** `status`, optional `headers`, and a body as either `json`
(encoded by the test server) or `body` (a string sent verbatim, for the malformed
cases). No body key means no body.

**A stream.** `status`, `headers`, and `sse`: a list of strings written in
order, each one flushed before the next. A string is one TCP write, so
splitting a frame across two list entries is how a scenario says "this frame
arrives fragmented". An entry may be `{"text": "…", "delay_ms": 50}` where the
timing matters. `close` is `end` for a clean end of stream or `abort` for a
connection that dies without one, which is what a deploy or a proxy timeout
looks like to a client that has been reading happily for hours.

### `steps`: what the client is asked to do

The vocabulary is small on purpose. Every op is something a client
exposes publicly; nothing here reaches into a private class.

| `op` | Fields | What the test calls |
|---|---|---|
| `me` | | the "who am I" call |
| `list` | `resource` (`agents`\|`vaults`\|`environments`) | that collection's list |
| `create_agent` | `attrs` | create an agent from a flat attribute map |
| `get_conversation` | `conversation_id` | read one conversation |
| `run` | `agent`, `prompt`, `channel_id?`, `client_request_id?`, `timeout_ms?`, `answer_permissions?` | start a run and consume it to completion |
| `send` | `conversation_id`, `prompt` | send a follow-up prompt to an existing conversation |
| `history` | `conversation_id` | drain the event feed to its end |

`run` consumes the run to completion and records both the events it yielded and
the result. `channel_id` selects a channel to create or resume, and
`client_request_id` names the prompt submission on both the create request and
the follow-up prompt request when the channel resumes.
`answer_permissions` maps a permission request id (or `"*"`) to the
option id the test should answer with, which is how the permission flow is
driven without the scenario knowing anything about callbacks or futures.

`client` sets up the client: `api_key`, and optionally `base_url_suffix` (append
to the server's base URL, for the normalisation scenarios) and `timeout_ms`.
The test supplies the base URL; a scenario never knows the port.

### `expect`: what must be observed

Every key is optional, and an absent key asserts nothing.

- **`requests`** — an ordered list. Each entry is a *subset* match against the
  request the server saw: `method` and `path` exactly, `query`, `headers`
  (lower-cased names) and `body` as subsets. Clients do not agree on every
  header they send, and this suite is not the place to make them.
  `header_prefixes` asserts a header starts with a string, for the ones whose
  tail is a version; `headers_absent` asserts a header was not sent at all.
  `"requests_exactly": true` alongside it also asserts the count.
- **`value`** — a subset match against what a non-run op returned, for the
  reads. A list op compares element by element.
- **`event_ids`** — the `id` of every event a `history` drain returned, in
  order. Exact, not a subset: the whole point is that none went missing.
- **`events`** — the ordered run events, each a subset match. The event
  vocabulary is the one the SDK already emits: `conversation`,
  `turn-start`, `text`, `thinking`, `tool`, `permission`, `block`, `event`,
  `turn-end`.
- **`result`** — a subset match against the finished run: `state`, `text`,
  `tools_used`, `turn_number`, `exit_code`, `reason`, `conversation_id`.
- **`error`** — the failure the client raised, subset-matched. `kind` comes
  from the vocabulary below rather than an error class name. The other keys are `status`, `code` (the server's `error` string),
  `retryable`, `retry_after` (seconds, from `Retry-After`), `field_errors` (the
  422 map) and `partial_text` (what a timed-out run had collected).
- **`no_error`: true** — the step must not raise. Implied when `result` or
  `events` is present.

### The error vocabulary

| `kind` | Raised for |
|---|---|
| `auth` | 401, and a client constructed with no key |
| `not_found` | 404 |
| `validation` | 422 |
| `rate_limited` | 429 |
| `busy` | `conversation_busy` |
| `quota` | `sandbox_quota_exceeded` — the concurrency cap; terminate a conversation and carry on |
| `not_ready` | `provisioning`, `sprite_probe_failed`, `fleet_full`, 503 |
| `timeout` | the client's own deadline elapsed |
| `connection` | the transport failed before a status arrived |
| `resolution` | a name the account has no match for |
| `server` | any other non-2xx |

`scenarios.test.ts` maps the client's error classes to these kinds. Keep the
mapping honest: map the class the client actually raises, never the class the
scenario wants.

## Adding a behaviour

1. Write the scenario JSON here, named after its `name`. It is the definition
   of the behaviour, and it lands before the client changes.
2. Run `node --test test/scenarios.test.ts`. A fixture body the contract does
   not declare fails before the client is even driven.
3. Fix the client.

## What this is not

It does not replace the SDK's other tests. Those cover idiom, ergonomics and
implementation detail, such as how `for await` behaves. These own only the
behaviour on the wire, and should stay boring enough that a reader can tell
which is which.

It also does not drive a real Fountain. Every scenario is scripted bytes, which
is what makes byte-level framing and connection death testable at all. The
complementary check — that a *real* rendered response matches its declared
schema — is a server-side concern and lives with the server.
