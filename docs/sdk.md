# TypeScript SDK

The REST API describes machinery. Conversations, turns, log events, blocks.
The SDK describes the job.

```ts
import { Fountain } from "@managoat/fountain-sdk";

const fountain = new Fountain();

const run = await fountain.run("Upgrade us to Phoenix 1.8 and open a PR", {
  agent: "reposage",
  vault: "github-bot",   // the token lands in the sandbox, never in the prompt
});

console.log(run.text);   // what the agent said
console.log(run.url);    // where a human can watch it happen
```

The source lives in
[`sdk/typescript/`](https://github.com/managoat/fountain/tree/main/sdk/typescript).
It has no runtime dependency, and it needs Node 20.19 or newer.

```bash
npm install @managoat/fountain-sdk
```

## What the second argument is for

The first argument is a prompt, and each LLM SDK has one. The second argument
is the part that is Fountain.

| | what it does |
|---|---|
| `agent` | Which named agent config to run. That is its runtime, model, skills and MCP servers. |
| `environment` | Which baseline to provision the sandbox from. That is the packages, the cloned repos and the setup script. |
| `vault` | Which secrets to attach at spawn. They win over the environment's on a key collision. |

Fountain decrypts a vault's values into the sandbox's environment when the
sandbox spawns. They are not in the prompt, not in the model's context, and
not in the log feed the SDK reads.

Change `vault: "github-bot"` to `vault: "github-readonly"`, and you change
what the agent can do. You change not one word of the task.

There is a second layer under that, and it changes what you can safely let an
agent do.

Fountain redacts each value of 8 bytes or more that it placed in the sandbox's
environment out of the conversation's output. It does that on the one write
path that each log event takes.

An `env`, a `set -x`, a `cat .env`, and an agent that you ask outright to
print its token all persist as `[REDACTED]`. The secret reaches the process
that needs it. It reaches neither the transcript, nor the database, nor this
SDK.

Read [the four primitives](primitives.md) for what each one is.

## Credentials

`new Fountain()` resolves exactly as the [CLI](cli.md) does. So a script
inherits whatever already works in your terminal.

```
apiKey:  option → FOUNTAIN_API_KEY → FOUNTAIN_TOKEN → ~/.fountain/credentials
baseUrl: option → FOUNTAIN_BASE_URL → ~/.fountain/credentials → hosted
```

`FOUNTAIN_TOKEN` is the token that a Fountain sandbox exports for the agent
inside it, scoped to that one conversation.

So an agent that imports this SDK delegates with the credential it already
holds. Fountain records the conversations it opens as its children. Fan-out
therefore needs no more configuration.

## Awaiting, streaming, or neither

`run()` starts the work and returns a handle. No second request hides behind
any of these. They are three views of one run.

```ts
// the finished answer
const result = await fountain.run(prompt, { agent: "reposage" });

// the words, as they arrive
const run = fountain.run(prompt, { agent: "reposage" });
for await (const chunk of run.textStream) process.stdout.write(chunk);

// everything: lifecycle, tools, thinking, raw events
for await (const event of run) {
  if (event.type === "tool") console.log("→", event.name);
}

// fan out: nothing is awaited, so every sandbox provisions at once
const results = await Promise.all(agents.map((agent) => fountain.run(prompt, { agent })));
```

A turn that **fails** is a result, and not an exception. So check
`result.state`, which is `done`, `failed`, `interrupted` or `timeout`. Only a
transport failure, a request the server rejected, or a timeout throws.

## When the agent asks first

An agent can hold a tool call and wait for a person. Give its
`permission_policy` an `ask` entry, and the agent stops before that tool. The
turn does not continue until an answer comes back.

```ts
for await (const event of run) {
  if (event.type !== "permission") continue;

  console.log(event.request.summary);
  const allow = event.request.options.find((o) => o.kind === "allow_once");
  await run.answer(event.request.requestId, allow.optionId);
}
```

The `options` list holds the choices of the agent, in the order of the agent.
Branch on `kind`, which is `allow_once`, `allow_always`, `reject_once` or
`reject_always`. An `optionId` that the agent did not offer causes a
`ValidationError`. To answer from a different process, use
`fountain.resume(id).answer(...)`.

A request that gets no answer expires, and the server then denies it. The turn
continues, but the agent did not do that step. Answer each request, or give the
agent the default `auto_allow` policy.

## A whole definition, in code

`run()` names an agent. Here is where that agent comes from. The point of the
whole definition is that the vocabulary fits on one screen.

```ts
const environment = await fountain.environments.create({
  name: "fountain-ci",
  packages: { apt: ["ripgrep"] },
  env_vars: { MIX_ENV: "test" },
  repositories: [
    { url: "https://github.com/managoat/fountain", mount_path: "/work/fountain" },
  ],
  setup_script: "cd /work/fountain && mix deps.get",
  networking_type: "limited",
  networking_config: { allowed_hosts: ["github.com", "hex.pm", "api.anthropic.com"] },
});

const vault = await fountain.vaults.create({ name: "github-bot" });
await fountain.vaults.secrets.set("github-bot", "GITHUB_TOKEN", process.env.GITHUB_TOKEN!);

const agent = await fountain.agents.create({
  name: "reposage",
  runtime: "claude",
  model: "anthropic/claude-sonnet-5",
  description: "Reads a repository and answers questions about it",
  system: "You are a careful reader of other people's code.",
  environment_id: environment.id,
  skills: [
    { source: "obra/superpowers", ref: "v2.1.0" },
    { name: "house-style", content: "# House style\n\nPrefer small diffs." },
  ],
  mcp_servers: { linear: { command: "npx", args: ["-y", "linear-mcp"] } },
  allowed_vault_ids: [vault.id],
});

// ...and now the one-liner at the top of this page has something to run.
await fountain.run("Find every N+1 query and open a PR", {
  agent: "reposage",
  vault: "github-bot",
});
```

That is an [environment](primitives.md), a [vault](primitives.md) and an
[agent](primitives.md). Those are three of the four primitives. The
conversation is the fourth.

Here are the fields that need a word.

| Field | What it decides |
|---|---|
| `runtime` | `claude`, `codex`, `gemini`, `opencode` or `acp`. The provider in `model` must match it, and `acp` needs no model at all. |
| `runtime_command` | The command that the `acp` runtime launches. It is a shell line, and Fountain resolves it inside the sandbox. The field is required for `acp`, and a 422 on each other runtime. |
| `model` | The canonical `provider/model_id`. Fountain checks it against no list, so a model that ships today works today. Leave it out on `acp`. |
| `system` | The agent's system prompt. |
| `skills` | Either `{ source, ref? }`, which installs from GitHub, or `{ name, content }`, which Fountain writes into the sandbox word for word. Each entry takes exactly one shape. |
| `sandbox_provider` | `sprites`, `e2b`, `daytona` or `runner`. A `null` takes the instance default. |
| `sandbox_mode` | `ephemeral` (default) or `persistent`. Persistent gives the agent one machine of its own, and each conversation lands on it. |
| `allowed_vault_ids` | Which vaults a conversation can attach. A `null` permits each one, `[]` permits none, and a list is an allowlist. A vault value overrides the environment, so this is what scopes who can override a config that somebody reviewed. |
| `allowed_environment_ids` | The same shape. It covers a launch of the agent under a different environment. |
| `inference_credential_id` | The agent's credential set ID. `null` selects the account default. |
| `allowed_inference_credential_ids` | Which sets a launch may request. `null` permits any tenant-owned set, `[]` forbids a different set, and a list permits those IDs. The agent's own set remains allowed. |

A launch can supply `inference_credential_id` in the conversation create
request. Set IDs belong to the authenticated account; an allowlist does not
grant access to another tenant's set. An omitted selection uses the agent's
set, then the account default. Existing conversations retain their resolved
source on wake and resume. See [credential sets](concepts/secrets.md#credential-sets)
for source replacement and shared Codex workspace constraints.

Each collection reads the same way.

```ts
await fountain.agents.list();                                  // or .list("search")
await fountain.agents.get("reposage");                         // by name or id
await fountain.agents.update("reposage", { model: "anthropic/claude-opus-5" });
await fountain.agents.delete("reposage");
```

`environments` and `vaults` have the same five verbs, and `secrets` as well.

```ts
await fountain.environments.secrets.set("fountain-ci", "HEX_API_KEY", "…");
await fountain.vaults.secrets.setAll("github-bot", { GITHUB_TOKEN: "…", GITHUB_USER: "bot" });
await fountain.vaults.secrets.list("github-bot");    // keys only, never values
await fountain.vaults.secrets.delete("github-bot", "GITHUB_USER");
```

A secret value is write-only. `list` returns the keys and nothing else. The
SDK can put a credential into a sandbox, and it cannot read one back out.

!!! note "Why `environment_id` and not `environmentId`"

    A resource payload uses the API's own key names. So one definition reads
    the same way in the SDK, in the [REST API](api.md) and in a
    `fountain.yml` manifest, and this page doubles as the API reference.

    An option that controls the SDK's own behaviour is camelCase. `timeoutMs`
    and `signal` are the two, and neither one is data.

## The team

Ten of the eleven applications on Fountain talk to `/api/team`, and some of
them never touch `/api/conversations` at all.

The reason is that a teammate *lasts*. It is one agent, one sandbox that stays
up, and one thread that you send to again and again. A conversation is
something you open and close.

```ts
await fountain.team.add("watchtower", { name: "Watchtower" });

const reply = await fountain.team.message("watchtower", "Any disks over 80%?");
console.log(reply.text);
```

`message()` returns the same `Run` handle that `run()` does. Await it, iterate
it, or ignore it and let the stream below carry the answer to your UI.

[**Build a chat app**](build/index.md) writes a whole chat client on these
verbs. It covers the roster, threads, connectors, routines, and the job each
piece does.

```ts
await fountain.team.list();                       // the roster, with unread counts
await fountain.team.rename("watchtower", "Eyes"); // null restores the agent's name
await fountain.team.history("watchtower");        // every thread it has had
await fountain.team.freshConversation("watchtower"); // new computer, old one retired
await fountain.team.remove("watchtower");         // off the team; the agent stays
```

A routine is cron for a teammate.

```ts
await fountain.team.schedules.create("watchtower", {
  cron: "0 9 * * *",
  prompt: "Check disk usage and say only what changed.",
});
```

### One stream for everyone

```ts
for await (const event of fountain.team.stream({ streams: ["stage"] })) {
  if (event.stage === "turn" && event.state === "done") refreshRoster();
}
```

The stream reconnects from its last event id on its own. So the caller sees
neither a deploy nor an idle timeout.

!!! note "The team stream carries blocks"

    `/api/team/stream` takes `blocks` and `streams`. The SDK sends `blocks` for
    you, so an event on it arrives parsed, not in the runtime's own dialect.
    The stream covers many conversations, so the server picks the runtime per
    event from the conversation that produced it.

    You can therefore render a thread from this one connection.
    `fountain.events()` is the same idea across each conversation you own.

## Reading a thread

Two calls cover what each application does when somebody opens a thread.

```ts
const conversation = fountain.resume(conversationId);

const events = await conversation.history({ streams: ["acp", "stage"] });  // paged until drained
await conversation.markRead();                                            // clears the unread badge
```

`history()` pages the log feed to the end for you. Each of the eleven apps
wrote that loop by hand first.

## Follow-ups

```ts
const first = await fountain.run("Find every N+1 query in this repo", { agent: "reposage" });
const second = await fountain.resume(first.conversationId).send("Fix the worst three.");
```

The second turn costs one prompt. The sandbox is the same machine. The
checkout is where the first turn left it, and the agent's session still holds
what it learned. A [suspended](reference/conversation-states.md) sandbox wakes
for it.

## Labels

A conversation carries `key=value` strings. A run stamps them with what it
found, and a list slices on them.

```ts
await fountain.resume(id).setLabels({ env: "prod", drift: "true" });
await fountain.resume(id).setLabels({ drift: null });   // null removes a key

await fountain.conversations({ labels: { env: "prod", drift: "true" } });
```

`setLabels` merges, so a key you do not name stays as it is. The filter
combines the pairs with AND. A conversation holds at most 32 labels, a key is
at most 64 bytes and a value is at most 256 bytes. The
[API reference](api.md#labels) has the limits, the sandbox rule and the ACP
extension an agent stamps its own run with.

## Sandboxes

A sandbox is the machine a conversation runs on, and several conversations
can share one. Two options on `run()` control that. The `sandbox` option
names a sandbox you already have, by id, and the new conversation lands on
it. The `sandboxMode` option is `"ephemeral"` or `"persistent"`, and it
replaces the agent's default.

```ts
const first = await fountain.run("Clone the repo and run the tests", { agent: "reposage" });
const { sandbox_id } = await fountain.resume(first.conversationId).get();
await fountain.run("Now fix the failures", { agent: "reposage", sandbox: sandbox_id! });

await fountain.sandboxes({ status: ["ready", "suspended"] });  // the list, with the conversations on each
await fountain.sandbox(id);
await fountain.resetSandbox(id);   // destroy a persistent machine; the conversations stay
```

`resetSandbox()` refuses an ephemeral sandbox, and one with a turn in flight.
The [API reference](api.md#sandboxes) has the rules.

## Timeouts

`run()` waits as long as the turn takes, and agent work fairly runs for hours.
`timeoutMs` stops the *wait*, and never the agent.

```ts
try {
  await fountain.run(prompt, { agent: "reposage", timeoutMs: 5 * 60_000 });
} catch (error) {
  if (error instanceof TimeoutError) {
    console.log(error.partialText);
    await fountain.resume(error.conversationId).send("status?");
  }
}
```

`run.interrupt()` asks the agent to stop the turn, and leaves the sandbox up.
`run.terminate()` takes the sandbox down.

## Errors

Branch on `code`, and not on the status. `conversation_busy` is a 400,
`sandbox_quota_exceeded` is a 429, and `provisioning` is a 503. What you want
to say about each one has nothing to do with those numbers.

```ts
try {
  await fountain.team.message("watchtower", prompt);
} catch (error) {
  if (error instanceof ConversationBusyError) return "Still working on the last one.";
  if (error instanceof QuotaExceededError) return `Sandboxes full (${error.activeSandboxes}/${error.limit}).`;
  if (error instanceof NotReadyError) return `Starting up, retry in ${error.retryAfter}s.`;
  if (error instanceof ValidationError) return Object.entries(error.fieldErrors)[0]?.join(" ");
  throw error;
}
```

| Class | Code / status | Retryable |
|---|---|---|
| `ConversationBusyError` | `conversation_busy` (400) | Yes. The turn in flight must finish. |
| `NotReadyError` | `provisioning`, `sprite_probe_failed`, `fleet_full`, `sandbox_unavailable` (503) | Yes. It carries the server's `Retry-After`. |
| `QuotaExceededError` | `sandbox_quota_exceeded` (429) | Yes. Terminate a conversation first. |
| `InsufficientCreditsError` | `insufficient_credits` (402) | No. It carries `upgradeUrl`. |
| `ValidationError` | 422 | No. Read `fieldErrors`. |
| `AuthError` and `NotFoundError` | 401 and 404 | No. |
| `ConnectionError` | It never reached the server. | In a browser, the cause is usually CORS. |

Each one carries `status`, `code`, `body`, `retryAfter` and a `retryable`
flag. So a generic retry wrapper needs no table of its own.

## In a browser

The SDK's default entry pulls in no Node built-in, so it bundles as it is. The
reader for the credentials file sits behind the `node` export condition.

In a browser you pass what you have.

```ts
const fountain = new Fountain({ baseUrl, apiKey });   // from your own settings UI
```

The server must admit your origin through a registered OAuth client or
`API_CORS_ORIGINS`. Otherwise each call fails before it starts.

`ConnectionError` says exactly that. "Failed to fetch" has sent more than one
person to search their own code for an hour.

## Everything else

The SDK wraps the verbs that are worth a wrapper. The rest of the API is one
call away, with the same auth and the same errors. That rest is audit, API
keys, admin, payment and exports.

```ts
await fountain.request("GET", "/api/audit", { query: { limit: 50 } });
```

Connections have a wrapper. `client.connections` lists, gets and deletes
them. `client.connections.providers` has `list`, `get`, `create`, `update`,
`delete` and `discover`, over `/api/connection-providers`. A `create` with
`kind: "mcp"` and an `mcp_url` runs discovery. Read
[Connections](catalog/connections/index.md).

The [API reference](api.md) covers those, and so does the generated
`GET /api/openapi.json`.

## Generated underneath

Nobody writes the types by hand. `src/generated/openapi.ts` comes from the
OpenAPI document that the server serves at `GET /api/openapi.json`.

CI generates it again and fails on a diff. So a field that somebody adds to a
schema in Elixir reaches the SDK on the next build. A type here can never
describe an API that has gone.

```ts
import type { components, paths } from "@managoat/fountain-sdk";

type Teammate = components["schemas"]["Teammate"];
```

What people write by hand is the part a spec cannot express. That many log
events fold into one *turn*. That you can await a run or stream it. Which of
85 paths are worth a verb.

## How CI publishes it

CI publishes every version. No person publishes from a workstation. npm accepts
a release only from the `Publish SDK` workflow in this repository. Each tarball
therefore carries a provenance attestation. To examine it, install the package
and then run this command:

```bash
npm audit signatures
```

A verified attestation identifies the workflow and the commit that made the
tarball. A package that a person sends by hand has no such attestation.

## Other languages

Elixir, Python and Swift have their own SDKs. Read the
[Elixir](elixir-sdk.md), [Python](python-sdk.md) and [Swift](swift-sdk.md)
references for their full APIs. For a different language, use one of two
worked references below. They show how to follow a turn through the log feed.

- **Python.** The SDK follows SSE. The
  [Hermes plugin](integrations/hermes.md)'s `tools.py` is a smaller reference
  that polls `/events?blocks=true`.
- **Go.** The [`fountain` CLI](cli.md)'s `fountain run`, which streams SSE.

These references implement the rules that the TypeScript SDK implements. Keep
your own turn's events, and no other. Keep the `text` blocks, and no other
kind. Join ACP chunks with nothing between them.
Start a new paragraph after a tool call. Resume from the last event id when a
connection drops mid-turn.

## Credit error migration

The credit error names start at TypeScript 2.0.0, Python 0.3.0, Elixir 0.3.0
and Swift 0.17.0. The first three SDKs have independent version lines; Swift
releases with the server. Replace subscription-era checks with the names below.

| Client | Removed name | Credit error | Purchase URL |
|---|---|---|---|
| TypeScript | `SubscriptionRequiredError` | `InsufficientCreditsError` | `error.upgradeUrl` |
| Python | `SubscriptionRequiredError` | `InsufficientCreditsError` | `error.upgrade_url` |
| Elixir | `:subscription_required` | `:insufficient_credits` | `Fountain.Error.upgrade_url(error)` |
| Swift `Fountain` | `.subscriptionRequired` | `.insufficientCredits` | `error.upgradeURL` |
| Swift `FountainKit` | No case rename | `.insufficientCredits(body, upgradeURL:)` | Associated `upgradeURL` value |

For billing error handling, use Fountain v0.13.0 or newer.
[v0.13.0](https://github.com/managoat/fountain/releases/tag/v0.13.0) is the first
release containing the credit-only server contract (`c3349343`).
`insufficient_credits` and a generic HTTP 402 identify the credit gate.
`subscription_required` has no special mapping; it follows the HTTP status.
The response still exposes its original code and purchase URL.

Swift v0.17.0 includes these source API changes. Earlier tags keep their
original error names.
