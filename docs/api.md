# API reference

Use the [generated API reference](/api/docs) for endpoints, parameters,
request bodies, response schemas, and error statuses. Fountain builds that
reference from the same OpenAPI descriptions that define its SDK contract.
The [OpenAPI document](/api/openapi.json) is public and needs no credential.

The reference describes the instance that serves it. On a self-hosted instance, open `/api/docs` on that instance.
This guide explains workflows; it does not maintain a second endpoint catalog.

For a script, start with the [TypeScript SDK](sdk.md). Use HTTP directly from
another language, or when your workflow needs a surface the SDK does not
expose.

## Authentication

Create an API key in the console under Account, then API keys. Store it
outside your source tree. Pass the key as a bearer token.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  "$FOUNTAIN_URL/api/agents"
```

Set `FOUNTAIN_URL` to your instance URL, without a slash at the end.
Use `fountain auth login` for a password account, or
`fountain auth login --device` for an account that uses GitHub sign-in.
Reuse that credential; repeated token exchanges create more keys.

Check the Auth operations in the [generated reference](/api/docs) for
account recovery, verification, key creation, revocation, and credential
expiry. A sandbox credential has restricted scope. Use an account credential
for administrative workflows.

### What a sandbox credential can do

Each sandbox gets a `FOUNTAIN_TOKEN`, a key with `sprite` scope. With it an
agent can read the account's agents, environments and vaults. It can also
start, prompt, stream and end conversations. That is enough to fan work out to
the agents you configured.

The token cannot change what an agent is, or what its sandbox is built from.
These requests need a full-scope key:

- creating, updating or deleting an agent, its avatar, an environment, a
  vault, or a secret in either, and copying a vault;
- `POST /api/apply`.

The same rule covers API keys, OAuth clients, secret bindings, a
conversation's egress log, inference credentials, account security, and a
sandbox's files.

A refused request gets `403` with `reason: "insufficient_scope"` and
`required_scope: "full"`. Without this rule, a prompt-injected agent could
rewrite an agent's instructions or an environment's setup script, and the
next launch would run what it wrote. It could also replace your inference
credentials or lock you out of the account.

### Sign in with Fountain (OAuth 2.0 for browser apps)

Browser apps use the authorization code flow with PKCE. The returned token
is a Fountain API key. Register the client and its exact redirect URIs
before you start the flow.

Keep the verifier in the app that initiated sign-in, and validate `state`
on return. See [Build a chat app](build/index.md) for the shape of such an
app and the OAuth operations in the [generated reference](/api/docs)
for the token exchange.

### Register your own app

Register a client in the console under **Account**, then **OAuth apps**, with
`fountain oauth-client create`, or through the API.

```
GET    /api/oauth/clients        # the account's clients
POST   /api/oauth/clients        # {name, redirect_uris} -> {client_id, ...}
GET    /api/oauth/clients/:id
PATCH  /api/oauth/clients/:id    # rename it, or replace the redirect URIs
DELETE /api/oauth/clients/:id
```

These routes need a full-scope key. A sandbox token cannot register a client.
A registered client leads to a full-scope key after consent.

Your client starts in **development mode**. It signs in only the account that
registered it. Every other account gets an error page instead of a redirect.
Only an operator publishes a client for other accounts. After that, only an
operator changes or removes the registration. Every other account signs in
through it, and the `client_id` is random, so a deletion breaks them all.

One account registers a maximum of 25 apps.

A redirect URI must match exactly and must use `https`. A URI on `localhost`
or `127.0.0.1` can use `http` and matches on any port.

The redirect origins also call `/api` from a browser. One registration covers
both sign-in and CORS. It needs no `OAUTH_CLIENTS` or `API_CORS_ORIGINS`
change.

## Account state

Read account identity (`GET /api/auth/me`) before you display
account-specific controls.

See the account and Auth operations in the [generated reference](/api/docs).

### Account deletion

Treat deletion as a separate, explicit user action. Deletion is immediate and
cannot be undone. See the account operations in the
[generated reference](/api/docs) for the deletion contract.

## Inference credentials

Inference credentials pay the model provider. Configure one when the selected
runtime needs it. A configured credential does not imply that a provider will
accept it.

Store provider keys in your account's
[inference credentials](concepts/secrets.md#inference-credentials). An account
holds one set of up to four: `anthropic_api_key`, `claude_code_oauth_token`,
`openai_api_key` and `gemini_api_key`. Values remain write-only; read
responses report which providers are set.

These routes require a full-scope account key.

| Method and path | Purpose |
|---|---|
| `GET /api/account/inference-credentials` | Which providers are set. |
| `PUT /api/account/inference-credentials/:provider` | Set one provider with `{"value": "..."}`, validated against the provider unless `validate` is `false`. |
| `DELETE /api/account/inference-credentials/:provider` | Clear one provider. |

The resolved source is bound to the conversation and recorded for each turn.
Wake and resume do not silently switch an existing conversation to another
credential after a replacement or deletion. See the
[sharing constraints](concepts/secrets.md#inference-credentials) and the
[generated reference](/api/docs) for response schemas and refusals.

### ChatGPT subscriptions

A codex run on an `openai/` model uses the account's ChatGPT subscription,
then the account's own `openai_api_key` (its own, an environment's or a
vault's). Subscriptions are linked in the console, not through the API; see
[Run Codex on a ChatGPT subscription](guides/chatgpt-subscription.md). A turn
on the account's subscription reports `scope: "grant"`. A conversation whose subscription
was disconnected, refused by OpenAI or linked to another account gets
`409 chatgpt_reconnect_required` on its next prompt or wake.

## Rate limiting

The resource API uses fixed one-minute windows.

- Each authenticated API key has a 600-request allowance.
- Failed authentication has a separate 600-request allowance per client address.
- A coarse ceiling allows 6,000 total attempts per client address before
  authentication. It includes failed authentication and requests over a key's
  quota. Exhausting it blocks every key at that address until its window resets.

Each key retains its individual allowance behind a shared ingress. All keys
count toward the coarse ceiling. Forwarded client addresses are accepted only from configured
`TRUSTED_PROXIES`; a direct caller cannot choose an address through headers.
Individual operations can impose additional limits.

Honor `Retry-After` when a request is rate limited. Avoid immediate retry
loops. A lost response to a mutation does not prove that the mutation failed;
reconcile the resource before you repeat an operation that could spend money.
See each operation's responses in the [generated reference](/api/docs).

## Agents

An agent is reusable configuration for a runtime and model. Create its
[environment](concepts/environment.md) and [vault](concepts/vault.md) first,
then reference them when you configure the agent.

Use version history to inspect configuration changes before a rollback.
See [Agents](concepts/agent.md) for the model and the Agents operations in
the [generated reference](/api/docs) for the complete contract.

## Catalog

Read the instance catalog before you offer runtime, provider, or app choices.
An integration should distinguish an unavailable capability from one that its
workflow does not require. The [generated reference](/api/docs) describes the
catalog response; the [Catalog](catalog/index.md) explains shipped resources.

## Environments

An environment supplies the packages, repositories, scripts, network policy,
and baseline secrets a machine needs. See [Environments](concepts/environment.md).
The [generated reference](/api/docs) defines the editable configuration and
secret operations. A secret write reaches running conversations the way a vault secret write does.

## Vaults

A vault supplies secret overrides without a duplicate environment.
See [Vaults](concepts/vault.md) for precedence and reuse. Submit secret values
through the write operations in the [generated reference](/api/docs); do not
expect read operations to return them. On a brokered deployment, a write or
delete reaches running conversations on the vault during their current turn,
at the sandbox's next connection through the broker. See
[Secrets](concepts/secrets.md#hop-3-environment-and-vault-merge).

To start a vault from another one's secrets, use `POST /api/vaults/:id/copy`.
The server copies the values, so they never cross the API.
See [Copy a vault](concepts/vault.md#copy-a-vault).

## Secret bindings

Use broker bindings when a sandbox should reference a credential while the
broker supplies its value to an approved destination. The credential value stays outside the sandbox.

See [Secrets](concepts/secrets.md) for the security model and the binding
operations in the [generated reference](/api/docs) for configuration.

Use `GET /api/auth/me` and its `brokered` field to decide whether to show
binding controls: bindings exist only on a deployment that runs the broker.

## Bulk apply

Use `fountain apply` when a checked-in manifest should define several related
resources. The CLI compiles the manifest and submits the resource graph.
Inspect every resource result. One failed resource does not mean that all
other writes failed. Apply needs a full-scope key; a
[sandbox credential](#what-a-sandbox-credential-can-do) is refused.

A manifest holds three kinds. Fountain reconciles them in a fixed order, which
is `Environment`, `Vault` and `Agent`, so an `Agent` can name its
`environment` whatever its position in the file. The name resolves against
the manifest first, then against the records the account already holds. A
name that matches neither fails that document alone.

The document name is the key for every kind. An absent `spec` key leaves
that field alone.

Apply is additive. A document that you delete from the manifest leaves its
record in place. There is no prune.

The audit trail names each applied row. Each row carries the actor and the IP
address of the request that applied it.

Each result row reports `created`, `updated`, `unchanged` or `error`. A
second apply of an unchanged manifest reports `unchanged` for every row, and
writes no audit event for those rows. Inline `spec.secrets` are encrypted
again on each apply, so they keep reporting `upserted` under a row that
reports `unchanged`.

See [CLI](cli.md) for the workflow and the Apply operation in the
[generated reference](/api/docs) for its wire format. Unknown configuration
keys fail validation before Fountain writes that resource's attributes or secrets.

## Conversations

Create a conversation with an agent and a first prompt, follow its events,
and send later prompts to that same conversation. Keep the returned ID.
A new conversation creates another thread.

Each turn has a read-only `inference` object that says which inference source
served it. `scope` is one of `credential`, `tenant_secret`, `grant` (the
account's [ChatGPT subscription](#chatgpt-subscriptions)), `none` and
`missing`. Fountain writes the object when the turn starts and does not
change it. A later change to the credential or a restart changes later turns
only. The object is null on a turn from before Fountain recorded it, and on
a turn that ran on a deployment's inference key before Fountain removed
those.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"YOUR_AGENT_ID","prompt":"Describe the files in the workspace."}' \
  "$FOUNTAIN_URL/api/conversations"
```

