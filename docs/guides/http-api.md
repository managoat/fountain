# Call the API over HTTP

This page walks through the tasks that most code calling Managoat over HTTP
has to do: authenticate, start a conversation, follow its events, send a
follow-up prompt and find the turn it opened. The same requests serve any
language. If you write TypeScript, the [TypeScript SDK](../sdk.md) does
these steps for you.

The field limits, error codes and rules behind each step are in the
[API reference](../api.md). The [generated reference](/api/docs) on your
instance lists every endpoint, parameter and response schema.

## Before you start

Set `MANAGOAT_URL` to your instance URL, without a slash at the end. You need
an agent to run; read [Agents](../concepts/agent.md) to create one, or use
the one the [quickstart](../quickstart.md) made.

## Authenticate

1. Create an API key in the console under **Account**, in the **API keys**
   section. Store it outside your source tree.

   From a terminal, `managoat auth login` mints one for a password account,
   and `managoat auth login --device` for an account that uses GitHub
   sign-in. Reuse that key: every exchange creates another one.

2. Pass the key as a bearer token on every request.

   ```bash
   export MANAGOAT_API_KEY=...
   curl --fail-with-body \
     -H "Authorization: Bearer $MANAGOAT_API_KEY" \
     "$MANAGOAT_URL/api/agents"
   ```

Code that runs inside a sandbox already holds `MANAGOAT_TOKEN`, a key with
narrower rights. Read
[What a sandbox credential can do](../api.md#what-a-sandbox-credential-can-do)
before you rely on it.

## Start a conversation

Create the conversation with an agent and a first prompt.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"YOUR_AGENT_ID","prompt":"Describe the files in the workspace."}' \
  "$MANAGOAT_URL/api/conversations"
```

Keep the `id` from the response. Every later prompt goes to that ID; a new
create starts another thread. This request starts real work, which uses
sandbox time and provider usage.

The first prompt is optional. Without one the conversation starts and waits
for a prompt. To run it on a model other than the agent's, add `model`
([Choose the model](../api.md#choose-the-model)). To stamp it with facts you
can filter by later, add `labels` ([Labels](../api.md#labels)).

## Follow its events

There are two ways to read what the agent does. History is the durable
transcript; the event stream (SSE) delivers it live. A client usually reads
the newest page of history first, then follows the stream from there.

1. Read the newest page, with whole turns, rendered as blocks:

   ```bash
   curl --fail-with-body \
     -H "Authorization: Bearer $MANAGOAT_API_KEY" \
     "$MANAGOAT_URL/api/conversations/$ID/events?order=desc&limit=200&whole_turns=true&blocks=true&prompts=true"
   ```

   `data` is newest first. Show it in reverse.

2. Keep the page's `page.newest_cursor`. Open the event stream with that
   value as `Last-Event-ID` to receive every event after it.

3. Persist the ID of the last event you processed. After a disconnect,
   reconnect with it as `Last-Event-ID`, so you resume after that event and
   miss nothing.

4. When the reader scrolls up, pass the page's `meta.next_cursor` as `before`
   to get the page before it. Stop when `meta.has_more` is `false`.

Use the cursors the server returns; event IDs have gaps, so do not compute
one. [Open a thread at its newest turns](../api.md#open-a-thread-at-its-newest-turns)
has the paging rules, and the Events operations in the
[generated reference](/api/docs) have the stream's framing.

## Send a follow-up and find its turn

`POST /api/conversations/{id}/prompts` answers before the turn exists, so it
cannot return a turn ID. Name the prompt yourself with `client_request_id`,
then find the turn that carries that name.

1. Send the prompt with an ID that is unique in the conversation:

   ```bash
   curl --fail-with-body \
     -H "Authorization: Bearer $MANAGOAT_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"prompt":"Run the approved plan.","client_request_id":"plan-7-step-3"}' \
     "$MANAGOAT_URL/api/conversations/$ID/prompts"
   ```

   A suspended conversation wakes on the prompt; you do not wake it first.

2. On the stream, watch for the `turn` stage event in the `started` state
   that carries your value. It names the candidate `turn_id`.

3. Read `GET /api/conversations/{id}/turns` and compare that turn's
   `client_request_id` with the value you sent. Bind your work item to the
   turn only when they match. An event alone is not proof, because event data
   is redacted.

4. Wait with a time limit. An accepted prompt can still be dropped, for
   example when another client's prompt opened the turn first. When the limit
   passes, read the turns: a turn with your value shows the prompt ran.

Do not resend a prompt only because a response was lost.
`client_request_id` is not an idempotency key, so a second send opens a second
turn. Read the turns first.
[Find the turn your prompt opened](../api.md#find-the-turn-your-prompt-opened)
has the full rules, including what happens when two clients send at once.

## Follow every conversation on one stream

A conversation list with live updates reads the account event stream instead
of one stream per conversation.

1. List the conversations with `GET /api/conversations`.
2. Open the account event stream.
3. When a conversation-change notification arrives, refresh that entry in
   the list.
4. After a reconnect, reconcile from each open conversation's history.

[Build a chat app](../build/index.md) shows how a client combines the list,
the transcript and the live stream.

## Keep one agent for weeks, or run on a clock

Managoat has no scheduler. For one agent you talk to over weeks, keep its
conversation ID and send each message to its prompts route. To find it again
by a key of your own, such as a Slack channel or a ticket number, create it
with a `channel_id`: a later create with the same `channel_id` resumes that
conversation, or replaces it under the same binding when it has ended.

For work on a clock, run your own cron and send the prompt when it fires.

## Sign users in from a browser app

A browser app uses Sign in with Managoat, the OAuth 2.0 authorization code
flow with PKCE. The token it receives is a Managoat API key.

1. Register the app in the console under **Account**, in the **OAuth apps**
   section, or with `managoat oauth-client create`. List each redirect URI
   exactly. The registration also allows those origins to call `/api` from a
   browser, so there is no separate CORS setting to change.
2. Send the user to the authorize endpoint with a PKCE challenge and a
   `state` value. Keep the verifier in the app that started sign-in.
3. On the redirect, check `state`, then exchange the code and the verifier
   for the token.
4. Call the API with that token as a bearer key.

A new client signs in only the account that registered it, until an operator
publishes it. [Register your own app](../api.md#register-your-own-app) has the
rules, and the OAuth operations in the [generated reference](/api/docs) have
the token exchange. [Build a chat app](../build/index.md) shows the shape of
such an app.

## Retry safely

- On `429`, wait for `Retry-After` before you send again. Do not loop.
- On `503 fleet_full` or `sandbox_unavailable`, wait for `Retry-After` and
  send again; nothing queues for you.
- After a timeout on a request that changes something, read the resource
  before you repeat the request. A lost response does not prove the change
  failed, and repeating it can spend money twice.
- On a revoked or expired key, get a new one rather than retrying.

[Rate limiting](../api.md#rate-limiting) and
[Error responses](../api.md#error-responses) have the limits and the error
shape.
