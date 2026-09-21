# Run on a user's ChatGPT subscription

This page is for an app that builds on Fountain and wants its users' codex
agents to run on the users' own ChatGPT subscriptions. It says how the
feature works from the API, what your app must do, and how to verify that
your integration does it. The console does all of this on one page; this is
the same thing over `/api`.

!!! note "Status"

    On the hosted platform this is on for every account since 2026-09-21.
    On a self-hosted instance it is off unless the operator forces the
    `chatgpt_subscriptions` flag. Parts of it have not yet been used against
    the real service; see [feature status](../reference/feature-status.md).

## The model, in four sentences

A user links a ChatGPT subscription by a device-code sign-in; Fountain keeps
the tokens and renews them, and no route ever returns one. A subscription is
a **named grant**, and a user may hold several. **A grant does nothing until
a credential set names it.** A codex agent that uses that set then runs on
that subscription, and on nothing else: if the subscription is unusable, the
run fails with a reason rather than falling back to a key or to the
platform's account.

The last sentence is the one apps get wrong. Linking a subscription does not
change what any agent uses. A user who links one and then runs an agent
sees that agent use whatever it used before, which on the hosted platform is
the deployment's own account when the user has no OpenAI key. That is not a
bug. The set is the switch.

## The three steps your app drives

Every route below needs a **full-scope** account key. A `sprite` key or an
OAuth client with less than full scope gets `403 insufficient_scope`. An
id that belongs to another account is `404`.

### 1. Link: a device-code sign-in

```bash
curl -X POST "$FOUNTAIN/api/account/chatgpt-subscriptions/attempts" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"name": "Work"}'
```

The reply is an attempt: `id`, `state` `pending`, `user_code`,
`verification_url`, `poll_interval`, `expires_at`. Show the person the
`user_code` and a link to `verification_url`, taken from the reply and from
nowhere else. Then poll:

```bash
curl "$FOUNTAIN/api/account/chatgpt-subscriptions/attempts/$ATTEMPT_ID" \
  -H "Authorization: Bearer $KEY"
```

every `poll_interval` seconds. Fountain polls ChatGPT; your read contacts
nobody. `state` moves once, from `pending` to `completed`, `cancelled`,
`expired` or `failed`, and `user_code` is null after that. A `completed`
attempt has the new subscription's id in `result_grant_id`. A `failed` one has
`failure.reason`; for `account_already_linked` it also names the subscription
that already holds that ChatGPT account, which is the one to reconnect
instead. An attempt expires after fifteen minutes.

Show the code **only to the person who started the attempt**, and tell them
to enter a code only if they started it themselves. A person who enters
someone else's code links their subscription to that other account.

Limits: three open attempts per account, one per subscription for a
reconnect, ten starts an hour. The refusals are `409
chatgpt_link_attempts_exceeded`, `409 chatgpt_link_attempt_pending` (with
the open `attempt_id`), `409 chatgpt_grant_limit_reached` (with `count` and
`limit`) and `429 chatgpt_link_attempts_rate_limited` (with `Retry-After`).
Where linking is off, a new-subscription attempt is `404
chatgpt_subscriptions_not_enabled`; `GET /api/auth/me` reports the door as
`chatgpt_subscriptions_enabled`, so check it before showing a "Connect"
button.

### 2. Name it on a credential set

```bash
curl -X PATCH "$FOUNTAIN/api/account/inference-credential-sets/$SET_ID" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"chatgpt_grant_id\": \"$RESULT_GRANT_ID\"}"
```

The set now reports `chatgpt_grant` with the subscription's `name` and
`status`. Send `null` to clear it. Naming a grant on a set **ends that set's
running codex conversations** with `409 inference_source_changed`; do it
before launching, or warn the user.

Which set? An agent uses its own `inference_credential_id`, else the
account's default set. If your app manages one agent per user, name the
grant on the set that agent uses. `GET /api/account/inference-credential-sets`
lists them, default first. An account always has a default set.

Only codex runs use the grant. Any other OpenAI consumer on the same set
(opencode on an `openai/` model, for example) still needs an
`openai_api_key` in the set.

### 3. Run, and read what served the turn

Launch a conversation on an agent whose set names the grant, on the `codex`
runtime with an `openai/…` model. Each turn then carries a read-only
`inference` object:

```json
"inference": {"origin": "own", "scope": "grant", "chatgpt_grant_id": "…"}
```