A first prompt is optional. A launch with no prompt creates the conversation
and waits for a later turn. A prompt that is present must contain words.
Fountain refuses blank or whitespace-only text with `422 invalid_prompt`.

Images need that first prompt. Fountain refuses images that arrive with no
text, and the error is `422 invalid_prompt`. An unsupported `media_type`,
empty bytes, or more than 10MB give `422 invalid_images`. Both checks run
before the launch reserves a sandbox, so bad input costs no machine.

This starts real work and can consume sandbox time and provider usage.
[Conversation states](reference/conversation-states.md) explains lifecycle
transitions. The Conversations operations in the
[generated reference](/api/docs) define prompt admission, permission answers,
interruption, termination, history, images, and event streams.

Use history for a durable transcript and SSE for live delivery. Persist the
event cursor so a reconnect can resume after the last event processed.
Request structured blocks to render ACP output. Historical vendor stdout
formats are no longer parsed; those events remain available as raw data.

### Open a thread at its newest turns

`GET /api/conversations/{id}/events` pages forward from `after` by default.
A long conversation holds thousands of events, and a client that shows only
the newest turns does not need to read all of them first. Ask for the newest
page instead:

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  "$FOUNTAIN_URL/api/conversations/$ID/events?order=desc&limit=200&whole_turns=true&blocks=true&prompts=true"
```

With `order=desc`, `data` is newest first. `meta.next_cursor` is the oldest
event ID on the page. Pass it as `before` to get the page before it.
`meta.has_more` says that older events exist. `page.newest_cursor` is the
newest event ID on the page. Pass the first page's value as `Last-Event-ID`
to follow the conversation over SSE from there.

`whole_turns=true` keeps a turn on one page. When the event at `limit` belongs
to a turn that started earlier, the page extends to that turn's first event.
The page keeps every event in that range, including events of another turn and
events with no turn. A page can therefore hold more events than `limit`. The
next page with `before` starts below the oldest event, so it returns earlier
turns only. Events with no turn, such as the setup before turn 1, page by
`limit` alone.

A page holds at most 5,000 events. A turn that is larger than that is cut
there, and `page.turn_split` is `true`. The rest of the turn is on the next
page. `whole_turns` requires `order=desc`, and Fountain answers `422` without
it.

Event IDs are global to the server, so the IDs in one conversation have gaps.
Use the cursors that a page returns, and do not compute one from an ID.
`streams`, `blocks` and `prompts` work the same in the two directions. Every
page has a `page` object with `order`, `oldest_cursor`, `newest_cursor` and
`turn_split`. Forward pages also accept `before` as an upper bound.

### Find the turn your prompt opened

`POST /api/conversations/{id}/prompts` answers before the turn exists. A
conversation with no machine must wake first, and the turn opens after that.
So the response cannot give you a turn ID. Give Fountain your own name for the
prompt instead.

The wake runs after the response, and so does the wait for a sandbox that is
still being set up or reattached. The request still refuses what needs no
sandbox to decide: a missing agent, a sandbox
being destroyed, or no room for one more sandbox. A wake that fails later is a
`wake` stage event with the `failed` state. Its `reason` says why, and
`retryable` says whether sending the prompt again can succeed. No turn opens
for that prompt.

```json
{"prompt": "Run the approved plan.", "client_request_id": "plan-7-step-3"}
```

The response repeats the value. Fountain stores it on the turn that the prompt
opens, and `GET /api/conversations/{id}/turns` shows it as `client_request_id`.
The turn holds the value you sent, character for character. It is the record.

The `turn` stage event with the `started` state carries the value next to
`turn_id`. Use that event to find a candidate turn quickly. Then read the turn
and compare its `client_request_id` with the value you sent. Bind your work
item only after that comparison.

Do not bind on the event alone. Fountain removes the sandbox environment values
from the data of every event. So an event shows `[REDACTED]` in the place of a
value that your ID contains, and a different client can send that same text as
its own ID. The two events are then equal and the two turns are not. Every
later event of the turn carries the same `turn_id`.

Two clients can send a prompt at the same moment. A conversation runs one turn
at a time, so one prompt opens the turn. The turn carries the value of that
client. Turn order cannot tell you that. When the conversation has a machine
that is awake, Fountain answers `conversation_busy` to the other client. When
the conversation must wake first, Fountain answers `queued` to the two clients.
It then drops the prompt that arrives second, and says so on the stream with a
`wake` stage event in the `failed` state and the reason `conversation_busy`.

The value is a string of 1 to 200 characters. It cannot contain a null
character; Fountain answers `422` for one that does. Send it in the request
body: Fountain does not read this field from the query string. Make the value
unique in the conversation. Fountain does not check that. **It is not an
idempotency key.**
A second prompt with the same value opens a second turn, and the two turns
carry the same value. Do not send a prompt again only because a response was
lost. Read the turns first.

`POST /api/conversations` takes the same field for its first prompt. The value
goes to turn 1 of a new conversation. Fountain ignores the value
when the request has no `prompt`. When a `channel_id` request returns a resumed
conversation, it does not deliver the prompt. Send the prompt to that
conversation on the prompts route, with the value.

An accepted prompt does not always open a turn. Fountain can refuse it after
the response: a limit on the conversation stops it, or another prompt opened the turn first. The stream reports some of these
refusals and not others. So do not wait without a limit for a `started` event
that carries your value. Set a time limit. Then read the turns.

A turn that carries your value shows that the prompt ran. No turn with your
value shows nothing. The prompt can still be waiting for the machine that must
start first. In that outcome you do not know whether the prompt ran. If you
send it again, the work can run two times.

A turn that Fountain opened by itself has the `autonomous` origin and a null
`client_request_id`.

The TypeScript SDK sends the value for you. It takes it on a run and on a
follow-up prompt: `run(prompt, { clientRequestId })` and
`send(prompt, { clientRequestId })`. A client that resumes a conversation with `channel_id` sends the value
again on the prompts route, because that request opens the turn. A client that
gets no value sends no field.

The CLI takes `--client-request-id` on `fountain run` and `fountain conv prompt`.
The ACP bridge takes `_meta.clientRequestId` on each `session/prompt`; see
[ACP prompt metadata](integrations/acp.md#_meta-extensions-on-sessionprompt).

### When the fleet is full

A start or a wake that would take the deployment past the fleet ceiling of
the provider the sandbox runs on (`SANDBOX_FLEET_CEILING_SPRITES`,
`SANDBOX_FLEET_CEILING_E2B`, each defaulting to `SANDBOX_FLEET_CEILING`) gets
`503 fleet_full` with `Retry-After: 60`. Nothing queues:
send the request again once a sandbox frees.

### Labels

A label is a `key=value` pair of strings on a conversation. A program stamps
its own runs with the facts it knew when the turn ended. Examples are
`env=prod`, `drift=true` and `gated=apply`. Labels are not searched. Use them
to slice a list.

Set them at creation, and read them back on every conversation object.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"YOUR_AGENT_ID","labels":{"env":"prod"}}' \
  "$FOUNTAIN_URL/api/conversations"
```

