# Conversation states

This page lists the status values a conversation takes, what exists in each
one, and which operations are legal. Read
[About conversations](../concepts/conversation.md) for what a conversation is.

## Transitions

```
pending ---> running <---> idle
   |            |            |
   |            v            |
   +--------> failed <-------+

any non-terminal state ---> terminated
```

`idle` returns to `running` when a follow-up prompt arrives. Each
non-terminal state moves to `terminated` through
`POST /api/conversations/:id/terminate`.

## The states

| Status | What exists | What you can do | Terminal |
|---|---|---|---|
| `pending` | The conversation row, and its resolved set of environment variables. No sandbox yet. | Terminate it. | No |
| `running` | A sandbox, and a turn in flight. | Interrupt the turn, stream events, terminate it. | No |
| `idle` | A sandbox, and no turn in flight. The sandbox can be live or suspended. | Send a follow-up prompt, stream events, terminate it. | No |
| `failed` | The transcript and the log events. Fountain can have destroyed the sandbox already. | Read the transcript. Launch a new conversation. | Yes |
| `terminated` | The transcript and the log events. | Read the transcript. | Yes |

## The sandbox is not the status

A conversation's status describes the run. It does not tell you whether a
machine has power right now.

An `idle` conversation can have a live sandbox, a suspended one, or none at
all. Which one depends on how long it has been idle, and on what the provider
supports.

| Sandbox event | Trigger | Effect on status | Agent memory |
|---|---|---|---|
| Suspend | Idle for `SANDBOX_IDLE_TIMEOUT_MINUTES`, 60 by default. | None. It stays `idle`. | Kept. The disk survives. |
| Wake | The next prompt. | `idle` to `running`. | Kept. |
| Wake without a prompt | `POST /api/conversations/{id}/wake`, or `fountain conv wake <id>`. | None. It stays `idle`. | Kept. |
| Destroy on ceiling | It ran for `SANDBOX_MAX_LIFETIME_HOURS`. Off by default, so this never happens unless you set it. | None. It stays resumable. | Lost for an ephemeral sandbox. Fountain parks a persistent home, which keeps it. |
| Destroy on idle | It went idle on a provider with no `:suspend` capability. | None. | Lost. |

Wake a conversation ahead of its next prompt when that prompt should not wait
for the sandbox: open it in an app, then send. The response is `awake` when
the sandbox was already up and `waking` when the request started it. A
sandbox that is gone is replaced, as a prompt would replace it, and a woken
conversation is suspended again after the same idle period.

You set both bounds for each instance. A `0` turns either one off, and the
ceiling starts off. Read the [configuration reference](../configuration.md).

## Warnings

Do not expect to resume a conversation in `failed` or `terminated`. Launch a
new one.

An interrupt applies to the turn in flight, and not to the conversation. The
conversation returns to `idle` and stays usable.

Do not terminate a conversation you want back. On an ephemeral sandbox that
no other conversation holds, termination destroys the sandbox, and the memory
the agent works from goes with it. A persistent or shared sandbox stays up
for the conversations that remain on it. The transcript stays in both cases.

A sandbox that a configured ceiling reclaims leaves the conversation
resumable, and leaves the agent without its earlier context. State what
matters again on the next turn.

## Where to go next

- [About conversations](../concepts/conversation.md).
- [API reference](../api.md), for the endpoints that cause each transition.
- [Configuration reference](../configuration.md), for the two timeouts.
