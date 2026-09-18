# A conversation is stuck or failed

This guide shows you how to find which step failed, and what to do about it.

## Read the stage events

Open the conversation's log view. Fountain records the progress of a new
sandbox as stage events. They are `provision`, `checkpoint_restore`,
`packages`, `network`, `clone`, `setup` and `turn`. The step that failed names
itself, and the event data holds the exit code.

**`packages`, `clone` or `setup` failed.** The cause is almost always the
environment's own configuration. A package that does not exist, a repository
the token cannot reach, or a setup script that exits non-zero. Fix the
environment, then prompt again.

**`provision` failed outright.** Fountain could not create the sandbox. The
provider is unhealthy, the token is invalid, or the user is at their quota for
concurrent sandboxes. Read [Sandbox errors](sandbox-errors.md).

**Stuck, with no failure.** A `running` conversation with no events usually
means the process on the sandbox side died and Fountain missed the exit.
Interrupt it, or send another prompt. A wake reattaches to the sandbox when
that sandbox still exists.

```bash
fountain conv show <conv-id>          # turn status, sandbox name
fountain conv interrupt <conv-id>     # stop the in-flight turn, keep the sandbox
fountain conv terminate <conv-id>     # destroy the sandbox, end the conversation
```

The sandbox itself has an API. `GET /api/sandboxes/:id` shows its status,
its provider and each conversation on it. `DELETE /api/sandboxes/:id` resets
a persistent sandbox. Fountain destroys the machine and keeps the
conversations, and the next prompt builds a clean machine. Read
[Sandboxes](../api.md#sandboxes).

## The agent runtime crashed

A turn that ends with `exit_code` 132 to 136 or 139 means the runtime process
died. It did not exit with an error of its own. The `turn` stage event names
the signal next to the code:

```
exit_code=139 signal=SIGSEGV
```

A crash can happen while the runtime starts, before it writes any output. In
that case Fountain starts the runtime once more on the same turn, and records a
`session` stage event with `reason: "adapter_crashed"`. Your prompt was not
sent before the crash, so the retry does not run it twice. A second crash
fails the turn. A crash after the runtime has started to answer also fails the
turn, because the prompt may already have run.

Send the prompt again. If the same turn crashes again and again, report it
with the conversation ID. A turn that has execution limits is not retried.

## The provider refused the model

A turn fails when the model provider refuses the agent's model. Fountain
records a `model` stage event with the refused id. The `turn` stage event holds
the provider's own message, and that message usually names a replacement.

```
The provider refused this agent's model (gemini-2.5-pro): This model
models/gemini-2.5-pro is no longer available to new users. Please update
your code to use models/gemini-3.1-pro-preview for the latest features
and improvements.
```

Open the agent. Set the model field to the replacement. Send the prompt again.
Each turn fails in the same way until that field changes.

The models Fountain lists are advice, not a set of permitted values. Fountain
accepts model IDs under known providers, then asks the runtime to select the
model before inference. The installed runtime must support the model, and the
provider account must have access. A rejected selection stops the turn. Check
the turn's `model_selection` field and `model` stage for the requested ID and
failure. An older runtime can need an update even when the account has access.
A provider can also retire a model that worked last month.

## What the statuses mean

`failed` and `terminated` are the two terminal states. Fountain refuses a
further prompt.

`idle` with a *suspended* sandbox is the normal state at rest, and not an
error. The sandbox parks and scales to zero. The next prompt wakes it, and the
agent's memory is intact.

`idle` with a *destroyed* sandbox is what a reset, an admin reap or a
configured max-lifetime ceiling leaves behind. A reset is
`DELETE /api/sandboxes/:id`. An admin reap is
`POST /api/admin/sandboxes/:id/reap`, or the admin page. The next prompt provisions a fresh
sandbox. Fountain leaves the stored transcript alone, but the agent starts a
fresh session. Read [About conversations](../concepts/conversation.md), and
the full table in [Conversation states](../reference/conversation-states.md).

## The knock-on effect on quota

A crash in the middle of a provision leaves a `pending` or `starting` sandbox
row. That row counts against the user's quota, which is 2 concurrent sandboxes
by default.

The reaper runs each hour at :07 and releases a row that has been stuck for
more than 60 minutes. An admin can raise a user's cap at once, from
`/admin/users` or with `POST /api/admin/users/:id/sandbox-limit`. An admin
can also see every sandbox with `GET /api/admin/sandboxes`, and release a
stuck one with `POST /api/admin/sandboxes/:id/reap`. Read
[Admin](../api.md#admin).

The reaper logs one summary line for each run.

```bash
kubectl logs -n fountain -l app=fountain --since=2h | grep 'reaper:'
# reaper: released=0 parked=1 expired=0 destroyed=2 untracked=102 live=114
```

`parked` counts the idle sandboxes the reaper suspended. The reaper can undo
that, and it is not a teardown.

## Conversations from before August 2026

Stage status is reliable now. It was not always. On the default provider, a
setup script or a clone that failed could record as successful. The client
discarded the exit code and read a 0. See
[#880](https://github.com/managoat/fountain/issues/880), fixed on
2026-08-23. For a conversation that ran before that date, read the logged
output. Do not trust its stage status.

## Related

- [Sandbox errors](sandbox-errors.md).
- [Conversation states](../reference/conversation-states.md).
- [Change sandbox lifetimes](../guides/operate/sandbox-lifetime.md).
