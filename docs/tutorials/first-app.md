# Your first app on the SDK

At the end of this page you have a chat in your terminal. You type a line, and
an agent answers it word by word. Every line after the first goes to the same
conversation, on the same machine, so the agent still has what it made and
what you said. The whole app is about forty lines of TypeScript on
`@managoat/fountain-sdk`.

The [quickstart](../quickstart.md) sent one request with curl. This page sends
it from code, and then keeps the conversation going, which is the part one
request cannot show. The [guided tour](../tour.md) is the bigger build, with a
repository, a token and a pull request. This page needs none of them.

Each output below came from a real run, with the address and the email
changed. The agent's words in yours will differ.

## What you must have

- An account on a Fountain instance, and the instance's address.
- An API key. Create one under **Account**, in the **API keys** section, and
  copy it there: the console shows it once.
- An inference key under Account, then Inference keys. The `starter` agent
  that your account came with runs on it.
- Node.js 22.18 or newer. It runs a TypeScript file as it is, so there is no
  build step. `node --version` tells you which one you have.

## 1. Make a project

```bash
mkdir fountain-chat && cd fountain-chat
npm init -y
npm pkg set type=module
npm install @managoat/fountain-sdk@^10.0.0
```

`type=module` lets the file use `import` and a top-level `await`.

Tell the SDK where your instance is, and who you are.

```sh
export FOUNTAIN_BASE_URL="https://fountain.example.com"
export FOUNTAIN_API_KEY="the key you just created"
```

`new Fountain()` reads both of these, exactly as the CLI does. If you ran
`fountain auth login` already, it reads that saved login instead, and you can
skip the two exports.

## 2. Check the key

Create `chat.ts`.

```ts
import { Fountain } from "@managoat/fountain-sdk";

const fountain = new Fountain();

const me = await fountain.me();
console.log(`Signed in to ${fountain.config.baseUrl} as ${me.email}.`);
```

Run it.

```bash
node chat.ts
```

```text
Signed in to https://fountain.example.com as you@example.com.
```

`me()` asks the server whose key this is. It is the cheapest call there is, so
it is a good first one. An `AuthError` here means the key is wrong. A
`ConnectionError` means the address is.

## 3. Ask, and watch the reply arrive

Add this to the end of `chat.ts`.

```ts
const run = fountain.run(
  "Write three names for a pet tortoise into names.txt, one per line. Then tell me which one you like best.",
  { agent: "starter" },
);

for await (const chunk of run.textStream) process.stdout.write(chunk);

const first = await run;
console.log(`\n(${first.state}, conversation ${first.conversationId})`);
```

Run it again. The first reply takes longer than the rest, because Fountain
starts a sandbox for it.

````text
Signed in to https://fountain.example.com as you@example.com.
Done — written to `names.txt`:

```
Shelldon
Torticia
Mango
```

My favorite is **Shelldon** — a tortoise pun never gets old.
(done, conversation 84edf0e5-2c92-4c62-a0c7-a9c561cf387c)
````

`fountain.run()` starts the work at once and hands back a `Run`. The loop over
`run.textStream` prints the agent's words as they arrive. `await run` waits for
the end of the turn, and gives you its result.

That result says how the turn ended in `state`: `done`, `failed`,
`interrupted` or `timeout`. A turn that fails is a result to read, and not an
exception. The result also holds the `conversationId`, which is the handle on
everything that comes next.

Fountain did more than call a model. It started a sandbox for this
conversation, with a filesystem and a shell, and ran the agent in it. The
agent wrote `names.txt` on that machine.

## 4. Send a follow-up

Add this to the end of `chat.ts`.

```ts
const second = fountain
  .resume(first.conversationId)
  .send("Read names.txt back to me, then add a fourth name to it.");

for await (const chunk of second.textStream) process.stdout.write(chunk);
console.log(`\n(${(await second).state})`);
```

Run it once more. This run opens a new conversation for its first prompt, and
then sends the follow-up to that conversation.