Filter a list with a repeatable `label` parameter. Fountain combines the
values with AND. The example keeps the conversations that carry both pairs.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  "$FOUNTAIN_URL/api/conversations?label=env:prod&label=drift:true"
```

Each value splits on its first colon. The key is the part before it, and the
value is all of the rest. `label=path:apps/fountain:lib` therefore filters the
key `path` for the value `apps/fountain:lib`. A value with no colon, or with
an empty key, returns 400 `invalid_label_filter`.

The parameter is an array in the OpenAPI document, with `style: form` and
`explode: true`. A client that builds arrays as `label[]=env:prod` is
accepted too.

`PATCH /api/conversations/{id}/labels` merges labels into a conversation. A
key the body does not name stays as it is. A key with a `null` value is
removed.

```bash
curl --fail-with-body -X PATCH \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"labels":{"drift":"true","env":null}}' \
  "$FOUNTAIN_URL/api/conversations/$CONVERSATION_ID/labels"
```

A conversation holds at most 32 labels. A key is at most 64 bytes and a value
is at most 256 bytes. Neither can contain a NUL byte. A write that breaks one
of these limits returns 422 and names the offending key under
`errors.labels`. The count applies to the merged result, so a merge can fail
against labels that are already there. The key named is one you sent, and
never one that was already on the conversation.

A create call to `POST /api/conversations` with a `channel_id` that resumes
a conversation also takes `labels`, and merges them into that conversation.

The account's own API key can label any of its conversations. A sandbox
callback token can label only the conversation it was minted for. Another
conversation returns 403 `sprite_may_not_label_another_conversation`. This
applies to both doors that write labels, which are the labels route and a
`channel_id` resume.

### An agent that labels its own run

An agent inside a turn does not need the route above. It sends an ACP
extension notification on the session it already holds. ACP keeps names that
start with `_` for extensions.

```json
{"jsonrpc":"2.0","method":"session/update","params":{
  "sessionId":"sess_1",
  "update":{"sessionUpdate":"_fountain/labels",
            "labels":{"drift":"true","env":"prod"}}}}
