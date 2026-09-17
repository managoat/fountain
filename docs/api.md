# API reference

Use the [generated API reference](/api/docs) for endpoints, parameters,
request bodies, response schemas, and error statuses. Fountain builds that
reference from the same OpenAPI descriptions that define its SDK contract.
The [OpenAPI document](/api/openapi.json) is public and needs no credential.

The reference describes the instance that serves it, with its installed
extensions. On a self-hosted instance, open `/api/docs` on that instance.
This guide explains workflows; it does not maintain a second endpoint catalog.

For a script, start with the [TypeScript](sdk.md), [Python](python-sdk.md),
[Elixir](elixir-sdk.md), or [Swift](swift-sdk.md) SDK. Use HTTP directly when
your language or workflow needs a surface the SDK does not expose.

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

### Sign in with Fountain (OAuth 2.0 for browser apps)

Browser apps use the authorization code flow with PKCE. The returned token
is a Fountain API key. Register the client and its exact redirect URIs
before you start the flow.

Keep the verifier in the app that initiated sign-in, and validate `state`
on return. See [Build a team chat](build/team-chat.md) for an application
example and the OAuth operations in the [generated reference](/api/docs)
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

Read account identity before you display account-specific controls. The console
uses onboarding state to show setup progress. An API integration can complete
setup without following the console checklist.

See the account and Auth operations in the [generated reference](/api/docs).

### Billing

Hosted work spends a credit balance. An idle machine does not burn turn
credits. Check the account's available balance before you offer a workflow
that starts paid work, and handle a refusal when admission occurs.

See [Billing](guides/operate/billing.md) for operation and
[Sandbox spend](guides/operate/sandbox-spend.md) for the distinction between
turn usage and provider usage. The [generated reference](/api/docs) describes
account balances, purchases, and payment errors.

### Data export and deletion

Export account data before you delete an account if you need an archive.
Treat deletion as a separate, explicit user action. See the account operations
in the [generated reference](/api/docs) for the export and deletion contracts.

## Inference credentials

Inference credentials pay the model provider. Fountain credits pay for
Fountain's hosted work. Configure both when the selected runtime needs them.
A configured credential does not imply that a provider will accept it.

