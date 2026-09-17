# Change sandbox lifetimes

This guide shows you how to widen, narrow or stop the two bounds that reclaim
a sandbox. It also says what each one costs.

## The two bounds

They do different things, and that difference matters more than the numbers
do.

| Setting | Default | |
|---|---|---|
| `SANDBOX_IDLE_TIMEOUT_MINUTES` | `60` | No turn activity for this long **suspends** the sandbox. The sprite stays, scaled to zero. The next prompt wakes it, and the agent's memory is intact. |
| `SANDBOX_MAX_LIFETIME_HOURS` | `0` (off) | A ceiling on one continuous run, from creation or from the last wake. To cross it **destroys** an ephemeral sandbox, and **parks** a persistent one. Off by default, because a machine that runs all day is not a fault. |

A `0` stops either bound. A value that is not a non-negative integer refuses
to boot, and it does not quietly turn the bound off.

With the ceiling off, the idle timeout is the one automatic stop. A sandbox
that stays busy stays up, and the concurrent-sandbox cap bounds how many can
be up at once.

## Which one you can be aggressive with

Neither bound ends the conversation. It stays resumable either way.

You can be aggressive with the idle bound, because a suspend loses nothing.

You cannot be aggressive with the max-lifetime ceiling, if you turn it on.
The runtime session lives on the disk that the ceiling destroys. After a
ceiling reclaim, the next prompt provisions a fresh sandbox, and the agent
starts with no memory of the earlier turns. Expect a user to state their
context again after one. Fountain parks a persistent home instead, and the
home keeps its disk.

Fountain never ages a suspended sandbox out. Its sprite stays at the provider
until you terminate the conversation, or until somebody deletes the account.
A user can also reset a persistent sandbox with `DELETE /api/sandboxes/:id`,
and an admin can reap one with `POST /api/admin/sandboxes/:id/reap`.
`GET /api/sandboxes?status=suspended` lists the parked ones. Read
[Sandboxes](../../api.md#sandboxes).

With `CHECKPOINT_CREATION_ENABLED=true`, Fountain takes a checkpoint of a
persistent sandbox each time it parks, on a provider that has checkpoints.
Read the [configuration reference](../../configuration.md#sandboxes).

## Not every provider can suspend

A provider that does not advertise the `:suspend` capability destroys on idle.
It does not fake a park, because a resume with a fresh disk would lose the
agent's memory without a sound. Read
[the sandbox contract](../../integrations/sandbox-contract.md).

So on such a provider, a lower idle timeout is not free. It costs what the
ceiling costs.

## Verify it worked

The reaper logs one summary line for each run, each hour at :07.

```bash
kubectl logs -n fountain -l app=fountain --since=2h | grep 'reaper:'
# reaper: released=0 parked=1 expired=0 refused=0 skipped=0 reconciled=0 destroyed=2 untracked=102 live=114
```

`parked` counts the idle sandboxes the reaper suspended. The reaper can undo
that, and it is not a teardown.

`refused` counts the sandboxes the reaper decided to reclaim or park and then
could not reach: another operation was holding the machine, or the provider or
the database would not answer. A non-zero value is not a fault on its own — the
next run looks again — but a value that stays high run after run means machines
are not being reclaimed, and those machines are still billing.

`skipped` counts the sandboxes the reaper decided to act on and then left
alone, because by the time it took the machine somebody was using it again, or
it was no longer past a bound, or a reset or teardown had been asked for. That
is the reaper being told it was out of date, which is normal on a busy fleet
and is deliberately kept out of `refused`.

A reaper run parks or reclaims at most a fixed number of machines, so a large
backlog drains over several runs rather than all at once.

## Related

- [About conversations](../../concepts/conversation.md), for what suspend and
  destroy mean to a user.
- [Conversation states](../../reference/conversation-states.md).
- [Configuration reference](../../configuration.md).
