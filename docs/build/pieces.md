# What each piece does

A chat app has three nouns. A contact, a thread, a message. Fountain has
[four primitives](../primitives.md), and they line up.

| In your UI | In Fountain | What it decides |
|---|---|---|
| The contact. | **Agent** | Which model and runtime answer. What the system prompt says. Which skills and MCP servers exist. |
| The thread. | **Conversation** | One session that continues, bound to the reserved channel `fountain:team`. |
| The machine behind it. | Its **sandbox** | The filesystem, the shell, the network, the memory. |
| What it can touch. | **Environment** and **Vault** | Packages, cloned repos, the setup script, and the encrypted values that arrive at spawn. |
| A message. | A **turn** | One prompt, and everything the agent did about it. |

There is no fifth primitive for the team. A teammate *is* a conversation bound
to a channel. So whatever you can do to a conversation, you can do to a
teammate.

```
   Agent  "watchtower"                 the definition. Cheap. Reusable.
     │      runtime, model, system prompt, skills, mcp_servers
     │
     ├── Environment "watchtower-env"  the machine's shape: apt packages,
     │     repos to clone, setup script, encrypted secrets
     │
     └── Conversation ─ channel: fountain:team      ← the thread
           │  turns 1..n, a log feed, a status
           └── Sandbox                              ← the computer
                 Debian, a shell, the repos, the secrets as real env vars,
                 the runtime's session on disk
```

## One agent, one thread that lasts

`channel_id` arranges that. Send to a channel that already has a live
conversation, and Fountain continues it. Your app then needs no
"create or find" dance, and no table of its own that maps a row to a
conversation id.

The team is a reserved channel, `fountain:team`. Any other string is yours.

```ts
// a Slack channel, a Telegram chat, a row in your own product
await fountain.run(text, { agent: "watchtower", channelId: `slack:${channel}` });
```

You get the same behaviour, and one sandbox for each thread, and you use none
of the [team API](../api.md#team) for it. The
[retired AG-UI endpoint](../integrations/openbot.md) bound a coworker channel
the same way before ADR 0057 removed it.

## What happens between Enter and the first word

```
  your app                     Fountain                       the sandbox
  ────────                     ────────                       ───────────
  POST /team/:id/messages ───▶ a turn in flight?  ─ yes ─▶ 400 conversation_busy
                               computer starting? ─ yes ─▶ 503 provisioning
                                     │ no
  ◀─── 202 {conversation_id}         │
       everything else arrives       ▼
       on the stream           wake it, or provision ─────▶ stage: reattach
                                     │                      stage: provision
                                     │                      stage: setup
                                     │                      env + vault become
                                     ▼                      real env vars here
                               prompt the runtime ────────▶ claude / codex / …
                                                                    │  ndjson
  SSE /api/team/stream ◀── redact ◀── persist ◀───────────────────── ┘
       stage: turn/started            every value Fountain
       …                              put in that machine,
       stage: turn/done               8 bytes or longer
```

**The 202 is not the answer.** `POST /messages` queues a turn and returns the
conversation id. Everything after that arrives on the stream. So an app that
awaits a reply must await stream events. The SDK's `Run` handle does that
wait for you.

**Secrets arrive at spawn, and not at the prompt.** Fountain merges the
environment's values with the vault's, and the vault wins on a key collision.
It hands the result to the sandbox as environment variables. They never reach
the prompt, so they never reach the model's context. No clever message can
talk the model into a value it does not hold.

**Redaction happens on the write path.** Fountain scrubs each value of 8 bytes
or more that it put into that sandbox out of the persisted output. The scrub
runs on the one path that each log event takes. It does not run in the client,
and it is not a rule that somebody asks the agent to obey. So `env`, `set -x`
and `cat .env` all persist as `[REDACTED]`. A browser app can therefore offer
a "connect GitHub" button, and think little about the transcript.

## The machine's day

The sandbox has no equivalent in a stateless agent API. Design your empty
states around its lifecycle.

```
  sandbox:  pending ──▶ starting ──▶ ready ──────────────▶ suspended
  presence: starting   starting     online / working       asleep
                                       │      ▲                │
                                       │      └── next message ┘
                                       │          wakes it, memory intact
                                       │
                                       │  a terminate, or a configured
                                       │  max-lifetime ceiling (off by default)
                                       ▼
                                   terminated — the thread stays readable and
                                   resumable; the next turn starts a new
                                   computer, and a new memory
```

`ready` becomes `suspended` after 60 minutes with no turn, by default.

A suspend is free and invisible. The disk survives, which keeps the runtime's
session alive. So message five never explains messages one to four again.

A destroy costs you that. A sandbox that a terminate, or a configured
max-lifetime bound, destroys loses its disk. The stored transcript is intact
and the conversation still resumes, and the agent's own memory of it has gone.

You can configure both bounds, with `SANDBOX_IDLE_TIMEOUT_MINUTES` and
`SANDBOX_MAX_LIFETIME_HOURS`. The ceiling is off by default.
`freshConversation()` is the deliberate version of the same thing. It gives
you a new session on the *same* disk.

## Who reads what

The two feeds a client uses are different on purpose.

| | `/api/team/stream` | `/api/conversations/:id/events` |
|---|---|---|
| Covers | Each teammate. | One thread. |
| Carries | Events, and `blocks` on request, with `conversation_id` and `agent_id`. | Events, and `blocks` on request. |
| Answers | *Something happened, and to whom.* | *The words themselves.* |
| You use it for | The roster, the dots that show a reply on the way, notifications, unread counts. | The thread, as you render it. |

A team UI wants both. One long-lived connection for the roster, and a read of
the open thread's feed. `blocks` keeps the second one from a parser of your
own.

The server parses ACP events into blocks for text, thoughts, tool calls,
results, errors, and permission requests. Your renderer consumes those blocks
across every supported runtime.

## Where the multi-tenancy is

Fountain scopes each route to the key that called it. Across agents,
conversations, secrets, search and audit, a key sees its own account and
nothing else. That scope lives in the queries, and not in each controller.

So the second person to sign in gets their own roster and their own
machines. You write not one line about it.

Nobody can talk a browser app that holds one person's key into a reach for
anybody else's teammates.

*To share* is the part you do not get for free. A teammate belongs to one
account, so a team room that several people share stays your product's
problem. The usual answer is one Fountain account for the team, with your app
in front of it.

## Where to look next

- [The four primitives](../primitives.md) describes the same objects on their
  own terms.
- [Architecture](../architecture.md) covers what runs, and what breaks when a
  dependency is down.
- [Troubleshoot a problem](../troubleshooting/index.md) is what to read when a
  sandbox is stuck.
- [A team chat, end to end](team-chat.md) is the code.