```

Fountain merges the map with the same rules as the route. A `null` value
removes a key. The notification never reaches the transcript, and it opens no
turn of its own. A stamp that breaks a limit is logged and dropped, and the
turn continues. Nothing in a stamp can end a run.

### Choose the model

A conversation runs its agent's model unless it names one of its own. Name one
at creation with `model`. The value is in canonical `provider/model_id` form.
It applies to this conversation only, for its whole life, and the agent keeps
its own model.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"YOUR_AGENT_ID","prompt":"Hello","model":"anthropic/claude-sonnet-5"}' \
  "$FOUNTAIN_URL/api/conversations"
```

The conversation object reports the override as `model`, and `null` means it
follows the agent. Each turn records the model it asked for under
`model_selection`.

Fountain checks the model as it checks an agent's model. A provider that the
runtime does not drive returns `422 model_invalid`. So does any model on the
`acp` runtime, which resolves none. Fountain does not check the model id
against a list, so a model released today works today.

A conversation without a `model` follows its agent. After you edit the agent's
model, its next turn returns `409 inference_source_changed`; start a new
conversation for the new model. A conversation with a `model` does not read
the agent's model, so the edit does not reach it.

The model is not part of a channel's resume key. A create request that resumes
a conversation through `channel_id` and names another model returns
`409 conversation_model_differs` before Fountain sends its prompt. Set
`fresh: true` to start a new conversation on it.

