# A team chat, end to end

Everything below is the [TypeScript SDK](../sdk.md) against a live instance,
in the order you would write it. It follows the sequence that
[fountain-team](https://github.com/managoat/demos/tree/main/apps/fountain-team) uses.

That app is older than the SDK, and it calls `fetch` directly. Its
hand-written API client is roughly what the SDK now wraps.

Nothing here needs a server of your own. The whole app is static files and a
bearer token.

## 1. A client

```ts
import { Fountain } from "@managoat/fountain-sdk";

const fountain = new Fountain({
  baseUrl: "https://fountain.example.com",   // your instance
  apiKey,                                     // pasted once, or an OAuth token
});

const me = await fountain.me();               // the cheapest check that a key works
```

In Node the arguments are optional. The credentials resolve from the
environment and from `~/.fountain/credentials`, exactly as the
[CLI](../cli.md)'s do.

In a browser you pass what the person gave you. Register the app's OAuth
client so the server admits its origin. Read
[how to ship it](#10-how-to-ship-it).

## 2. Hire a teammate

The **+** in these apps asks nothing. A name from a list, a sensible brain, a
one-line brief, and a second later the roster has a new row.

Two calls do it. One defines an [agent](../concepts/agent.md). One puts that
agent on the team.

```ts
const catalog = await fountain.catalog();          // this deployment's vocabulary
const model = catalog.models.claude?.[0] ?? "anthropic/claude-sonnet-5";

const agent = await fountain.agents.create({
  name: "watchtower",
  runtime: "claude",
  model,
  description: "Keeps an eye on the fleet",
  system: "You are Watchtower. You watch things and report only what changed.",
});

const teammate = await fountain.team.add(agent.name, { name: "Watchtower" });

teammate.conversation.id;      // the thread
teammate.presence.state;       // "starting", a computer is being provisioned
```

`catalog()` is what keeps the model dropdown fresh. The runtimes, the
suggested `provider/model` ids come from the server.
They do not come from a list in your bundle.

The add is idempotent, so the **+** need not know whether this agent is on the
team already. A machine appears at this point too. `team.add` opens the
teammate's one long conversation, and that provisions its sandbox.

!!! note "The face"

    Upload an avatar from the agent form. Clients can also send base64 image
    bytes and a media type to `PUT /api/agents/:id/avatar`.

    A read of it needs the bearer key, so an `<img src>` pointed straight at
    the URL gets a 401. Fetch the bytes, then hand the element an object URL.

    ```ts
    const response = await fountain.api.raw("GET", `/api/agents/${agent.id}/avatar`);
    element.src = URL.createObjectURL(await response.blob());
    ```

## 3. The roster

```ts
const roster = await fountain.team.list();

for (const teammate of roster) {
  render({
    name: teammate.name,                       // its title, else the agent's name
    status: teammate.presence.label,           // "working", "asleep · wakes on message"…
    line: teammate.preview?.text ?? "",        // the last thing said, either way
    who: teammate.preview?.kind,               // "you" | "them" | "typing"
    bold: teammate.unread,
    tokens: teammate.usage_total,              // summed over every thread it has had
  });
}
```

One call fills a roster row completely. You assemble nothing from three
endpoints and a guess.

Behind the label, `presence.state` is an enum. Its values are `working`,
`starting`, `online`, `asleep`, `away`, `failed` and `offline`.

A teammate reads as `asleep` when Fountain
[parked](../concepts/conversation.md) its machine for want of work. It wakes
on the next message, with its memory intact. Your UI need do no more than say
so.

## 4. Say something

```ts
const run = fountain.team.message("watchtower", "Any disks over 80%?");

for await (const chunk of run.textStream) appendToBubble(chunk);

const result = await run;
if (result.state !== "done") markFailed(result.reason);   // failed, interrupted, timeout
```

`message()` hands back the same `Run` handle that `fountain.run()` does. You
have four choices.

Await it for the finished reply. Iterate `textStream` for the words as they
land. Iterate the run itself for tool calls and thoughts. Or drop it, and let
the team stream in the next section carry the answer to whichever component
shows that thread.

A turn that fails is a result, and not an exception. Check `state`. Only a
transport failure, or a request the server rejected, throws. §7 is about
those.

## 5. One connection for the whole app

A chat app must know what each teammate does, and not the open thread alone.
One endpoint covers that, and you need no socket for each teammate.

```ts
for await (const event of fountain.team.stream({ streams: ["stage"] })) {
  // A `team` or `schedule` notice: the roster or the routines changed.
  if (!event.agent_id) {
    void refreshRoster();
    continue;
  }

  if (event.stage === "turn") {
    if (event.state === "started") setTyping(event.agent_id, true);
    if (event.state === "done") {
      setTyping(event.agent_id, false);
      void reloadThread(event.conversation_id!);
      notifyIfNotLooking(event.agent_id);
    }
  }
}
```

Each payload is a conversation's log event, with `conversation_id` and
`agent_id`. So it routes to a roster row, and you look nothing up.

The iterator reconnects from its own last event id. A Fountain deploy, a proxy
timeout or a closed laptop lid therefore loses no event. Your reconnect logic
is the `for await` you already wrote.

The stages that matter are the ones a UI shows before the first word arrives.
Those are `provision`, `setup` and `reattach`, then `turn`, then
`terminate`. Each one carries a `state` of `started`, `done`, `failed` or
`interrupted`.

!!! note "The team stream carries blocks"

    `/api/team/stream` takes `blocks` as well as `streams`, and the SDK sends
    it for you. An event arrives parsed, so this one connection is enough to
    show *something happened, and to whom* **and** to render the words.

    The next section covers the conversation's own feed, which is what you read
    when somebody opens one thread and you want its history.

## 6. Open a thread

Three calls. The third one stops your app from a shout about the messages that
the person reads right now.

```ts
const conversation = fountain.resume(conversationId);

const [turns, events] = await Promise.all([
  conversation.turns(),                                  // the prompts, in order
  conversation.history({ streams: ["acp", "stdout"] }),   // paged to the end for you
]);

await conversation.markRead();
```

Each turn is a pair of bubbles. The words, and everything the agent did about
them. Group the feed by `turn_id` and you have both.

```ts
import type { Block, LogEvent, Turn } from "@managoat/fountain-sdk";

function bubbles(turns: Turn[], events: LogEvent[]) {
  const byTurn = new Map<string, Block[]>();
  for (const event of events) {
    if (!event.turn_id) continue;
    const blocks = byTurn.get(event.turn_id) ?? [];
    blocks.push(...(event.blocks ?? []));
    byTurn.set(event.turn_id, blocks);
  }

  return turns.flatMap((turn) => [
    { from: "you" as const, text: turn.prompt },
    { from: "them" as const, parts: fold(byTurn.get(turn.id) ?? []) },
  ]);
}
```

A reply is a handful of blocks. Fold them the way a chat bubble wants them.
Prose that sits together joins up, and a run of tool calls collapses into one
line that a person can expand.

```ts
type Part = { kind: "text" | "thinking" | "tools"; body: string; tools: string[] };

function fold(blocks: Block[]): Part[] {
  const out: Part[] = [];
  for (const block of blocks) {
    const last = out.at(-1);
    if (block.kind === "text" || block.kind === "thinking") {
      const body = typeof block.body === "string" ? block.body : "";
      if (last?.kind === block.kind) last.body += body;
      else out.push({ kind: block.kind, body, tools: [] });
    } else if (block.kind === "tool_use") {
      if (last?.kind === "tools") last.tools.push(block.name ?? "a tool");
      else out.push({ kind: "tools", body: "", tools: [block.name ?? "a tool"] });
    }
  }
  return out;
}
```

Those two functions are the whole transcript renderer. They fit on a screen
because of `blocks`.

The log feed stores ACP messages from every supported runtime.
`history()` requests `?blocks=true` to parse ACP events on the server.
The transcript blocks carry text, tool calls, results, and permission requests. Other streams remain raw event data and produce no blocks.
Historical vendor stdout formats are no longer parsed.

Before that existed, fountain-team shipped a 200-line port of Fountain's own
ACP parser. Do not repeat that.

## 7. The things people judge a chat app on

**Busy.** A teammate is one machine that runs one turn. Fountain refuses a
message sent mid-turn, and the right answer is not an error toast.

```ts
import { ConversationBusyError } from "@managoat/fountain-sdk";

try {
  await fountain.team.message("watchtower", text);
} catch (error) {
  if (error instanceof ConversationBusyError) queue.push(text);   // send it at turn-end
  else throw error;
}
```

Queue locally, then flush on the `turn`/`done` event from §5. Several queued
notes then go as one turn. Branch on `error.code`, and not on the status. The
[error table](../sdk.md#errors) has the rest.

**Stop.** An interrupt ends the turn and keeps the machine. A terminate takes
the machine down.

```ts
const conversation = await fountain.team.conversation("watchtower");
await conversation.interrupt();
```

**Images.** Base64 in, on the same call.

```ts
await fountain.team.message("watchtower", "What is wrong with this graph?", {
  images: [{ data: base64, media_type: "image/png" }],
});
```

**Search.** Across each conversation the key can see, both prompts and
replies.

```ts
const hits = await fountain.search("disk usage");
// { conversation_id, agent_id, turn_id, turn_number, kind: "title"|"prompt"|"reply", snippet }
```

`turn_number` is what lets a ⌘K hit open the thread at the right bubble.

**A clean slate.** A long thread one day wants a fresh start.

```ts
await fountain.team.freshConversation("watchtower");  // new conversation, new computer
const past = await fountain.team.history("watchtower"); // the retired threads
```

Fountain retires the old thread, and it stays readable. Its sandbox is
destroyed, and the new conversation gets a fresh one, so the agent starts with
a new context and a clean disk. Anything it needs again, such as a clone, it
sets up again.

## 8. Give a teammate an app to use

The clones call this part connectors. It is where a hosted runtime becomes
more than a convenience. A connector is an MCP server that the teammate's
runtime talks to, and it usually needs a real credential.

The credential does not go in the agent config. It goes in the teammate's
[environment](../concepts/environment.md), as a secret. The server definition
then refers to it by name.

```ts
const environment = await fountain.environments.create({ name: "watchtower-env" });
await fountain.agents.update("watchtower", { environment_id: environment.id });

await fountain.environments.secrets.set(environment.name, "GITHUB_TOKEN", token);

await fountain.agents.update("watchtower", {
  mcp_servers: {
    github: {
      type: "http",
      url: "https://api.githubcopilot.com/mcp/",
      headers: { Authorization: "Bearer ${GITHUB_TOKEN}" },
    },
  },
});
```

[Substitution](../primitives.md#substitution) resolves `${GITHUB_TOKEN}` when
Fountain prepares the machine. Three things follow. Together they are why this
is more than a nicer way to store a string.

- The token never appears in a prompt, a model's context, or the log feed your
  app reads.
- Fountain **redacts each environment value of 8 bytes or more out of the
  conversation's output**. It does that on the one write path that each log
  event takes. Ask an agent to print its token, and `[REDACTED]` is what
  persists.
- A secret value is write-only. `secrets.list()` returns keys. Your app can
  give a teammate a credential, and it can never read one back. That is a
  useful thing to tell somebody who pastes a GitHub token into a web page.

A connector applies the next time Fountain prepares the machine. It does not
reach the machine that runs now.

## 9. Routines

Cron, per teammate, server-side. Nothing in your app has to be awake.

```ts
await fountain.team.schedules.create("watchtower", {
  cron: "0 9 * * 1-5",                       // five fields, UTC
  prompt: "Check disk usage and say only what changed.",
  name: "Morning sweep",
});

const routines = await fountain.team.schedules.list();          // the whole team's
await fountain.team.schedules.run("watchtower", routines[0].id);  // "Run now"
```

By default the prompt lands in the teammate's own thread, as though you typed
it. The reply then sits in the conversation, and in the memory the agent works
from.

`one_off: true` gives each run a fresh conversation on a new machine instead,
and leaves the thread alone. The `schedule` notice on the team stream tells
your UI to list them again.

## 10. How to ship it

Host it as static files. The only server-side facts are on the Fountain
instance.

| What | Why |
|---|---|
| OAuth client registration | Register under Account, then OAuth apps. This enables **Sign in with Fountain** and admits the redirect origins to the API. |
| `API_CORS_ORIGINS` and `OAUTH_CLIENTS` | Operator settings for published first-party apps. A development-mode app does not need them. |

[Sign in with Fountain](../api.md#sign-in-with-fountain-oauth-20-for-browser-apps)
is OAuth 2.0 authorization code with PKCE. The token it returns *is* an API
key. It lists and revokes under Account, then API keys, and a sign-out revokes it.
For an app with no backend, that is the whole authentication story.

## The whole thing, runnable

The roster row, the event router and the transcript folder above are one file
in this repo,
[`sdk/typescript/examples/chat.ts`](https://github.com/managoat/fountain/blob/main/sdk/typescript/examples/chat.ts).

It hires a temporary teammate, prints the roster, sends a message, renders the
thread out of blocks, then cleans up after itself.

```bash
cd sdk/typescript && npm install
FOUNTAIN_API_KEY=ftn_… node examples/chat.ts
```

CI typechecks it against the SDK on each push. That is the only reason this
page can promise that the code on it compiles.
[`examples/team.ts`](https://github.com/managoat/fountain/blob/main/sdk/typescript/examples/team.ts)
is the smaller version. Hire, say two things, watch the stream.

## Where this goes next

- [**What each piece does**](pieces.md) covers what happens between Enter and
  the first word, and which primitive is responsible for what.
- [**TypeScript SDK**](../sdk.md) has the full surface, with everything
  outside the team.
- [**API reference**](../api.md#team) documents the routes underneath, for a
  language the SDK does not cover yet.
