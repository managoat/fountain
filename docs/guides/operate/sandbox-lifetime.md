# Sandbox lifetime and cost

Every conversation runs in a sandbox, and a sandbox costs money for as long
as it runs. This page covers the two bounds that reclaim a sandbox, and how to
read what sandboxes cost.

## The two bounds

They do different things, and that difference matters more than the numbers.

| Setting | Default | |
|---|---|---|
| `SANDBOX_IDLE_TIMEOUT_MINUTES` | `60` | No turn activity for this long **suspends** the sandbox. It stays at the provider, scaled to zero. The next prompt wakes it, and the agent's memory is intact. |
| `SANDBOX_MAX_LIFETIME_HOURS` | `0` (off) | A ceiling on one continuous run, from creation or from the last wake. Crossing it **destroys** the sandbox. Off by default, because a machine that runs all day is not a fault. |

A `0` turns either bound off. A value that is not a non-negative integer
refuses to boot. With the ceiling off, the idle timeout is the one automatic
stop, and each provider's fleet ceiling (`SANDBOX_FLEET_CEILING_SPRITES`,
`SANDBOX_FLEET_CEILING_E2B`) bounds how many sandboxes can be up at once.

Neither bound ends the conversation; it stays resumable either way. You can
be aggressive with the idle bound, because a suspend loses nothing. You
cannot be aggressive with the ceiling: the runtime session lives on the disk
it destroys, so the next prompt provisions a fresh sandbox and the agent
starts with no memory of the earlier turns.

Only waking a *suspended* sandbox restarts the ceiling's clock, including a
conversation that reattaches to a sandbox the cleanup pass parked a moment
earlier. A deploy that reattaches a `ready` sandbox leaves the clock alone,
and so does Fountain restarting a `ready` sandbox its provider stopped (on
Sprites, every sprite that scaled to zero on its own).

**A provider without `:suspend` destroys on idle.** It does not fake a park,
because a resume with a fresh disk would lose the agent's memory without a
sound. On such a provider a lower idle timeout costs what the ceiling costs.
Read [the sandbox contract](../../integrations/sandbox-contract.md).

**Fountain never ages a suspended sandbox out.** It stays at the provider
until the conversation is terminated or the account is deleted.
`GET /api/sandboxes?status=suspended` lists the parked ones, and an admin can
reap one with `POST /api/admin/sandboxes/:id/reap`. Read
[Sandboxes](../../api.md#sandboxes).

## Read the reaper's log

The reaper logs a summary each hour at :07, and a shorter line every five
minutes for the deletions it finishes.

```bash
kubectl logs -n fountain -l app=fountain --since=2h | grep 'reaper:'
# reaper: released=0 parked=1 expired=0 refused=0 skipped=0 destroyed=2 untracked=102 live=114
# reaper: teardowns reconciled=0 refused=0
```

| Field | Meaning |
|---|---|
| `parked` | Idle sandboxes suspended. Not a teardown. |
| `refused` (hourly) | Sandboxes the reaper chose to reclaim or park and could not reach: another operation held the machine, or the provider or database did not answer. The next run looks again, but a value that stays high means machines are not being reclaimed and are still billing. |
| `skipped` | Sandboxes left alone because, by the time the reaper took the machine, somebody was using it, it was no longer past a bound, or a reset or teardown had been asked for. Normal on a busy fleet. |
| `reconciled` | Deletions and resets the reaper finished for somebody else. Not routine: each one is a deletion or reset abandoned upstream. |
| `refused` (five-minute) | Of those, the ones it could not finish on that run. The machines are still up, and the next run tries again. |

Deletions and resets record their intent on the machine first and delete it
second, so a server that dies between the two leaves a machine nobody is
deleting. The five-minute run retries a **reset** until the provider confirms
the delete (the trail records `sandbox.reset`). It finishes a **deletion**
once it is fifteen minutes old and no server holds the machine, recording
`sandbox.destroyed` and `sandbox.teardown_reconciled`; if the provider refuses,
the row is retired anyway and the hourly pass deletes the machine later.

Each run acts on at most a fixed number of machines, so a large backlog drains
over several runs.

## What sandboxes cost

Fountain does not total sandbox time. Your provider's invoice is the figure
to trust: Sprites and E2B each bill you for the machines Fountain created on
your account there, from the moment a build starts until the machine goes
away.

A sandbox nobody prompts still runs and still bills at full rate, so idle
time costs the same as working time. The idle timeout above is the lever: a
bill that grows while nobody is talking to the agents means it is too long.

For a live count, the gauge `fountain_sandboxes_by_provider_count` reports
how many sandboxes each provider holds, by status. `/admin/sandboxes` lists
the live ones, with their owners. Read [Observability](observability.md).

Model inference bills through your users' own credentials. The console's
dashboard shows each account its own conversations, turns and tokens for the
month.
