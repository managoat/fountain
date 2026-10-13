# The Sprites transport reference

This page documents the **Sprites adapter's** transport contract. It covers
each endpoint that `Managoat.Sandbox.Sprites` calls, the semantics it depends
on, and the operational assumptions it makes.

[The sandbox contract](sandbox-contract.md) is the provider-neutral contract
that each backend must meet. That is the `Managoat.Sandbox` behaviour and its
conformance suite, `Managoat.Sandbox.ConformanceCase`, which the
[E2B](e2b.md) adapter also satisfies. To evaluate a
new backend, start there. This page is the reference for what the first
backend provides.

The [Sprites integration guide](sprites.md) holds the setup and the cost
model.

Here is the transport in one line. It is REST over HTTPS with
`Authorization: Bearer <token>`, one WebSocket transport for command
execution, and an endpoint that streams NDJSON for checkpoints.

---

## The surface it consumes

| Operation | Endpoint | What depends on it |
|---|---|---|
| Create a sprite | `POST /v1/sprites`, JSON `{"name": …}`, allowed 120s. | Each conversation start. |
| Get a sprite | `GET /v1/sprites/{name}`, where 404 means not found. | A wake, and sandbox reuse. |
| Destroy a sprite | `DELETE /v1/sprites/{name}`, where **404 counts as success**. | Terminate, a configured max-lifetime ceiling, the reaper, and account deletion. An idle suspend deliberately calls nothing, because the sprite scales to zero on its own. |
| List sprites | `GET /v1/sprites`, paginated, as below. | The reaper's hourly reconciliation. |
| Write a file | `PUT /v1/sprites/{name}/fs/write?path=…&workingDir=…&mode=…&mkdirParents=…`, with a raw body. | The env file, inline skills, and the runtime config files. |
| Execute, and block | A WebSocket at `/v1/sprites/{name}/exec`. Run to exit, then collect the output. | Package installs, git clones, setup scripts, and the runtime preparation. |
| Execute, and stream | The same WebSocket, with `detachable=true`. | The agent turn itself. |
| List sessions | `GET /v1/sprites/{name}/exec` → `{"sessions": […]}` | A reattach after a deploy or a crash. |
| Attach a session | A WebSocket at `/v1/sprites/{name}/exec/{session_id}`. | A resume of a turn that runs. |
| Create a checkpoint | `POST /v1/sprites/{name}/checkpoint`, with an NDJSON response. | A warm start. |
| Restore a checkpoint | `POST /v1/sprites/{name}/checkpoints/{id}/restore`, with an NDJSON response. | A warm start. |
| Set a network policy | `POST /v1/sprites/{name}/policy/network`, where success is **exactly 204**. | An environment with `networking_type: limited`. |

Pagination on `GET /v1/sprites` works like this. The server pages, at 50,
which is its choice, and the client sends no page-size parameter. The response
carries `sprites`, `has_more` and `next_continuation_token`. The client passes
`continuation_token` back until `has_more` is false.

Fountain refuses to act on a partial list. A reconciler that saw half the
account would draw exactly the wrong conclusions.

---

## The exec transport

Command execution is a WebSocket upgrade of `/v1/sprites/{name}/exec`. The
client sends the bearer token again on the upgrade, and has ten seconds to
complete it.

The command travels in the query string. That is `path`, one repeated `cmd`
for each argv entry, repeated `env=KEY=VALUE` pairs, and `stdin=true|false`.
It also takes an optional `dir`, an optional `tty` with `rows` and `cols`, and
an optional `detachable=true`.

Frames are binary, with a one-byte stream id in front.

| First byte | Meaning |
|---|---|
| `0` | stdin, client to server. |
| `1` | stdout. |
| `2` | stderr. |
| `3` | exit, and then a one-byte exit code. |
| `4` | stdin EOF, client to server. |

In TTY mode the prefix disappears. A binary frame is then raw terminal bytes,
and a JSON text frame carries a control message, which is `exit`, `resize` or
`port`.

Fountain depends on three subtleties.