### Set reasoning effort and fast mode

Runtimes that speak ACP offer session config options beyond the model. The two
that clients ask for are reasoning effort and fast mode:

| Runtime | Effort | Fast mode |
|---|---|---|
| `claude` | `effort` | `fast` |
| `codex` | `reasoning_effort` | `fast-mode` |

Request them with `session_config`, a map of option id to a string or a
boolean. It can go in three places, and each one overrides the one before it,
key by key:

1. On the agent: every conversation of the agent requests it. A
   conversation copies the agent's options when it's created, so an edit to
   the agent reaches the conversations you create after it, not the ones
   that already exist.
2. On the conversation, at creation: the conversation requests it on every
   turn.
3. On a prompt: that turn requests it, and the next turn goes back to the
   conversation's options. An option that neither the conversation nor the
   agent names goes back to the value the runtime had before the session
   first changed it.

```bash
curl --fail-with-body   -H "Authorization: Bearer $FOUNTAIN_API_KEY"   -H "Content-Type: application/json"   -d '{"prompt":"Review the migration plan.","session_config":{"effort":"high","fast":true}}'   "$FOUNTAIN_URL/api/conversations/$CONVERSATION_ID/prompts"
```

Before each prompt, after the model, Fountain applies the options through ACP
`session/set_config_option`:

