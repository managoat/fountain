# Run your first agent

One request gets a reply from an agent in its own sandbox. You need an
account on a Managoat instance and nothing else. No repository, no GitHub
token, and no install. To run an instance of your own, read
[Self-host Managoat](self-hosting.md).

## 1. Your key and your agent

Create an API key in the console: open **Account**, then the **API keys**
section (`/account?open=api-keys`). The console shows a key once, so copy it
there.

```sh
export MANAGOAT_BASE_URL="https://fountain.example.com"
export MANAGOAT_API_KEY="the key you just created"
```

Use your instance's address as `MANAGOAT_BASE_URL`. A new account has no
agents, so create one. It needs a name, a runtime and a model, and runs in a
plain sandbox.

```sh
curl -sS -X POST "$MANAGOAT_BASE_URL/api/agents" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "first", "runtime": "claude", "model": "anthropic/claude-sonnet-5"}'
```

The response holds the agent's `id`.

```sh
export MANAGOAT_AGENT_ID="the id of the agent you just created"
```

The [CLI](cli.md) can do the rest for you once an
agent exists: `managoat auth login`, then `managoat quickstart`.

!!! note "Whose model key"

    An agent calls a model, so it needs an inference key. Add yours under
    Account, then Inference keys, before the first request. The server holds
    no key of its own ([Inference](configuration.md#inference)).

## 2. Send the request

```sh
--8<-- "apps/fountain/priv/first_request/first-request.sh"
```

Managoat starts a sandbox, starts the agent in it, and answers. The response
holds the conversation `id`.

## 3. Read the reply

Read the conversation stream with the id from step 2.

```sh
curl -N -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  "$MANAGOAT_BASE_URL/api/conversations/CONVERSATION_ID/stream?blocks=true"
```

That reply came from your agent, on a machine that Managoat operates for you.
It is the whole product, in one request.

## The same request from the SDK

```bash
npm install @managoat/sdk@^10.0.0
```

```ts
--8<-- "apps/fountain/priv/first_request/first-request.ts"
```

`new Managoat()` reads `MANAGOAT_API_KEY` and `MANAGOAT_BASE_URL` from the
environment, exactly as the CLI does. The request uses the same agent ID as
the curl example. `runRequest` accepts API fields
directly, with local timeout/event options passed separately. From another
language, call the [HTTP API](api.md) directly.

## Where to go next

The [guided tour](tour.md) is the second page. It builds an agent that clones
your repository, changes it, and opens a pull request.

To build on the SDK first, [your first app](tutorials/first-app.md) turns the
request above into a chat in your terminal: it streams the reply, then sends
follow-ups to the same conversation.

Past the first request, the How-to guides take each next step.

- [Deploy an instance](guides/operate/deploy.md) runs a server of your own
  with Docker Compose.
- [Use the CLI](cli.md#install) installs `managoat` and signs it in to your
  instance.
- [Manage resources as YAML](guides/manifests.md#start-from-the-example)
  applies a small manifest and runs its agent against a real repository.
