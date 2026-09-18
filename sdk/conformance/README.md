# The SDK conformance suite

`sdk/contract/` pins the *shape* of the wire. This pins the *behaviour*: what a
client does with an SSE frame split across two TCP writes, which error class a
402 becomes, whether a dropped stream resumes from the right cursor, and what
`run` returns when the turn fails. None of that is in an OpenAPI document, and
all of it is something Fountain promises in four languages at once.

Each scenario is a JSON file describing bytes in and observations out. Each SDK
supplies a thin adapter that serves those bytes to its own public client and
reports what it saw. The scenarios contain no language-specific expectation,
and the adapters contain no expectation at all.

## Layout

```
sdk/conformance/
  README.md            this file: the format, the vocabulary, how to add one
  scenarios/*.json     the canonical scenarios
  matrix.json          which SDK runs which scenario, and why not
  lint.py             validates the scenarios, the matrix and the fixtures
```

## Running it

| SDK | Command | Run from |
|---|---|---|
| TypeScript | `npm run conformance` | `sdk/typescript` |
| Python | `python3 -m unittest discover -s tests -p test_conformance.py` | `sdk/python` |
| Swift | `swift test --filter ConformanceTests` | repository root |
| Swift (typed) | `swift test --filter FountainKitTests.Conformance` | repository root |
| Elixir | `mix test test/conformance_test.exs` | `sdk/elixir` |

Each also runs inside that SDK's normal test command, so a contributor who runs
the suite gets it without knowing it is there. `python3 sdk/conformance/lint.py`
checks the scenarios themselves.

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

An ordered list of exchanges. For each incoming request the adapter takes the
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
(encoded by the adapter) or `body` (a string sent verbatim, for the malformed
cases). No body key means no body.

**A stream.** `status`, `headers`, and `sse`: a list of strings written in
order, each one flushed before the next. A string is one TCP write, so
splitting a frame across two list entries is how a scenario says "this frame
arrives fragmented". An entry may be `{"text": "…", "delay_ms": 50}` where the
timing matters. `close` is `end` for a clean end of stream or `abort` for a
connection that dies without one, which is what a deploy or a proxy timeout
looks like to a client that has been reading happily for hours.

**How the bytes reach the client is the adapter's business.** A real loopback
socket and a transport-level mock are both fine, as long as the client parses
the same bytes. Swift uses its `MockURLProtocol` rather than a real socket on
purpose: the `FoundationNetworking` teardown bug is tracked separately and is
explicitly not this suite's problem.

### `steps`: what the client is asked to do

The vocabulary is small on purpose. Every op is something all four clients
expose publicly; nothing here reaches into a private class.

| `op` | Fields | What the adapter calls |
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
option id the adapter should answer with, which is how the permission flow is
driven without the scenario knowing anything about callbacks or futures.

`client` sets up the client: `api_key`, and optionally `base_url_suffix` (append
to the server's base URL, for the normalisation scenarios) and `timeout_ms`.
The adapter supplies the base URL; a scenario never knows the port.

### `expect`: what must be observed

Every key is optional, and an absent key asserts nothing.

- **`requests`** — an ordered list. Each entry is a *subset* match against the
  request the server saw: `method` and `path` exactly, `query`, `headers`
  (lower-cased names) and `body` as subsets. Four clients do not agree on every
  header they send, and this suite is not the place to make them.
  `header_prefixes` asserts a header starts with a string, for the ones whose
  tail is a version; `headers_absent` asserts a header was not sent at all.
  `"requests_exactly": true` alongside it also asserts the count.
- **`value`** — a subset match against what a non-run op returned, for the
  reads. A list op compares element by element.
- **`event_ids`** — the `id` of every event a `history` drain returned, in
  order. Exact, not a subset: the whole point is that none went missing.
- **`events`** — the ordered run events, each a subset match. The event
  vocabulary is the one all four clients already emit: `conversation`,
  `turn-start`, `text`, `thinking`, `tool`, `permission`, `block`, `event`,
  `turn-end`. Adapters report `type` in that spelling whatever their language
  calls it.
- **`result`** — a subset match against the finished run: `state`, `text`,
  `tools_used`, `turn_number`, `exit_code`, `reason`, `conversation_id`.
- **`error`** — the failure the client raised, subset-matched. `kind` comes
  from the shared vocabulary below, because `QuotaExceededError` and
  `Fountain.Error` with `:quota_exceeded` are the same promise in two
  languages. The other keys are `status`, `code` (the server's `error` string),
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
| `insufficient_credits` | `insufficient_credits` and a bare 402; the caller must buy credit. `upgrade_url` preserves the purchase destination when supplied. Retired `subscription_required` has no special mapping. |
| `not_ready` | `provisioning`, `sprite_probe_failed`, `fleet_full`, 503 |
| `timeout` | the client's own deadline elapsed |
| `connection` | the transport failed before a status arrived |
| `resolution` | a name the account has no match for |
| `server` | any other non-2xx |

An SDK whose class names differ maps them here in its adapter. The mapping is
the adapter's only judgement call, and it is the thing the suite is asserting,
so keep it honest: map the class the client actually raises, never the class
the scenario wants.

## The support matrix

`matrix.json` says which SDK runs which scenario. Every scenario needs an entry
for all four, and the only values are `"yes"` or an object
`{"skip": "why", "issue": 1234}`. `lint.py` fails on a scenario missing from the
matrix, on an SDK missing from a scenario, on a skip with no issue, and on a
matrix entry naming a scenario that no longer exists. A gap is therefore a
decision somebody wrote down and filed, never an absence.

## Adding a behaviour

One place, in this order:

1. Write the scenario JSON here. This is the definition of the behaviour, and
   it lands before any implementation changes.
2. Run `python3 sdk/conformance/lint.py`. It checks the format, and it checks
   every `json` response body in the scenario against the schema the server
   declares for that operation in `sdk/contract/contract.json` — so a fixture
   cannot quietly encode a response the real server would never send.
3. Add it to `matrix.json`, `"yes"` for the SDKs that pass and a skip with an
   issue number for the ones that do not yet.
4. Fix the clients.

## What this is not

It does not replace each SDK's own tests. Those cover idiom, ergonomics and
implementation detail — how `for await` behaves, whether a Swift `AsyncSequence`
cancels cleanly, what an Elixir `Stream` does on demand. This suite owns only
the behaviour Fountain promises identically in every language, and its scenarios
should stay boring enough that a reader can tell which is which.

It also does not drive a real Fountain. Every scenario is scripted bytes, which
is what makes byte-level framing and connection death testable at all. The
complementary check — that a *real* rendered response matches its declared
schema — is a server-side concern and lives with the server.