- An option already in force isn't sent again.
- An option the runtime doesn't offer for the current model is skipped, and
  the turn continues. Claude offers `effort` only on models that support it.
- An option an earlier turn set that this turn doesn't request is put back
  to the runtime's value from before that change.
- A value the runtime refuses fails the turn before the prompt is sent, with
  the runtime's own message.

Fountain checks only the shape of `session_config`: at most 16 options, ids of
letters, digits and `._:-`, and values that are a string or a boolean. A
malformed map returns `422 session_config_invalid`. `model` is refused, so use
the `model` field for it. Fountain doesn't check ids or values against a list,
because they differ by runtime and by model.

The runtime's permission mode is refused too: `mode` on `claude` and `codex`,
and `collaboration_mode` on `codex`. They return `422 session_config_invalid`.
Those options include `bypassPermissions` and `agent-full-access`, so a
request that sets one could widen the agent's `permission_policy`, which a
conversation may only narrow. Use `permission_policy` instead. An agent or
conversation that stored one of these ids before the refusal still runs, but
Fountain doesn't send that option. `session_config_options` doesn't list them.

To see what the current model offers, read the conversation's
`session_config_options`: the options the runtime advertised before the latest
prompt, each with its `id`, `category`, `type`, `options` and `currentValue`.
It's `null` until a turn has run. Each turn records its options under
`config_selection`:

- `requested`: the merged request;
- `applied`: each id mapped to the value the runtime confirmed;
- `skipped`: the ids the runtime didn't offer;
- `restored`: each id that an earlier turn set and this turn didn't request,
  mapped to the value the runtime confirmed when it was put back;
- `status` and `error`: set when the runtime refused a value.

Each option also emits a `config` stage event on the conversation's stream:
`done` with `outcome` set to `applied`, `skipped` or `restored`, or `failed`.

A create request that resumes a conversation through `channel_id` and names a
different `session_config` returns `409 conversation_session_config_differs`.
Send them on the prompt, or set `fresh: true`.

### Workers without Fountain API access

Set `sandbox_api_access` to `none` when the host must retain Fountain API
authority. Fountain omits its sandbox callback credential before provision
and on every wake or reattachment. The default, `owner`, retains existing
behavior.

This setting is immutable, like the conversation's sandbox, which is always
its own. A channel resume with a different explicit setting fails.

Discover support in `GET /api/catalog` under `sandbox_api_access`. The host
can still send prompts and read events and files. The worker cannot use
Fountain MCP tools or connections that require its callback credential.

This option controls the credential Fountain creates. It does not remove
credentials supplied through environments, vaults, or custom MCP configuration.
Use a dedicated account containing only these workers for mutually untrusted
repositories. Keep the account's full API keys on the service host.

### Every conversation on one stream

Use the account event stream for a conversation list with live updates.
Refresh the list when a conversation-change notification arrives. Keep each
conversation's history available for reconciliation after a reconnect.