- **The exit code is one byte.** This page said four bytes until August 2026,
  and our Elixir client read four. No real frame `3` ever matched, so the
  client discarded every one of them. Read
  [#880](https://github.com/managoat/fountain/issues/880) before you
  change this row.
- **A close with no exit frame counts as exit 0.** A replacement that drops a
  connection and sends no frame `3` makes a failed command look successful.
  This rule is what turned the wrong width into silence. The client dropped
  the frame, the socket closed, and the command reported success.
- The client enforces the timeout for each command. The turn itself runs
  unbounded, and the [sandbox lifecycle](../architecture.md) ends it. The
  transport does not.

---

## Sessions

`detachable=true` on the spawn is the contract that lets a deploy happen
safely. The process on the sprite side continues when the WebSocket drops.
It appears in `GET /v1/sprites/{name}/exec`, with `id`, `command`, `created`,
`last_activity`, `is_active` and `tty`. You can re-join it at
`/v1/sprites/{name}/exec/{session_id}`.

- A detached session reports `is_active: false` while nobody holds a
  connection to it. Fountain deliberately does not filter on that field.
- **An attach replays the session's buffered output from the start, then
  tails.** There is no offset parameter. Fountain removes the duplicates. It
  counts the bytes it already persisted for each stream, then drops that many
  from the head of the replay. A replacement must replay from the start, or
  that arithmetic breaks.

---

## Checkpoints

Create is `…/checkpoint`, singular. Restore is `…/checkpoints/{id}/restore`,
plural. Both answer with NDJSON, one JSON object for each line, as
`{"type": "info"|"stdout"|"stderr"|"error", …}`. The create stream surfaces
the new checkpoint's id, and Fountain stores that on the environment.

Here is the promise Fountain depends on. To restore a checkpoint reproduces
the filesystem state at the moment of the create. Fountain can then skip the
cold pipeline, which is packages, clone and setup.

A restore that fails is not fatal. Fountain clears the stored checkpoint id
and falls back to the cold path.

---

## Network policy

The body is
`{"rules": [{"domain": …, "action": "allow"|"deny", "include": …}]}`.

One semantic matters most. **An empty rules list means no enforcement, which
is allow-all, and not deny-all.**

For a `limited` environment with an empty allowlist, Fountain sends an
explicit `{"domain": "*", "action": "deny"}`. It deliberately omits
`include: "defaults"`, which would add the platform's own allowances back.

A replacement that treats `rules: []` as deny-all is safer than Sprites here.
One that ignores a deny rule fails the whole `limited` feature open.

---

## Operational assumptions

- **Timeouts.** `SPRITES_TIMEOUT_MS` bounds each REST call, and it is 30s by
  default. Create alone gets 120s. An exec command carries its own bound: 5s
  for a chmod, 30 to 120s for a runtime probe and the setup script, 300s for a
  package install, 600s for a clone, and unbounded for the turn.
- **Retries.** Fountain tries a transient failure up to three times, so the
  first call and two retries, with exponential backoff and jitter. It does
  that on the provision path alone. Transient means a 5xx, a 429, a timeout or
  a transport error. Another 4xx fails fast, because a 401 or a 403 is a token
  problem, and not weather.
- **Idempotency is Fountain's job, and not the API's.** A sprite name is
  unique for each token, as `fountain-<tenant-prefix>-<8 hex>`. A 409 on
  create means the sprite already exists. Fountain then adopts it, and raises
  no error. Destroy tolerates a 404. The hourly reaper converges
  whatever the successful path leaked. A replacement needs stable name-keyed create
  and destroy semantics, and no more.
- **Errors.** Any non-2xx surfaces as a status plus the decoded body. A
  rate-limit response carries a structured body, with
  `sprite_creation_rate_limited`, `concurrent_sprite_limit_exceeded` and
  `retry_after_seconds`. Fountain handles those generically today, as 429s.
- **The bill.** One platform token pays for each sandbox (ADR 0005). That is
  why the fleet ceiling counts a sandbox from the moment a provision
  starts, and why the reaper exists at all.

---

## The failure model

| When Sprites is… | What happens |
|---|---|
| Down at provision time. | Fountain retries within bounds, then marks the conversation `failed`. The stage events name the step. |
| Down at wake time. | Fountain marks the sandbox `failed`. The conversation stays resumable, and re-provisions on the next prompt. |
| Dropped mid-turn. | The detachable session continues on the sprite side. A reattach picks it up, and replay-from-start plus the byte skip restores the stream. |
| Slow. | `SPRITES_TIMEOUT_MS` bounds each call, and Fountain retries a timeout like any other transient failure. |
| Down entirely. | Everything that is not a sandbox still works, which includes sign-in, configuration and past logs. Readiness deliberately leaves Sprites out, so a pod does not go NotReady over a third party. |

---

## What a replacement must provide

Here is the checklist. It needs the twelve operations above and bearer auth.
It needs name-keyed idempotent create and destroy, with a 409 on a duplicate
and a delete that tolerates a 404. It needs the stream-id frame protocol with
a real exit frame, and detachable sessions that replay from the start. It
needs NDJSON checkpoints that restore filesystem state, a network policy
that can deny, and `has_more` and `next_continuation_token` pagination.

Get those semantics right, and the four subtle ones above with them.
`SPRITES_BASE_URL` is then the only thing that changes.