`origin` is `own` for the user's credential and `platform` for the
deployment's; `scope` is `grant` when a subscription served the turn.
Fountain writes it when the turn starts and never changes it, so a later
change to the set relabels later turns only. **This object is your proof.**
A turn that ran on the platform account reads `origin: "platform"`, and one
on the set's own key reads `scope: "credential"`.

## What "no fallback" looks like to your app

A named subscription that is disconnected, revoked, expired, reconnect-
required, exhausted or removed refuses the run instead of substituting
anything:

- Launch: `409 chatgpt_grant_unusable` with `reason`, `grant_id`, `grant`
  (the name), `until` (set when the reason is `exhausted`) and a `message`
  that ends "start a new conversation".
- An existing conversation: the turn is refused, and the stream's
  `admission_refused` stage event carries the same fields.

Handle it by telling the user which subscription and why, and offering the
fix: reconnect it (a new attempt with `{"grant_id": …}`), clear it from the
set, or wait for `until`. Do not retry on another credential for them; that
is the decision Fountain deliberately does not make.

**Exhaustion** is detected only after a turn fails: the failing turn shows
codex's own message, Fountain then confirms the limit with OpenAI (at most
once every five minutes per subscription), and every later launch or turn
gets `reason: "exhausted"` with the reset time in `until`. The subscription
list shows `exhausted_until` too.

## Managing subscriptions

| Route | Does |
|---|---|
| `GET /api/account/chatgpt-subscriptions` | List, with `count`, `limit`, `linking_enabled`. Each has `id`, `name`, `status`, `plan_type`, `account_email`, `refreshable`, `exhausted_until`, `last_refreshed_at`. Never a token. |
| `PATCH …/:id` `{"name"}` | Rename. |
| `POST …/attempts` `{"grant_id"}` | Reconnect: a new sign-in for an existing subscription. The old credential keeps serving until the new one is stored. |
| `POST …/:id/disconnect` | Forget the tokens, keep the row. Sets that name it start refusing. |
| `DELETE …/:id` | Remove a disconnected subscription that no set names (`409 chatgpt_grant_named_by_sets` otherwise). |

Fountain renews an idle subscription about every six days. Fountain cannot
revoke a sign-in at OpenAI; a user who wants that signs the device out there.

## How to verify your integration

Run this once against a test account, in order. Each step has one
observable that proves it.

1. **Door.** `GET /api/auth/me` → `chatgpt_subscriptions_enabled: true`.
2. **Link.** Create an attempt, approve the code in a browser, poll to
   `completed`. Proof: the subscription appears in the list with `status:
   "active"`.
3. **Not yet in use.** Launch a codex conversation on the agent, send a
   prompt. Proof: the turn's `inference.origin` is **not** `own` with `scope:
   "grant"` (on the hosted platform it is `platform`). This is the step that
   proves you understand the model.
4. **Name it.** `PATCH` the agent's set with `chatgpt_grant_id`. Proof: the
   set reports `chatgpt_grant.name`.
5. **In use.** Launch a **new** conversation, send a prompt. Proof:
   `inference` reads `{"origin": "own", "scope": "grant", "chatgpt_grant_id":
   <the id>}`.
6. **No fallback.** Disconnect the subscription, then launch again. Proof:
   `409 chatgpt_grant_unusable` with `reason: "disconnected"` and the name,
   even though the platform account (or a key) would have worked. Your UI
   should show the reason, not a generic error.
7. **Reconnect.** Start an attempt with `{"grant_id"}`, approve, poll to
   `completed`. Proof: the list shows `active` again and a new launch runs
   on it.
8. **Two subscriptions, if you support them.** Link a second one under
   another name, name it on a second set, put two agents on the two sets.
   Proof: each agent's turns carry its own `chatgpt_grant_id`, and
   disconnecting one refuses only that agent's launches.

What you cannot verify from the API, and do not need to: the token is never
returned, and the sandbox never holds it. The broker attaches it to the one
route Codex uses and to nothing else.

## Two things to get right in the UI

- After a successful link, if the user holds exactly one subscription and
  the relevant set names nothing, offer to name it right there. Without that
  offer, step 3 above is what your users experience and they will read it as
  broken.
- A user who leaves to approve the code and comes back on another page
  needs to see the outcome. `GET …/attempts` lists **pending** attempts
  only, so keep each attempt's `id` on your side and read
  `GET …/attempts/:id` on return: an ended attempt stays readable by id,
  with its `state` and `failure`.

See also the [API guide](../api.md#chatgpt-subscriptions) for every refusal,
the [console guide](../guides/chatgpt-subscriptions.md) for what a user sees,
and the generated reference at `/api/docs` for the schemas.