The Events operations in the [generated reference](/api/docs) define stream
selection, cursors, and framing. See [Build a chat app](build/index.md) for
how a client combines the list, transcript, and live stream.

## Sandboxes

A sandbox is the machine that hosts a conversation. Every conversation has
one of its own, and the sandbox operations are read-only: list them, and get
one with its conversation.

See [Sandboxes](concepts/sandboxes.md) and
[Sandbox lifetime](guides/operate/sandbox-lifetime.md). The Sandboxes operations
in the [generated reference](/api/docs) describe the fields.

### Files, git status and git diff

Use the sandbox read operations to inspect files and changes while an agent
works. Reads do not wake a parked machine. A diff compares tracked content
only. To see a file the agent made and never staged, use the git status
operation. Its entry paths are relative to the repository root, not to the
sandbox home.

The [generated reference](/api/docs) defines path confinement, byte limits,
truncation, encoding, comparison options, and the untracked modes. Check
truncation before you show a response as a complete file. Treat redacted
output as a display value.

## Search

Use account-scoped search to find resources and conversation content the caller
can access. Search results are navigation aids; fetch the selected resource
before you act on its current state. See Search in the
[generated reference](/api/docs).

## A long-lived agent, or one on a clock

Fountain has no team and no scheduler of its own; both were removed. An app
that wants one agent it talks to for weeks keeps that conversation's id and
sends each message to `POST /api/conversations/{id}/prompts`. A suspended
conversation wakes on the prompt. To find it again by a key of your own,
create it with a `channel_id` (a Slack channel, a ticket number): a later
create with the same `channel_id` resumes it, and one that has ended is
replaced under the same binding.

An app that wants work on a clock runs its own cron and sends the prompt
when it fires. A `503 fleet_full` or `sandbox_unavailable` carries
`Retry-After`; retry after it.

A browser client on another origin needs a registered OAuth client or an
`API_CORS_ORIGINS` entry. Read [configuration](configuration.md). A bearer
key is the one credential that crosses an origin.

## Admin

`/api/admin/*` needs an account with the admin role and an admin key, a key
with `admin` among its `scopes`. No other key an admin holds works there: not
a key from `fountain auth login` or `POST /api/auth/token`, not the token an
app receives from Sign in with Fountain, and not one minted at
`POST /api/auth/api-keys`. Each of those gets `403` with
`error: "admin_key_required"`.

Mint an admin key as the admin, on **Account → API keys** with **Admin key**
checked, or with a release task (see
[Run a release task](guides/operate/run-a-release-task.md)):

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.create_admin_key("ops@example.com", "provisioner")'
```

The release task prints the key once. Give an admin key to one place, such
as a platform's provisioner, and revoke it there when you rotate it. Taking
the admin role away stops its admin keys working.

Use tenant-scoped resource reads for ordinary application work. An operator's
metadata access does not grant access to another tenant's prompt or output.

See Admin in the [generated reference](/api/docs) for account controls,
sandbox maintenance, and privilege-trail events.

## Audit

Use the audit trail to investigate who changed a resource and when.
A transcript describes agent work; the audit trail describes account and
resource actions. The [generated reference](/api/docs) defines filters,
pagination, and returned metadata.

## Error responses

Every JSON error status declares one schema, `Error`. Its `error` field is
the machine-readable code to branch on. The other fields accompany particular
codes and are absent otherwise: `message` is a sentence for a human, `errors`
holds field validation messages beside `validation_failed`. On the
key-authentication and scope refusals `error` is a sentence and `reason`
carries the code. A 406 is the one
exception: content negotiation fails before any operation runs and renders
`{"errors": {"detail": "Not Acceptable"}}`.

The [generated reference](/api/docs) declares shared pipeline errors alongside
controller responses. Reconcile state after a timeout before you retry a
mutation. Honor retry guidance where present, and refresh credentials when
the response identifies an expired or revoked key.

## LLM-native discovery

Use `/llms.txt` for a short introduction, `/llms-full.txt` for the manual,
and `/skill` for an editor skill. Use the [OpenAPI document](/api/openapi.json)
for machine-readable endpoint contracts.
See [LLM integration](llm-integration.md) for integration guidance.