```text
Signed in to https://fountain.example.com as you@example.com.
Written to `names.txt`. My favorite is **Shelldon** — the pun's too good to pass up for a tortoise.
(done, conversation a4c8c63d-101a-48ee-8f54-f122faf416b3)
Current contents:
1. Shelldon
2. Torta
3. Zuma

Adding a fourth now.

Added **Franklin** as the fourth name.
(done)
```

The file is still there, and so is the agent's memory of the first turn. You
explained nothing again. `resume(id).send()` sends the next turn to the same
conversation: the same machine, the same files, and the same agent session.
The follow-up costs one prompt. The [guided tour](../tour.md#5-the-follow-up-which-is-the-point)
shows what that is worth on a real repository.

## 5. Make it a chat

Two hard-coded prompts are a script. A chat reads its prompts from you. Replace
the whole of `chat.ts` with this.

```ts title="chat.ts"
--8<-- "sdk/typescript/examples/chat.ts"
```

Three things changed.

- **The prompts come from the terminal.** Node's `readline` reads one line at a
  time, and `/quit` or Ctrl-D ends the loop.
- **The first line opens the conversation, and every other line follows it
  up.** The program keeps `conversationId` from the first result, and sends
  each later line with `resume(conversationId).send()`.
- **`show()` does the printing** for both kinds of turn. It says how a turn
  ended only when the turn did not finish.

Run it, and talk to the agent.

````text
Signed in to https://fountain.example.com as you@example.com. Type /quit to leave.

you> Make a file called chores.txt with three small chores for a Saturday morning.
agent> Created `/home/sprite/chores.txt` with three Saturday morning chores: trash/recycling, dishes, and watering the plants.

you> Which one takes longest? Move it to the end of the file, and show me the file.
agent> Of the three, washing/putting away dishes typically takes longest, so I moved it to the end:

```
1. Take out the trash and recycling
2. Water the plants
3. Wash and put away the dishes
```

you> /quit
````

## 6. Clean up

`/quit` runs the `finally` block, which calls `terminate()`. That takes the
sandbox down, and nothing can resume the conversation after it. Its history
stays on the server.

If the program stops some other way, the sandbox is not lost. A sandbox that
nobody talks to parks itself, and costs little while it is parked.
[Sandbox lifetime and cost](../guides/operate/sandbox-lifetime.md) has the
timings. Send it another prompt, and it wakes with its files where they were.

## What you built

| Call | What it does |
|---|---|
| `new Fountain()` | Reads your instance's address and your key, as the CLI does. |
| `fountain.me()` | Checks the key. |
| `fountain.run(prompt, { agent })` | Opens a conversation, starts its sandbox, and starts the first turn. |
| `run.textStream` | The agent's words, as they arrive. |
| `await run` | How the turn ended, what the agent said, and the `conversationId`. |
| `fountain.resume(id).send(prompt)` | The next turn, on the same sandbox. |
| `fountain.resume(id).terminate()` | Takes the sandbox down. |

The agent was the `starter` one, with no repository and no secrets. Everything
above works the same for an agent of your own, with its own machine and its
own credentials.

## Where to go next

- [**The guided tour**](../tour.md) builds an agent of your own, with a
  repository, a GitHub token and a system prompt. It opens a real pull request,
  then revises it on a follow-up.
- [**Use the TypeScript SDK**](../sdk.md) covers the rest of the client: every
  event a turn emits, an agent that asks before a tool runs, the error classes,
  and a client in a browser.
- [**A conversation that lasts**](../sdk.md#a-conversation-that-lasts) lets
  Fountain keep the mapping from your own thread to a conversation, with a
  `channelId`, rather than your program holding the id.
- [**The shape everyone clones**](../build/index.md) is the chat app this
  page is the start of, as a static web app with a roster of agents.
- [**The four primitives**](../primitives.md) explains the agent, the
  conversation, and the two pieces this page did not need, the environment
  and the vault.
