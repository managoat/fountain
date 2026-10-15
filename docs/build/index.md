# The shape everyone clones

The same app comes round again and again. It is a chat client whose contacts
are bots. The roster is on the left and the thread is on the right. A **+**
makes a new bot out of a name and a one-line brief. A settings panel connects it to
GitHub or Notion. Grok Bot shipped that shape, and the clones are everywhere.

The front end is a weekend of work. The machinery under it is not.

## What a bot needs, and a chat UI does not give it

A useful bot is a process on a machine. So something must supply the
machine.

| Behind the bubble | What it truly means |
|---|---|
| A machine. | A filesystem, a shell, a package manager, a network. |
| Credentials. | A GitHub token that works, and that sits in neither the prompt nor the transcript. |
| Memory. | The second message costs a sentence, and not a re-explanation of the first. |
| Isolation. | One bot's token and files, on a machine that is not the one that serves your app. |
| A lifecycle. | Something starts that machine, parks it while nobody types, and wakes it. |
| Tenancy. | The second person who signs in does not see the first one's bots. |

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
credentials in it, keeps its memory between calls, and stops one user from
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
     browser ──▶ Managoat ──▶ a sandbox per conversation: shell, checkout,
     static files             secrets, memory that survives the message
```

Managoat is that third shape. `POST /api/conversations` starts an agent on a
machine of its own. `POST /api/conversations/:id/prompts` says something to
it. One SSE connection, `GET /api/events/stream`, carries what every
conversation does. Your app is static files and a bearer token.

## What you write, and what you stop writing

| You write | Managoat does |
|---|---|
| The roster, the thread, the composer. | Provisions and holds one sandbox for each conversation. |
| The name of a bot, and how it looks. | Starts `claude`, `codex` or `gemini` in it, or the command that an `acp` agent names. |
| Which connectors you offer. | Encrypts the tokens, injects them at spawn, and redacts them from the output. |
| Your own sign-in, or none. | Accounts, API keys, OAuth, isolation for each user, a fleet ceiling, audit. |
| How a thread must look. | Parses ACP events into blocks that you can render. |

One of those two columns has an on-call rotation.

## It already exists

[fountain-conversations](https://github.com/managoat/demos/tree/main/apps/fountain-conversations)
sits on this API today. It is open source and has no backend of its own: it
is static files that talk to Managoat, with a key the person pasted in, or
with a "Sign in with Managoat" token.

Managoat's own console holds no chat. It manages the account, its keys and the audit trail.
The chat surface is an app on the public API, with no privileged access to
it.

## One thread per contact

Keep the conversation's id beside the contact, and send each message to it.
A suspended conversation wakes on the next prompt. Or let Managoat keep the
mapping: start the conversation with a `channel_id` of your own, and a later
start with the same agent and `channel_id` resumes it. Read
[What each piece does](pieces.md#one-agent-one-thread-that-lasts).

The same agent answers over [ACP](../integrations/acp.md) in an editor, and
over the [API](../api.md) from your own code. Your UI is one door onto
something that exists whether or not the tab is open.

Managoat has no scheduler. For "each weekday at nine", run your own cron and
send the prompt when it fires.

## Next

- [**The TypeScript SDK**](../sdk.md) is the client the app is written in.
- [**What each piece does**](pieces.md) covers which primitive is responsible
  for what, and what happens between Enter and the first word of the reply.
