# The shape everyone clones

The same app comes round again and again. It is a chat client whose contacts
are bots. The roster is on the left and the thread is on the right. A **+**
makes a new bot out of a name and a one-line brief. A settings panel connects it to
GitHub or Notion. Grok Bot shipped that shape, and the clones are everywhere.

The front end is a weekend of work. The machinery under it is not.

## What a bot needs, and a chat UI does not give it

A useful teammate is a process on a machine. So something must supply the
machine.

| Behind the bubble | What it truly means |
|---|---|
| A machine. | A filesystem, a shell, a package manager, a network. |
| Credentials. | A GitHub token that works, and that sits in neither the prompt nor the transcript. |
| Memory. | The second message costs a sentence, and not a re-explanation of the first. |
| Isolation. | One bot's token and files, on a machine that is not the one that serves your app. |
| A lifecycle. | Something starts that machine, parks it while nobody types, and wakes it. |
| Tenancy. | The second person who signs in does not see the first one's bots. |
| A clock. | "Each weekday at nine." |

## The two usual answers

**Run the agent on the user's own machine.** The app becomes a front end for a
process on your laptop. Your Node, your keys in a dotfile, the directory you
work in.

Nothing is quicker to build, and for one person it works well. The cost shows
up in the README, which starts with `git clone`. Each person who wants a bot
installs the whole stack. The bots stop when the lid closes. To share them with
a team has no answer.

**Take an endpoint.** Bring your own agent, as a URL that speaks
[ACP](../integrations/acp.md), or an OpenAI-compatible chat completion, or a
framework's own protocol.

The app can now run anywhere, and the hard part moved rather than went.
Somebody still hosts that runtime, and gives it a filesystem. Somebody puts
credentials in it, keeps its memory between calls, and stops one tenant from
a read of another's. A chat-completions endpoint is stateless and has no shell. An ACP
endpoint has one only if you built it one.

The two answers leave the same gap.

## The third answer

Make the runtime an HTTP API that somebody else operates.

```
  A. the agent runs on the user's machine
     browser ──▶ local daemon ──▶ agent process ──▶ ~/.config, ~/code, your keys
                 one person, one laptop, asleep when the lid closes

  B. bring your own endpoint
     browser ──▶ your server ──▶ https://someones-agent/…
                 stateless: no shell, no files, nothing remembered
                 unless you also built and now operate that

  C. the runtime is an API                            ← this section
     browser ──▶ Fountain ──▶ a sandbox per teammate: shell, checkout,
     static files             secrets, memory that survives the message
```

Fountain is that third shape. `POST /api/team` hires a teammate and gives it a
machine. `POST /api/team/:id/messages` says something to it. One SSE
connection carries what each teammate does. Your app is static files and a
bearer token.

## What you write, and what you stop writing

| You write | Fountain does |
|---|---|
| The roster, the thread, the composer. | Provisions and holds one sandbox for each teammate. |
| The name of a bot, and how it looks. | Starts `claude`, `codex`, `gemini` or `opencode` in it, or the command that an `acp` agent names. |
| Which connectors you offer. | Encrypts the tokens, injects them at spawn, and redacts them from the output. |
| Your own sign-in, or none. | Accounts, API keys, OAuth, isolation for each user, quota, audit. |
| What a routine is for. | Runs it on a cron. |
| How a thread must look. | Parses ACP events into blocks that you can render. |

One of those two columns has an on-call rotation.

## It already exists, twice

Two apps sit on this API today. Both are open source, and neither has a
backend of its own. They are static files that talk to Fountain, with a key
the person pasted in, or with a "Sign in with Fountain" token.

- **[fountain-team](https://github.com/managoat/demos/tree/main/apps/fountain-team)** is the one
  this section walks through. It has the roster, threads, a queue of messages
  for a teammate that is busy, images, notifications, routines, ⌘K search,
  connectors, and a live activity feed. It is a few thousand lines of React.
- **[fountain-conversations](https://github.com/managoat/demos/tree/main/apps/fountain-conversations)**
  takes the same API from the other end, and shows one conversation in detail.

Fountain's own console holds no chat. It manages agents, secrets and audit.
The chat surfaces are those two apps, on the public API, with no privileged
access to it.

## Two things the clones do not have

**The teammates know each other.** Fountain hands each conversation on the
team channel an MCP server. A teammate can then list the others, find "the
engineer", send one of them a message, and wait for the reply. The exchange
appears in both threads. Read [Team](../api.md#team).

**A teammate is not locked to your app.** The same agent answers over
[ACP](../integrations/acp.md) in an editor, over
[AG-UI](../integrations/openbot.md) from another agent platform, and over
Nostr.

Each of those surfaces binds its own durable thread, by the mechanism
your app uses. Your UI is one door onto something that exists whether or not
the tab is open.

## Next

- [**A team chat, end to end**](team-chat.md) walks the whole app through in
  SDK calls. Hire, message, stream, render, connect, schedule, ship.
- [**What each piece does**](pieces.md) covers which primitive is responsible
  for what, and what happens between Enter and the first word of the reply.
