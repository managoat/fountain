# Webhooks

Fountain sends conversation lifecycle events to a URL you own. This page lists
the events, the payload shape, how to verify the signature, and what the
delivery contract promises.

A webhook tells you that something happened. It does not carry the transcript.
Read the [conversation events section](../api.md#conversations) of the API
reference when you want the output itself.

## When to use a webhook, and when to stream

`GET /api/conversations/:id/events` is a good stream and a bad integration
point. It needs a process that holds a socket open for a whole turn, and a
turn can take twenty minutes. It also covers one conversation only.

| You have | Use |
|---|---|
| A GitHub Action, a Lambda, a cron script, a Slack app. | A webhook. |
| A chat UI that draws output as it arrives. | The SSE stream. |
| A dashboard that wants every conversation on the account. | A webhook. |
| A run you must watch from start to finish, live. | The SSE stream. |

You can use both at once. A webhook `id` is the id the stream sends, so a
client that does both can drop the duplicates.

## Create an endpoint

```bash
fountain webhooks create https://example.com/hooks/fountain \
  --event conversation.turn.done \
  --event conversation.turn.failed
```

The CLI prints the secret once. Fountain cannot show you that secret again.
To replace it, run `fountain webhooks rotate-secret <id>`. The old secret then
fails every signature check.

Over the API:

```bash
curl -X POST https://your-instance/api/webhooks \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com/hooks/fountain",
       "event_types":["conversation.turn.done"]}'
```

An endpoint with no `event_types` gets `conversation.turn.done`,
`conversation.turn.failed` and `conversation.provision.failed`. Most
integrations want those three.

## The event catalogue

Each event type is `conversation.<stage>.<status>`. The stage and the status
are the pair the SSE stream puts on a `stage` event. The Prometheus stage
counter uses the same pair as its tags.

| Stage | Statuses | What it means |
|---|---|---|
| `provision` | `started` `done` `failed` | Fountain builds the sandbox. A `failed` here means no agent ever ran. |
| `clone` | `started` `done` `failed` | Fountain clones the repositories the environment declares. |
| `packages` | `started` `done` `failed` | The environment's package commands run. |
| `network` | `started` `done` `failed` | Fountain applies the egress policy to the sandbox. |
| `broker` | `started` `done` `failed` | Fountain prepares the egress credential broker for the conversation, when brokerage is on for the tenant. A `failed` before any sandbox exists names the cause: the broker did not answer, or the provider cannot enforce the network floor. |
| `setup` | `started` `done` `failed` | The environment's setup script runs. |
| `checkpoint_restore` | `started` `done` `failed` | Fountain restores a checkpoint into the sandbox. |
| `connection` | `started` `done` | An accepted runner turn waits for its socket to reconnect. The outcome records recovery, interruption or failure. |
| `reattach` | `started` `done` `failed` `interrupted` | The server reconnects to a sandbox after a restart. |
| `turn` | `started` `done` `failed` `interrupted` | One prompt and its reply. |
| `request` | `started` `done` | The agent asked permission for a tool. It got an answer, or the request expired. |
| `caller_tool` | `started` `done` | The agent called a tool that the client defined on its request. The client answered, or the call expired. |
| `model` | `done`, `failed` | The runtime confirmed the selected model, or selection or provider access failed. |
| `session` | `done` | The runtime reported a session id for the conversation. |
| `sandbox` | `done` | Fountain reclaimed the sandbox. The conversation stays resumable. |
| `configuration` | `done`, `failed` | Fountain applied a new Agent, Environment or Vault, or selected one that the machine has yet to read. The machine stays. |
| `terminate` | `done` | The conversation ended. |

An endpoint filter accepts three shapes.

- An exact type, `conversation.turn.done`.
- One stage, `conversation.turn.*`.
- All events, `*`.

Fountain rejects a typo in an exact type when you save the endpoint. A mistake
never leaves you with an endpoint that gets nothing.

### Output does not come this way

`stdout` and `stderr` produce no webhooks. One chatty turn writes thousands of
output chunks. An HTTP POST for each chunk is a denial of service on both
ends. Use the SSE endpoint for output.

## The payload

```json
{
  "id": "918273",
  "type": "conversation.turn.done",
  "created_at": "2026-08-22T18:30:00.123456Z",
  "data": {
    "conversation_id": "0f2c…",
    "agent_id": "7ab1…",
    "parent_conversation_id": null,
    "status": "idle",
    "labels": {"env": "prod", "drift": "true"},
    "stage": "turn",
    "state": "done",
    "turn_id": "3d90…",
    "duration_ms": 42310
  }
}
```

| Field | Meaning |
|---|---|
| `id` | The log event row id. The SSE stream uses the same id. It is stable and monotonic. |
| `type` | `conversation.<stage>.<status>`. |
| `created_at` | The time Fountain recorded the transition, in UTC, to the microsecond. |
| `data.status` | The conversation status Fountain read at dispatch time. Treat it as advisory. |
| `data.labels` | The conversation's labels, read at dispatch time. An empty object when it has none. |
| `data.turn_id` | A turn event carries it. Every other event carries null. |
| `data.duration_ms` | How long the stage took, where the stage records a duration. |

**The payload carries no values.** It has no transcript text, no prompt, no
environment variable names and no secret values. Labels are the one free-form
field, and they are there because a caller put them there itself. The agent
in the sandbox can also stamp them over its ACP session. Treat a label as
data your own run wrote, and not as a value Fountain derived. The audit trail obeys the
same rule ([ADR 0013](https://github.com/managoat/fountain/blob/main/decisions/0013-audit-trail.md)),
for the same reason. A payload is tenant data that leaves the building over a
URL somebody typed into a form. The delivery log would otherwise hold a
second, less guarded copy of every conversation.

A receiver that wants the transcript calls `GET /api/conversations/:id/events`
with its own API key.

## Verify the signature

Each request carries four headers.

```
Fountain-Signature: t=1755203400,v1=8a1f…
Fountain-Event-Id: 918273
Fountain-Event-Type: conversation.turn.done
Fountain-Delivery-Attempt: 1
```

`v1` is `hmac_sha256(secret, "<t>.<raw request body>")`, in hex. The signed
string holds the timestamp. An attacker cannot move a captured body forward in
time, and a receiver can enforce a replay window.

Verify against the **raw** body, before your code parses the JSON. If you
re-encode the parsed object, the bytes change and the signature fails.

```python
import hashlib, hmac, time

def verify(header, raw_body, secret, tolerance=300):
    parts = dict(p.split("=", 1) for p in header.split(","))
    timestamp = int(parts["t"])
    if abs(time.time() - timestamp) > tolerance:
        return False
    expected = hmac.new(
        secret.encode(),
        f"{timestamp}.".encode() + raw_body,
        hashlib.sha256,
    ).hexdigest()
    return hmac.compare_digest(expected, parts["v1"])
```

```javascript
import crypto from "node:crypto";

export function verify(header, rawBody, secret, tolerance = 300) {
  const parts = Object.fromEntries(
    header.split(",").map((p) => p.split("=", 2)),
  );
  const timestamp = Number(parts.t);
  if (Math.abs(Date.now() / 1000 - timestamp) > tolerance) return false;
  const expected = crypto
    .createHmac("sha256", secret)
    .update(`${timestamp}.`)
    .update(rawBody)
    .digest("hex");
  return crypto.timingSafeEqual(
    Buffer.from(expected),
    Buffer.from(parts.v1),
  );
}
```

Read the pairs by name, not by position. A `v2` scheme would sit beside `v1`,
and would not replace it.

Fountain has the same problem when it receives a webhook. It solves that
problem with `FountainWeb.CachingBodyReader`, which keeps the raw body
available for the Stripe webhook. Copy it if you build a Phoenix receiver.

## The delivery contract

**At least once, and in no guaranteed order.** Retries and parallel delivery
both mean one event can arrive twice, and two events can arrive out of order.
Use `id` to drop duplicates. Do not assume that `conversation.turn.started`
lands before the `conversation.turn.done` beside it.

Fountain retries any response outside `200`-`299`. It retries a redirect too.
Fountain never follows a redirect, because a `302` to a private address
defeats the checks in the next section.

| Behaviour | Value |
|---|---|
| Attempts per event | 8, with exponential backoff, over about a day. |
| Request timeout | 10 seconds. |
| Redirects | Fountain never follows one. A `3xx` is a failure. |
| Response body | Fountain reads the first 4 KB and keeps it in the delivery log. |
| Concurrency | One job per endpoint per event. A slow receiver cannot stall a fast one. |

Answer `2xx` as soon as you have stored the event. Do not do the work inside
the request. A 10 second timeout turns that work into a retry storm.

### When Fountain switches an endpoint off

Fountain counts events that exhaust their retries. After 5 in a row, it sets
the endpoint to `disabled`, stops delivery, and emails the account owner. Any
delivery a receiver accepts clears the counter, so a flaky receiver never
trips the limit.

Repair the receiver. Then resume the endpoint and send a test event.

```bash
fountain webhooks resume <id>
fountain webhooks test <id>
fountain webhooks deliveries <id>
```

## The delivery log

Fountain records each attempt with its status code, duration and the first few
KB of the response.

```bash
fountain webhooks deliveries <id>
```

```
id        event                     try  result  took    detail
a41c…     conversation.turn.done    1    500     212ms   {"error":"boom"}
a41c…     conversation.turn.done    2    500     198ms   {"error":"boom"}
b90f…     conversation.turn.done    1    200     84ms
```

`fountain webhooks redeliver <endpoint-id> <delivery-id>` sends one of them
again. It uses the endpoint's current URL and current secret. The console
holds the same view and the same button at `/account/webhooks`.

The retention sweep prunes delivery rows after 30 days. They help you diagnose
a problem. They are not an event store.

## What a URL may point at

You choose the URL, and the request leaves from inside Fountain's network. So
Fountain checks the URL in three places.

- **When you save it.** Fountain demands `https://`, unless the instance sets
  `WEBHOOK_ALLOW_HTTP`. Fountain refuses credentials in the URL.
- **Before each request.** Fountain resolves the host. Every address the host
  answers with must be publicly routable. Fountain refuses loopback, link
  local, RFC1918, carrier grade NAT, and the documentation and reserved
  blocks. Every cloud metadata service sits on the link local block. A check
  at save time alone would be decorative, because DNS can change afterwards.
- **During the request.** Fountain connects to the address it just checked. It
  puts your hostname in the `Host` header and in TLS SNI. Nothing can swap the
  address underneath the check.

`WEBHOOK_ALLOW_HTTP` relaxes the scheme rule alone. It does not let a URL
point at a private address.

## Related

- [API reference](../api.md)
- [Conversation states](conversation-states.md)
- [Configuration reference](../configuration.md)
