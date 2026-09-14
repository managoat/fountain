# Agents as teammates

This page explains what a teammate is, and why it is not a fifth primitive.
For the endpoints, read the [Team section](../api.md#team) of the API
reference.

## What a teammate is

A teammate is an [Agent](agent.md) with one
[Conversation](conversation.md) that continues, bound to the reserved channel
`fountain:team`.

That is the whole mechanism. There is no team table and no teammate record.
Fountain binds it the way a Buzz channel binds through `channel_id`, and
points it at a reserved name.

The [team app](https://github.com/managoat/demos/tree/main/apps/fountain-team) lays those
conversations out the way a chat client does. The roster is on the left and
one thread is on the right, on `/api/team`.

## Why it works this way

A teammate needs exactly the properties a Conversation already has.

It must persist across messages, and a Conversation does. It needs a machine
that remembers what it did, and a suspended sandbox keeps that on disk. It
must survive an idle night and wake on the next message, and suspend and
resume already do that.

A fifth primitive would have meant a second lifecycle to keep correct. Each
sandbox reclamation rule would then have needed a teammate variant. To bind a
Conversation to a channel needs none of that.

## How it behaves

Add an Agent to the team, and Fountain opens its conversation. That opens the
sandbox.

A message becomes a follow-up turn in that conversation. A suspended or reclaimed
sandbox wakes on the next message, as it always does.

Fountain replaces a terminated conversation with a fresh one on the same
channel, so the teammate stays reachable. Remove a teammate, and Fountain ends
the live conversation and unbinds the Agent's conversations from the channel.
The rows stay in the usual conversation list.

"Details" on a thread opens the full transcript in the
[conversations app](https://github.com/managoat/demos/tree/main/apps/fountain-conversations), with
stages, tool calls and raw output.

## Three fields that look new and are not

When you add a teammate, you can give it a name of its own, choose the
Environment that builds its sandbox, and attach a Vault.

None of that is new. They are the conversation's `title`, its per-launch
environment override, and its `vault_id`. The pickers offer only what the
Agent's `allowed_environment_ids` and `allowed_vault_ids` permit.

They belong to the teammate, and not to the sandbox. Fountain ends the old
conversation and opens a fresh one, and that fresh one inherits all three.

## Schedules

A schedule is a cron that runs a teammate with a prompt. Cron times are UTC.

By default the prompt goes into the teammate's own conversation, as if you had
typed it. The reply then lands in the thread, and in the memory the teammate
works from.

Set `one_off` to change that. The team app shows it as the
**Run in a one-off computer** checkbox. Each run opens a fresh
conversation on a new sandbox, from the same Agent, Environment and Vault that
you added the teammate with. The thread stays as it is. The run appears in the
conversation list like any other, and the schedule keeps a link to its last
one.

You can pause, edit, delete and run a schedule on demand. When Fountain cannot
deliver a run, the last error shows on the schedule. That happens when the
teammate was busy for half an hour, or when the sandbox quota was full.

Remove a teammate and Fountain deletes its schedules.

The team app, `fountain.team.schedules` in the SDK, and the
[Schedules API](../api.md#schedules) all manage the same rows.

## What a teammate is not

**Not a primitive.** `POST /api/team` adds a teammate, and it creates no new
kind of object. It binds a conversation to the channel. The rest of the
[Team API](../api.md#team) reads and writes that conversation.

**Not a shared inbox.** One Agent has one team conversation. Two people who
message the same teammate talk to the same thread and the same machine.

**Not persistent memory.** The teammate's memory is the sandbox's disk. A
terminate destroys that sandbox and takes the memory with it, and the thread
survives without it. Read [About conversations](conversation.md).

## Where to go next

- [About conversations](conversation.md), for the lifecycle below this one.
- [About agents](agent.md).
- [Team](../api.md#team) and [Schedules](../api.md#schedules) in the API
  reference, for the endpoints.