Store provider keys in named [credential sets](concepts/secrets.md#credential-sets).
The first set an account creates is its default. An account with no sets gets
a Default set on its first provider write through the original account route.
Existing credential rows become Default sets on upgrade. A set can hold
`anthropic_api_key`, `claude_code_oauth_token`, `openai_api_key` and
`gemini_api_key`. Values remain write-only; read responses report which
providers are set.

These routes require a full-scope account key.

| Method and path | Purpose |
|---|---|
| `GET /api/account/inference-credential-sets` | List sets, default first and then by name. |
| `POST /api/account/inference-credential-sets` | Create an empty set with a `name`. |
| `PATCH /api/account/inference-credential-sets/:id` | Rename with `name`, or promote with `is_default: true`. |
| `DELETE /api/account/inference-credential-sets/:id` | Delete a non-default set. Promote another first to delete the current default. |
| `PUT /api/account/inference-credential-sets/:id/credentials/:provider` | Set one provider with `{"value": "..."}`. |
| `DELETE /api/account/inference-credential-sets/:id/credentials/:provider` | Clear one provider in that set. |

Names must be unique within the account. Omitting a PATCH field leaves it
unchanged; `is_default: false` is refused. The original
`GET /api/account/inference-credentials` and
`PUT` or `DELETE /api/account/inference-credentials/:provider` routes operate
on the default set.

Set `inference_credential_id` on an agent to choose its default, or on
`POST /api/conversations` to request a launch override. The agent's
`allowed_inference_credential_ids` bounds that override. `null` permits any
set the account owns, `[]` forbids a different set, and a non-empty list
permits those IDs. The agent's own selection remains allowed. Omit the
selection to use the agent's set, then the account default. A foreign,
deleted or unusable explicit source is refused instead of selecting another.

The resolved source is bound to the conversation and recorded for each turn.
Changing the account default applies to new selections. Wake and resume do
not silently switch an existing conversation to another credential after a
replacement or deletion. See the [sharing constraints](concepts/secrets.md#credential-sets)
and the [generated reference](/api/docs) for response schemas and refusals.

## Claimable principals

A claimable principal lets an application start a computer before its visitor
has a Fountain account. A claim attaches an owner; resource IDs and the
tenant stay the same.

Follow [Start before sign-in](build/anonymous-visitors.md). Use the documented
idempotency key to reconcile a lost create or claim response. A repeated
request can return a fresh credential, so keep the latest successful result.
The [generated reference](/api/docs) defines required scopes and refusals.

### Set a principal's provider credential

Use `PUT /api/claimable-users/:id/inference-credentials/:provider` with
`{"value": "..."}` to write a provider credential to the principal's default
set. Use `DELETE` on the same path to clear it. Here `:id` is the claim grant
ID returned by `POST /api/claimable-users`, not the principal's tenant ID.
Both operations return `204` on success, and encrypt under the principal's
own tenant key. They do not validate the value with the provider.

These writes require the current owner's full-scope key. Before claim, that
is the application account that opened the principal. After claim, it is the
account that claimed it; the original application loses credential-write
access. A `principal`-scoped key gains no account-write permission. Use
[principals](build/anonymous-visitors.md) for customer isolation; multiple
sets on one account do not create separate tenants.

## Rate limiting

The resource API uses fixed one-minute windows, independently on each server
replica.

- Each authenticated API key has a 600-request allowance.
- Failed authentication has a separate 600-request allowance per client address.
- A coarse ceiling allows 6,000 total attempts per client address before
  authentication. It includes failed authentication and requests over a key's
  quota. Exhausting it blocks every key at that address until its window resets.

Each key retains its individual allowance behind a shared ingress. All keys
count toward the coarse ceiling. Forwarded client addresses are accepted only from configured
`TRUSTED_PROXIES`; a direct caller cannot choose an address through headers.
These counters are per replica, so distributing requests across replicas can
multiply an allowance. Individual operations can impose additional limits.

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
secret operations. Changes can affect persistent machines built from it.

## Vaults

A vault supplies secret overrides without a duplicate environment.
See [Vaults](concepts/vault.md) for precedence and reuse. Submit secret values
through the write operations in the [generated reference](/api/docs); do not
expect read operations to return them.

## Secret bindings

Use broker bindings when a sandbox should reference a credential while the
broker supplies its value to an approved destination. The credential value stays outside the sandbox.

See [Secrets](concepts/secrets.md) for the security model and the binding
operations in the [generated reference](/api/docs) for configuration.

## Connections

A connection authorizes access to an external service through its OAuth flow.
It is distinct from an API key for Fountain. See
[Connections](catalog/connections/index.md) for supported services and setup.
The [generated reference](/api/docs) describes discovery and connection state.

Use `GET /api/auth/me` to decide which controls to show:
`connections_enabled` allows adding connections, providers, and credential
bindings; `connections_manageable` allows listing and removing existing ones.
Keep removal controls visible when `connections_manageable` is true, even if
`connections_enabled` is false.

### Connection providers

An instance must configure a provider before an account can connect it.
For an external service, follow [Register your own OAuth app](guides/connect/own-oauth-app.md).
Use provider discovery from the [generated reference](/api/docs) to decide
which connection choices the UI can offer.

## Bulk apply

Use `fountain apply` when a checked-in manifest should define several related
resources. The CLI compiles the manifest and submits the resource graph.
Inspect every resource result. One failed resource does not mean that all
other writes failed.

A manifest holds six kinds. Fountain reconciles them in a fixed order, which
is `Environment`, `Vault`, `Agent`, `Teammate`, `Schedule` and `Webhook`. A
document can name another document whatever its position in the file. An `Agent` names an
`environment`. A `Teammate` names an `agent`, an `environment` and a `vault`.
A `Schedule` names a `teammate`. A teammate's name is not unique, so a name
that two teammates answer to fails that row rather than binding to one of
them. Each name resolves against the manifest first, then against the records
the account already holds. A name that matches neither fails that document
alone.

The document name is the key for five of the kinds. `Webhook` is the
exception, and is keyed by `spec.url`. Change that URL and the apply creates
a second endpoint. The first one stays, and keeps delivering, until you
delete it through the webhook routes.

A `Teammate` document is the whole teammate. Drop `environment` or `vault`
from it and the apply clears that binding, which puts the teammate back on
the agent's own environment and on no vault. The other five kinds behave the
other way around, where an absent `spec` key leaves that field alone.

Rebinding a teammate moves its computer. Fountain retires the machine the old
binding named, so the next message builds one from the new environment and
vault. It refuses the whole row while a turn is running on that machine. A
conversation that shared the retired machine, and that names a different
environment or vault, does not follow the teammate onto the new one. It
builds a machine from what it names on its own next message.

Fountain keeps one machine for each agent, environment and vault. The row
fails when the agent already has one on the environment and vault the
teammate moves to. Fountain does not join the teammate to that machine.
Reset or delete the machine first, then apply again.

Apply is additive. A document that you delete from the manifest leaves its
record in place. There is no prune.

The audit trail names each applied row. Teammate rows record
`team.member.added` and `team.updated`, and schedule rows record
`team.schedule.created` and `team.schedule.updated`, and webhook rows record
`webhook_endpoint.created` and `webhook_endpoint.updated`. The webhook actions
carry the `webhook_endpoint` prefix that the webhook routes have always
written, not a shorter `webhook` one. Each row carries the actor and the IP
address of the request that applied it.

A `Webhook` that an apply creates carries its signing secret in that result
row. Fountain shows the secret one time. An update of the same endpoint
carries no secret. A manifest that holds a `Webhook` needs a full-scope
credential, which is what `POST /api/webhooks` needs. A sandbox-scoped
credential is refused before any resource in that manifest is written.

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

Launch requests inherit the stricter host and account execution ceilings. Omitted, null or
empty `execution_limits` do not remove it. Wider requests return
`422 execution_limits_widen`; malformed requests or configured policy return
`422 execution_limits_invalid`. Nonempty effective limits return
`422 execution_limits_unsupported`; Fountain cannot yet enforce these controls.
These preflight checks cover fresh launches, sandbox attachments and channel
resumes before worker start or channel changes. This is not an atomic reservation
against later policy changes. Keep host and account ceilings empty until later-turn and
recovery checks and runtime enforcement are integrated. Fresh launches and
attachments save their initial allowance with the conversation before worker
startup or prompt delivery. Fresh launches also reserve the sandbox in that
transaction; a failed insert leaves no sandbox or conversation.

A turn that a limit ended carries `limit_reason`. Read it before you read
`exit_code`. A runtime that answers after its deadline can exit zero. A client
that reads only `exit_code` then shows a stopped turn as a success. The
transcript event for that turn puts the same value in `stop_reason`.

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

This starts real work and can consume credits and provider usage.
[Conversation states](reference/conversation-states.md) explains lifecycle
transitions. The Conversations operations in the
[generated reference](/api/docs) define prompt admission, permission answers,
interruption, termination, history, images, and event streams.

Use history for a durable transcript and SSE for live delivery. Persist the
event cursor so a reconnect can resume after the last event processed.
Request structured blocks to render ACP output. Historical vendor stdout
formats are no longer parsed; those events remain available as raw data.

### Find the turn your prompt opened

`POST /api/conversations/{id}/prompts` answers before the turn exists. A
conversation with no machine must wake first, and the turn opens after that.
So the response cannot give you a turn ID. Give Fountain your own name for the
prompt instead.

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
It then drops the prompt that arrives second, and the stream does not say so.

The value is a string of 1 to 200 characters. It cannot contain a null
character; Fountain answers `422` for one that does. Send it in the request
body: Fountain does not read this field from the query string. Make the value
unique in the conversation. Fountain does not check that. **It is not an
idempotency key.**
A second prompt with the same value opens a second turn, and the two turns
carry the same value. Do not send a prompt again only because a response was
lost. Read the turns first.

`POST /api/conversations` takes the same field for its first prompt. The value
goes to turn 1 of a new conversation, and to the first turn of a conversation
that you attach to a sandbox with `sandbox_id`. A start that waits in the queue
keeps the value until it starts. Fountain ignores the value when the request
has no `prompt`. Fountain also ignores it when `channel_id` resumes a
conversation, because a resume does not deliver the prompt. Send the prompt to
the resumed conversation on the prompts route, with the value.

An accepted prompt does not always open a turn. Fountain can refuse it after
the response: the machine is at capacity, a limit on the conversation stops
it, or another prompt opened the turn first. The stream reports some of these
refusals and not others. So do not wait without a limit for a `started` event
that carries your value. Set a time limit. Then read the turns.

A turn that carries your value shows that the prompt ran. No turn with your
value shows nothing. The prompt can still be waiting for the machine that must
start first, and the rollout below can open its turn without the value. In that
outcome you do not know whether the prompt ran. If you send it again, the work
can run two times.

A deployment that updates to the release with this field runs two releases
for some minutes. In that time, Fountain can deliver a prompt without its
value. The turn then has a null `client_request_id`.

A turn that Fountain opened by itself has the `autonomous` origin and a null
`client_request_id`. A webhook delivery carries `turn_id` and does not carry
this value. Read the turn to get it.

Each SDK sends the value for you. The TypeScript, Python, Elixir and Swift
clients take it on a run and on a follow-up prompt:
`run(prompt, { clientRequestId })` and `send(prompt, { clientRequestId })` in
TypeScript, `client_request_id=` in Python and Elixir, `clientRequestID:` in
Swift. A client that resumes a conversation with `channel_id` sends the value
again on the prompts route, because that request opens the turn. A client that
gets no value sends no field.

### Wait for capacity

A start can reach the tenant sandbox cap or the fleet ceiling. Fountain then
answers `429` or `503`. Set `queue: true` to wait instead. Fountain answers
`202` with a sandbox request and its one-based `position`. The request becomes
a conversation when capacity is free.

`GET /api/sandbox-queue` lists your requests in position order.
`GET /api/sandbox-queue/{id}` reports the status of one request. It carries
`conversation_id` after the start. `DELETE /api/sandbox-queue/{id}` cancels a
request that still has the `queued` status.

Each tenant holds ten requests at once. A request waits one hour at most. A
full queue keeps the immediate `429` or `503` answer. A start with images does
not wait. A start with an explicit `sandbox_id` does not wait. A queued start
must pass the credit gate and the inference gate again.

A teammate schedule uses the queue without the flag. No person is present
when its cron fires, so Fountain must not lose the run.

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
an empty key, returns 400 `invalid_label_filter`. The same parameter works on
`GET /api/team/{agent_id}/conversations`.

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

A team message to `POST /api/team/{agent_id}/messages` also takes `labels`.
Fountain merges them into the conversation that receives the message, before
it queues the turn. A create call to `POST /api/conversations` with a
`channel_id` that resumes a conversation merges them into that conversation.

The account's own API key can label any of its conversations. A sandbox
callback token can label only the conversation it was minted for. Another
conversation returns 403 `sprite_may_not_label_another_conversation`. This
applies to all three doors that write labels, which are the labels route, a
team message, and a `channel_id` resume.

`conversation.*` webhook payloads carry `labels` under `data`. See
[Webhooks](reference/webhooks.md).

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

### Reapply the configuration

`POST /api/conversations/{id}/reapply` selects a different Agent, Environment
or Vault for a conversation that exists. The machine stays, so the files on
its disk stay with it. Fountain rewrites the variables, the system prompt, the
skills and the MCP configuration. The next prompt starts a runtime that reads
them.

An empty body reapplies the current selection. A field that the body does not
name keeps its selection. A field with a `null` value clears the Environment
override or the Vault.

Reapply retains the bound credential's identity and revision. Compatible
configuration and binding changes commit together, without changing earlier
turn snapshots. A target that would change the credential returns
`409 inference_source_changed` before changing the configuration or machine
identity. See [credential sets](concepts/secrets.md#credential-sets).

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"YOUR_AGENT_ID","vault_id":null}' \
  "$FOUNTAIN_URL/api/conversations/$CONVERSATION_ID/reapply"
```

The machine also takes the new identity. A later attachment must name the new
Agent, Environment and Vault. A target identity that already has a persistent
home fails the request and moves neither binding.

A conversation that sleeps applies the change on its next wake. A
configuration revision stops a prompt against a configuration that a live
worker did not read yet. The `configuration` stage event reports which of the
two happened. The status is `done` when a machine holds the new selection, and
`failed` when the selection stands and the machine has yet to read it. The
request succeeds in both cases. Fountain removes the managed skills that the Agent no
longer names, and keeps the other files in the skills directory. On an older
machine with no skill manifest, Fountain recovers the names from the recorded
Agent version and from the installer's source lock. An entry with no ownership
record stays where it is.

Some selections need a new disk. Fountain refuses those with
`409 rebuild_required` and a `field` that names the cause. Fountain answers
`environment` when you edit one Environment in place or the machine has no
recorded build fingerprint. The error message distinguishes absent build
evidence. Fountain cannot reconstruct original inputs from the current mutable
Environment. The machine records one digest of its build inputs, not a digest
for each field. A different runtime
needs one, because Fountain installs the agent adapter before the network
policy, and that policy now blocks a second install. A different set of
packages, repositories, setup script or network policy needs one too. A
machine that other conversations share accepts only the selection that those
conversations have, because the skills and the instructions belong to the
machine. For the rest, start a new conversation. You can also build this
conversation's machine again with `DELETE /api/sandboxes/{id}`.

Fountain refuses the request with `409 conversation_busy` while a turn runs,
with `503` while it still builds the machine, and with `410` after the
conversation ends.

### Workers without Fountain API access

Set `sandbox_api_access` to `none` when the host must retain Fountain API
authority. Fountain omits its sandbox callback credential before provision
and on every wake or reattachment. The default, `owner`, retains existing
behavior.

This setting is immutable. `none` requires a fresh ephemeral sandbox. It
cannot attach to an existing machine or share its machine with another
conversation. A channel resume with a different explicit setting fails.

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

A sandbox is the machine that hosts a conversation. Several conversations
can share it. Keep the distinction between a transcript and its machine
when you present reset or termination controls.

See [Sandboxes](concepts/sandboxes.md) and
[Sandbox lifetime](guides/operate/sandbox-lifetime.md). The Sandboxes operations
in the [generated reference](/api/docs) describe attachment identity, reset
conditions, and refusal during a turn.

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

## Team

A teammate is an agent with a stable conversation. Follow
[Teammates](concepts/teammates.md) for the model and
[Build a team chat](build/team-chat.md) for the app workflow.

The Team operations in the [generated reference](/api/docs) describe roster,
messages, and access.

### Schedules

A schedule runs work without a person at the keyboard. Choose the intended
timezone and verify the next execution before you enable unattended work.
See [Teammates](concepts/teammates.md) for how schedules relate to a teammate.
The [generated reference](/api/docs) defines timing fields and run history.

A browser client on another origin needs a registered OAuth client or an
`API_CORS_ORIGINS` entry. Read [configuration](configuration.md). A bearer
key is the one credential that crosses an origin.

## Support

Use the console's support action to report a problem or request access to a
feature. Include the conversation ID and the time of the failure. Review any
attached transcript for sensitive content before you submit it.

Support is an optional extension. Its operations appear in the
[generated reference](/api/docs) only when the instance installs it.

## Admin

Administrative workflows require an operator account and an appropriate key.
Use tenant-scoped resource reads for ordinary application work. An operator's
metadata access does not grant access to another tenant's prompt or output.

See Admin in the [generated reference](/api/docs) for account controls,
credit grants, sandbox maintenance, and privilege-trail events.

## Webhooks

Use webhooks when another server must react to Fountain events. Verify the
signature before you process an event. Make the delivery handler idempotent.
Follow [Webhooks](reference/webhooks.md) for delivery and retry behavior.
The [generated reference](/api/docs) describes endpoint registration and replay.

## Audit

Use the audit trail to investigate who changed a resource and when.
A transcript describes agent work; the audit trail describes account and
resource actions. The [generated reference](/api/docs) defines filters,
pagination, and returned metadata.

## Error responses

Every JSON error status declares one schema, `Error`. Its `error` field is
the machine-readable code to branch on. The other fields accompany particular
codes and are absent otherwise: `message` is a sentence for a human, `errors`
holds field validation messages beside `validation_failed`, `upgrade_url`
comes with `insufficient_credits`, and `active_sandboxes` and `limit` come
with `sandbox_quota_exceeded`. On the key-authentication and scope refusals
`error` is a sentence and `reason` carries the code. A 406 is the one
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
