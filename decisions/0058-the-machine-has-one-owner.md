---
type: ADR
title: "The machine has one owner"
description: "Proposed 2026-09-16, nothing built. One process per sandbox, backed by a durable lease on the row, becomes the only writer of sandboxes.status and the only caller of the provider's create, resume, suspend, destroy and checkpoint; conversation servers, the reaper, Launch, Wake, Reapply, Termination, admin and account deletion ask it. Delivers the per-sandbox owner that ADR 0023 step 4 named and its outcome replaced with a lock and a query; settles #2307 and the open decisions on #2255; prerequisite for two agents on one machine (#1089)."
tags: [sandbox, lifecycle, conversations]
status: draft
adr: "0058"
adr_status: "Proposed"
date: 2026-09-16
---

# 0058 — The machine has one owner

**Status:** Proposed — nothing built. Every mechanism below is unbuilt unless
an Outcome section says otherwise. **Date:** 2026-09-16. **Amends:**
[0023](0023-persistent-agent-sandbox.md) (delivers its step 4),
[0017](0017-suspend-idle-sandboxes.md) (the idle and ceiling decision moves
into the owner). **Settles:** #2307; open decisions 1–3 on #2255.
**Prerequisite for:** #1089, #1910, #1120. **Companion:** #805, the
"sandbox as a first-class machine" sketch this converges on.

## Context

Fountain runs several conversations on one sandbox in production (0023, since
2026-08-24; the busiest machine carries 36). 0023 step 4 specified a
per-sandbox process that "serializes provision, resume, park, destroy and
re-provision; holds the refcount of live conversations and which are mid-turn;
keeps the idle and ceiling clock over the union of their activity; enforces
capacity." Its Outcome records that the process was not built:

> There is no `SandboxServer` process. The machine-operation lock is a
> per-sandbox Postgres advisory lock taken by the conversation that needs it
> (`Conversations` around `pg_advisory_xact_lock`), the refcount is the
> conversation rows on the sandbox, and the idle clock is
> `SandboxReaper.last_activity_at/1` over all of them. [...] Revisit if the
> handle and sprite env ever need to move into one owner.

This is the revisit. On `main` at `c3f568596` (2026-09-16),
`Conversations.update_sandbox/2` is called from 24 sites in 11 files (28 row
writes counting its sibling `claim_sandbox/2`, three in the server and one in
`Lifecycle.park/4`), and the provider's create, resume, suspend, destroy and
checkpoint from 17 sites in 9 files:

| Writer | `update_sandbox` sites | provider mutations | protected by |
|---|---|---|---|
| `conversations/conversation_server.ex` | 7 | 4 | its own state; `expected_sandbox_id` on ending writes |
| `workers/sandbox_reaper.ex` | 3 | 2 | a bare registry-liveness scan (`Lifecycle.any_server_alive?/1`); no fence |
| `conversations/termination.ex` | 3 | 1 | the teardown fence (`teardown_requested_at`) |
| `conversations/provisioning.ex`, `provision_watchdog.ex` | 2 | 3 | a retirement changeset match |
| `conversations/wake.ex` | 2 | 1 | the quota reservation lock, not the sandbox lock |
| `conversations/reapply.ex` | 2 | — | `configuration_revision` |
| `conversations.ex`, `conversations/lifecycle.ex` | 3 | 4 | the advisory transaction lock; `_unsafe_sandbox_held_by_other?/2` |
| `home_checkpoint.ex`, `accounts/deletion.ex` | 2 | 2 | each its own |

Every one of those protections is compensation for the owner that was not
built. `reset_requested_at` and `teardown_requested_at` are fence columns a
writer must check because no one owns the state they fence.
`expected_sandbox_id` (the nine-PR #1767 campaign; #2021 lists the writes it
still misses) is a compare-and-set token each ending write carries because the
row has no single writer. The retirement changeset match is copied four times
(#2039). Four unrelated readings answer "is anyone else on this sandbox"
(#2255 listed them at `269f2fe6`): `_unsafe_sandbox_held_by_other?/2`
(status only), `_unsafe_sandbox_busy_elsewhere?/4` (status and the idle
window), `Lifecycle.live_conversation_ids/1` with `any_server_alive?/1`
(registry liveness over a preloaded row), and `_unsafe_list_cotenant_ids/2`.
#2257 and #2309 had already folded the reaper's and the admin reap's bare
`whereis/1` scans into the third, so at `c3f568596` the names are these.

The clearest evidence is #2286. It tried to make the reaper's idle park safe
with a lock and a durable claim, went five adversarial review rounds, each
finding a real ordering gap, and was withdrawn. #2307 records the seven
constraints those rounds established and asks for an ADR before more code. The
constraints are correct and they are not reaper constraints: they describe
what any owner of the machine must do. The two that a lock cannot satisfy are
that the provider round trip sits between "decide" and "write" (a
transaction-scoped lock cannot span it), and that Horde registry propagation
is asynchronous, so "no live server" on one node is not evidence of absence
during a rolling deploy.

#2175 and #2255 gave each conversation lifecycle verb one owner — `Launch`,
`Wake`, `Termination`, `Reapply`, `Interruption` — and did it by pure moves
that landed in a day. Decision 3 recorded on #2175 that day — "The machine
stays in the conversation server. ADR 0023 stands; no `SandboxServer`." — is
the one this ADR reopens. The verbs
now have owners; the thing they all act on still has none. This is the shape
Erlang has a standard answer for: state with many concurrent writers and
external I/O in the middle of its transitions gets a process.

The product direction needs the owner first. #805 names the target
vocabulary: the sandbox is a first-class machine, and a conversation is a
binding of an agent to one. #1089 scoped two agents on one machine and found
the identity-key change trivial and the disk scoping hard: skills, the
instructions file, `.mcp.json` and `~/.codex` sit at runtime-global paths and
are rewritten on every reattach by whichever conversation woke last. #1910 is
that collision live in production. "Materialize this agent's layer onto this
disk" is a machine operation with nowhere to live.

## Decision

A sandbox gets one owner: a `Fountain.Machines.Machine` process, registered
in `Horde.Registry` under the sandbox id and backed by a durable lease on the
`sandboxes` row. It is the only code that writes `sandboxes.status` and the
timestamps that accompany a transition, the only code that calls
`Managoat.Sandbox.create/2`, `resume/1`, `suspend/1`, `destroy/1` and
`create_checkpoint/1`, and the one answer to "who is on this machine, and is
anyone mid-turn". Conversation servers, the reaper, `Launch`, `Wake`,
`Reapply`, `Termination`, the admin surfaces and `Accounts.Deletion` send it
requests and never touch the row or the provider. The two sandbox modes become
one lifecycle policy on the machine: `ephemeral` is a machine that destroys
itself on its last detach, `persistent` one that parks. The `sandboxes` table
and the `sandbox_mode` attribute keep their names and their API; the module
namespace is new. (Stage 7a gathered that policy — the provider capability,
park vs destroy at each bound, the keep rule on the last detach, and the default
mode — into `Fountain.Machines.Policy`, as a move with no behaviour change. What
the policy *decides* now lives in one place; the queries that ask it the
questions stayed where they are, because two of them run inside the teardown
fence's own transaction.)

### The owner is a lease first and a process second

A process alone can have two instances across a rolling deploy (#2307
constraint 4, reproduced on #2286). The source of truth is therefore a lease
on the row — `lease_epoch` (a monotonic integer), `lease_node`, `lease_until`
— claimed in one short transaction under the existing per-sandbox advisory
lock and renewed by the process on a timer. (Stage 7a built the timer, as
`Fountain.Machines.Renewal`, and settled the clock it runs on: `lease_until` is
written and judged by the database's `statement_timestamp()`, so a cluster has
one clock rather than one per node. The lease is still *per operation* — an idle
machine holds none, which is what keeps stage 6a's "busy means a live lease"
true — and what the timer changes is that it bounds an operation that is making
progress rather than one that started less than a TTL ago.) Every state write
the owner makes
is a compare-and-set on `(id, lease_epoch)`. A write from a superseded epoch
affects zero rows, and the process that made it stops. Takeover after a crash
or a partition is: the lease has expired, a new claimant takes a new epoch
under the lock, and any in-flight work from the old epoch fails its
compare-and-set. This is #2307 constraints 1–3 implemented once, in one
module, instead of per writer. (Stage 8b added one early door to expiry, and
it is not the name-based rule constraint 4 forbids: a holder whose
`lease_node` is not a connected node **and** whose lease has run down under
*half* a renew interval of the shortest TTL is taken over before
`lease_until`. Half, because a live renewer stands at one whole renew interval
when a single renewal has been missed — a headroom of one interval is a line it
touches, and round 1 drove exactly that, evicting an alive, renewing,
partitioned holder forty seconds early after one slow renewal. At half an
interval a partitioned holder that is alive may miss a renewal outright and keep
its machine; two missed in a row is past the lease anyway. Stage 8b round 3
added the other half of that property: the renewer schedules each attempt from
the slot it was due in rather than from the last attempt's return, so a failing
renewal's own duration no longer comes out of the headroom — without it a 12 s
database stall at TTL 60 took the machine off a live holder.)

### In-flight states are durable states, not locks

The status set `pending starting ready suspended terminated failed` gains a
nullable `transition` column (`provisioning`, `resuming`, `parking`,
`destroying`, `retargeting`) and a `transition_reason`, stamped with the
epoch. The owner writes the transition before any provider I/O, does the I/O
outside every transaction, then finalizes with a compare-and-set on the same
epoch and transition. Any reader sees intent: a wake that finds `parking`
*under a live lease* returns a retryable refusal rather than racing the
suspend. (Stage 6a narrowed that to the lease: a transition whose lease has
expired is an owner that died, not one working, and refusing a reader on it
withheld a machine for as long as the sweep that gives up on the row takes to
run. Takeover, below, is what resolves it.) A finalize lost
after a successful provider call is repaired at takeover, which reads the
transition and the machine's true state and compensates — never both. (Stage
6b built that for `parking` and settled what "compensates" means there: the
taker finalizes a machine the provider reports suspended, and *clears the
transition* on one it reports running, leaving the row `ready` for the next
idle verdict to act on. It never resumes. A resume is compute, and constraint 5
puts compute behind the account-suspension and credit gates this protocol does
not consult; and the compare-and-set has already made the superseded owner's
own call invisible, so there is nothing to undo.)
`reset_requested_at` and `teardown_requested_at` become
`transition: destroying` with a reason. (Stage 9a settled what that costs, and
it is not a rename. Those two columns are **durable intent**: refused whatever
the lease says, surviving a crashed owner indefinitely. A `transition` stamp is
**abandonable**: 6a's `register_server/2`, 7a's `Resume.under_lease/3` and 6b's
park takeover all clear a lease-less one on sight, which is what stops an owner
that died mid-operation withholding a machine until a sweep gives up on the
row. So `destroying` is made the one durable transition — never cleared by a
reader, refused regardless of lease, kept by `Lease.cas_update/4` through any
write that does not retire the row — and its completion is *driven*:
`Destroy.run/2` already continues from a `destroying` stamp on claim, and
`SandboxReaper.sweep_fenced_teardowns/0` became the thing that calls it on a row
whose lease is dead. Every fence writer stamps it in the same commit as the
columns, so no row records the intent in a column alone before 9b drops them.)

### The verbs

| Machine verb | Replaces today | The owner's rule |
|---|---|---|
| `attach(conv, agent_layer)` / `detach(conv)` | the attach door, release, `_unsafe_sandbox_held_by_other?/2` | a refcount; the last detach applies the mode's policy. Stage 8b built both as `Fountain.Machines.Binding`: the conversation row that binds an agent to a machine is inserted by the owner under its lock (`Launch.attach_conversation/3` and `Team.open_fresh_conversation/3` both ask, the rotation before it releases the conversation it is replacing), the refcount is the non-terminal rows read through `Occupancy` (so a conversation that ends without a detach simply stops counting), and the last-detach decision is the teardown fence with a terminating conversation, which now refuses a live lease and carries the caller's deadline. A release is a detach that keeps the machine and runs inline, being a conversation write. The agent layer waits for #1089 |
| `admit_turn(conv, runtime)` / `end_turn(conv)` | the locked turn insert, `_unsafe_sandbox_busy_elsewhere?/4`, the capacity check | capacity per `Runtimes.ACP.concurrency/1`, counted per runtime (#1089 blocker 4). Stage 8a built both as `Fountain.Machines.Admission`: the insert refuses a live lease and either fence under its lock and counts per runtime; `end_turn` is the door for every turn-ending write an actor makes and runs inline whichever way the gate is set, because it mutates no machine. `_unsafe_sandbox_busy_elsewhere?/4` was never an admission check — it is the idle verdict's reading, and it stays where stage 4 put it, in `Occupancy` |
| `ensure_up()` | `Provisioning` create and its watchdog, `Wake`'s suspended resume, the rehydrator's start | two prompts waking one machine resume it once; the second waits (0023 step 4). Stage 7a built the resume half, as `Fountain.Machines.Resume`, with the quota gate settled *before* the provider call rather than around it. Stage 7b built the provision half as `Fountain.Machines.Provision`, and as a **bracket** rather than a move: the owner takes the lease, stamps the intent, creates the machine and writes the outcome, while the conversation server's pipeline runs in the middle as a callback. `Machine.provision/3` therefore runs inline on its caller whichever way the gate is set — the callback is that server's own state-building work (0037, #1369) and it runs for minutes |
| `park(reason)` | `SandboxReaper.idle_sweep/2`, `Lifecycle.park/4`, `HomeCheckpoint` | refused while a turn is admitted that this park is not itself cutting; the checkpoint happens inside the transition |
| `destroy(reason, actor)` | terminate, reset, agent delete, admin reap, account deletion, `Lifecycle.destroy/4` | one door; one `sandbox.destroyed` audit event carrying the actor (0013) |
| `retarget(triple)` | `Reapply`'s row write | refused with cotenants or a changed `build_fingerprint`, as 0023's 2026-09-11 amendment says. Stage 8b built it as `Binding.retarget/3`, inline and inside the reapply's own transaction, which already holds the machine's lock; `Reapply.mount_skills/3`'s skills record goes through the same verb |
| `machine_gone` (inbound) | the `{:machine_gone, …}` cast senders | the owner tells every bound conversation once; `MachineEvents` becomes its outbound. Stage 8b: `Wake`'s two direct sends for a replaced machine's co-tenants are the destroy's `:notify` now, and a lexical pin keeps `MachineEvents.tell_cotenants/5` callable from `lib/fountain/machines/` only. The owner also **ends the turns it operates over**: a destroy ends every running turn bound to the machine at its finalize, a ceiling park ends the requester's own turn *strictly before* it stamps `parking` — its own write, committed first, not the stamp's transaction — so no reader ever meets a `running` turn on a `parking` row, and a park over a turn nothing is driving leaves it — stage 6b's rule, a turn parked on a person's permission is theirs to answer |

### What the conversation server keeps

Its adapter, transcript, callback key, turn state machine and the handle
(`Managoat.Sandbox.build_handle/2` is pure; the owner hands over the row and
the server rebuilds it). It asks the owner for a turn slot and is told when
the machine is gone. It never reads or writes `sandboxes`. `state.sandbox_id`
stays immutable; the binding fence it powers today is replaced by the epoch.
(Stage 8a moved every turn-ending write behind `Machine.end_turn/3` and found
that the epoch cannot fence them yet: on a shared home a cotenant's resume or
park moves the machine's epoch while this conversation's turn is legitimately
running, a park that proceeds over a turn whose server is dead moves it too,
and the recovery of that turn is exactly the write that then has to succeed.
The fence stays the conversation's *current binding*, defined once in
`Fountain.Machines.Admission.bound?/2`, until the owner ends the turns it
parks, destroys or resumes over — stage 8b's `machine_gone` work — after which
a stale actor's write always finds a turn already ended and the epoch can
stand. Stage 8b built the destroy half of that and the ceiling park's, and
deliberately not a park over a turn nothing is driving: a permission-parked
turn whose server died is still a person's to answer, which is 6b's rule and
the reason counterexample 2 still holds. The binding stays the fence.)

### The reaper schedules; it does not write

`SandboxReaper` keeps its scans and telemetry and sends `park` or `destroy`
requests to the owner, which revalidates eligibility itself under its own
lease. The untracked-sprite report and the destroy of provider machines whose
rows are already terminal stay in the reaper; they concern machines no owner
will ever claim.

### Rollout

Behind `MACHINE_OWNER_ENABLED` (runtime configuration, default off) until
every serving replica reads the lease and transition columns (#2307
constraint 7). While it is off, every existing fence stays in force. The
migration is additive. The fence columns are dropped in a later release, after
the flip, under the migration and changelog rules in CONTRIBUTING.

## Consequences

**Deleted once the gate flips.** The `expected_sandbox_id` plumbing (seven
sites in four files) and the `:noop` reconciliation debt #2021 describes;
`reset_requested_at` and `teardown_requested_at`; four liveness predicates
become one; the two copies of the admin reap audit become one; the retirement
changeset match copied four times (#2039); the salvage branch
`follow/2255-reaper-liveness-lock`.

Two of those are amended by what stage 9a built. `SandboxReaper.sweep_fenced_teardowns/0`
and `SandboxResetReconciler` are **not** deleted: they are the drivers that
finish a `destroying` row whose owner died, which is the thing that makes the
stamp safe to rely on, and deleting either would reopen #2021 item 7. What 9a
removed from them is the writing — neither writes a terminal status any more;
both ask the owner. 9b decides only whether the reconciler folds into the reaper.

**The mixed-version window.** During the 9a rollout an old replica still clears
a lease-less `destroying` stamp (6a/7a code) and still writes an abandoned
teardown terminal through `update_sandbox/2`. Nothing is lost either way,
because the two fence columns are still written and still read on every node —
which is the whole reason 9a writes both and 9b drops the columns a release
later rather than in the same PR. The one shape that outlives the window is a
*terminal* row still wearing the stamp, which only an old replica's write now
produces; `Machines.Destroy`'s `already_terminal` clause clears it and stays for
as long as such a replica can exist.

**New.** `Fountain.Machines.{Machine, Lease, Policy, Occupancy, Destroy, Park,
Resume, Renewal, Admission, Binding}` and `Fountain.MachineRegistry`; six columns on `sandboxes` (the five lease and
transition columns, and `woken_at`, the wake-registration marker stage 6a
added for constraint 4); the existing `sandbox_unavailable` carried into every
transient-error vocabulary that was missing it, rather than a new refusal word
(stage 6a; #2307 constraint 6 lists the sites); one GenServer per *active*
machine, idle-stopping, not one per row; a ratchet test that pins direct writes
and only goes down.

**Unchanged.** The product: `sandbox_mode`, `sandbox_id` attach, every door
#1070 opened, the API and the four SDKs. #2175's verb owners. The size pin on
`conversation_server.ex`, which keeps ratcheting down as its last writes
leave. 0023's identity key — loosening it is #1089, after this.

**Cost.** A distributed lease protocol is real work with real failure modes,
and it needs the adversarial review passes that #2262 showed a behaviour
change in this subsystem requires. The risk it does not remove: a partitioned
node whose lease has expired can still complete a provider call it started.
The compare-and-set makes that write invisible, and the takeover reads the
machine's true state and compensates. Provider I/O is never inside a lock or
a transaction.

**Second order.** #1089 becomes tractable: `attach` takes an agent layer, the
owner materializes it, and per-agent `HOME` follows `Layout.home_env/1`'s
existing precedent; #1910's `CODEX_HOME` fix lands there. #1120 gets a natural
meter, since the owner knows a machine's kept time. 0017's idle and ceiling
policy has one home instead of a server timer and a reaper sweep that
disagree.

## Alternatives considered

- **Keep fencing per write** (#1767 continued) — 25 branches, four writes
  still unfenced (#2021), and #2307 shows the park cannot be fixed by a lock.
  The approach needs every writer to be individually correct, forever.
- **Postgres only: a transition column with compare-and-set, no process** —
  covers constraints 1–3 but not the serialization of two wakes, and the
  provider I/O still has N callers. The process is what makes the I/O
  single-file.
- **Process only, no lease** (0023's `SandboxServer` as written) — two owners
  during a rolling deploy; the asynchronous-registry gap on #2286 is exactly
  this failure.
- **Remove persistent mode** — Team uses it, the busiest production machine
  is persistent, and #1089 is the direction. Ephemeral has the same writers
  (server, reaper, admin, deletion); the races predate 0023 (#649, #936).
- **Rewrite the conversation server** — 0037 promised not a rewrite; #1369
  and #2175 show subtraction works here.

## Implementation brief

For whoever runs the stack. One tracker issue, a `stack:<tracker>` label, one
PR per stage, each PR lowering the ratchet. Stages 1–4 are moves and additive
schema and can be delegated the way #2175's stages were. Stages 5–8 change
behaviour under concurrency and need three independent reviewers with a
reproduction for every claimed race, or they do not merge. Labels on every
stage: `area:sandbox`, `area:conversations`, `lang:elixir`, `P2`.

### Stages

| # | Stage | Kind | Done when |
|---|---|---|---|
| 1 | This ADR; `scripts/decisions-index.sh`; `okf validate decisions`; 0023's Outcome points here; #2307 closed by it; the three #2255 decisions answered on the issue (one predicate; the reaper asks the owner; the admin audit moves into `destroy/2`); #1089 told the owner is its prerequisite | docs | merged |
| 2 | **The ratchet.** `apps/fountain/test/fountain/machines/direct_writes_test.exs` enumerates every `update_sandbox(`, `update_sandbox_row(` and `Managoat.Sandbox.{create,resume,suspend,destroy,create_checkpoint}(` call outside `lib/fountain/machines/`, pinned at the numbers measured on `main` when it lands (28 row writes counting `claim_sandbox(`, 17 provider mutations, at `c3f568596`), failing when the count rises. Same convention as `conversation_server_size_test.exs`: a PR lowers the pin and never raises it. `.credo.exs` ownership entries for the new namespace | test | verified by reverting: one added direct write fails it |
| 3 | **Lease columns and `Fountain.Machines.Lease`.** Additive migration: `lease_epoch bigint not null default 0`, `lease_node`, `lease_until`, `transition`, `transition_reason`, all otherwise nullable, nothing reads them. `Lease.claim/2`, `renew/2`, `release/2`, `take_over/2`, each one short transaction under the existing sandbox advisory lock with a compare-and-set on the epoch; `Lease.cas_update/3` is the one write primitive the owner will use | schema + pure module | two concurrent claimers tested with `pg_blocking_pids`; a stale-epoch write affects zero rows; a SQL fault (a `BEFORE INSERT` trigger raising SQLSTATE 57014, the #2309 proof) leaks nothing out of a transaction; the migration version checked against every open stack |
| 4 | **The process, read-only.** `Fountain.Machines.Machine` GenServer, `Fountain.MachineRegistry`, `ensure_started/1`, `whereis/1`, idle-stop. One verb, `who_is_here/1`: bound conversations, admitted turns, last activity, from the rows. The four predicates delegate to it (#2255 decision 1). No writes. Behind the gate | new module | ratchet unchanged; no changelog fragment |
| 5 | **Destroy through the owner.** `Machine.destroy/2`: `transition: destroying` → provider destroy → compare-and-set finalize → `sandbox.destroyed` audit with the actor. Retarget `Termination.retire_terminated_sandbox/2`, the destroy-home family, `Termination.reap_sandbox/1` (the admin reap), `Accounts.Deletion.destroy_sprites/2`, `Lifecycle.destroy/4`. Under the gate the teardown fence is the transition. #2255 tranche 2 lands here as behaviour under an owner rather than as a move | behaviour | account deletion nilifies `user_id`, so the owner destroys an ownerless row (the #2329 trap); deletion's teardown stays non-fatal (0009); full suite and the deployed suite; changelog fragment; ratchet −9 |
| 6 | **Park through the owner; closes #2307.** Cut in two PRs. **6a, the preparation:** a durable wake-registration marker (`sandboxes.woken_at`, written by one `Conversations.register_server/2` door under the sandbox lock before `start_child`, honoured by the reaper's two liveness passes as a grace condition — constraint 4); the readers that refuse a machine whose owner holds a **live lease** — `Wake.maybe_reuse_sandbox/1`, `Launch.check_attachable/4` and the rehydrator's sweep. A stamped `transition` alone does not refuse them: a transition with a dead lease is an abandoned operation, which `sweep_fenced_teardowns/0` already calls abandoned, and refusing on it answered 503 for up to 75 minutes where `main` handed out a fresh machine at once (round 1). And the vocabulary. **6b:** `Machine.park/2` — refused while any turn is admitted; `transition: parking`; checkpoint and suspend outside any transaction; finalize by compare-and-set; `SandboxReaper.idle_sweep/1` and `Lifecycle.park/4` send the request. **The refusal is the existing `sandbox_unavailable`, not a new word** (Jake, 2026-09-16, amending the Decision's "one retryable refusal" above): it already means "this machine cannot be reached right now", it is already 503 with a `Retry-After` and `NotReadyError` in all four SDKs, and the SDK half of a second word was built and closed unmerged as #2304. Constraint 6's list is still the checklist, of the sites this word was missing from: `SandboxQueue.@transient_errors` (and `TeamScheduleRun`'s snooze guard, which now reads it), `Team.Schedules.describe_error/1`; the fallback controller's 503 mapping and docs/sdk.md already carried it, and no SDK changes. The salvage branch's tests come across | behaviour | 6a: the marker is committed before the child and under the lock; every reader refuses a parking or lease-held row and the reset fence still wins; ratchet unchanged. 6b: admission wins the lock and the reaper skips (the #2286 reproduction) per path; a finalize lost after a successful suspend is compensated at takeover, tested; changelog fragment |
| 7 | **Provision and resume through the owner.** `Machine.ensure_up/1` replaces `Provisioning`'s create and `ProvisionWatchdog`, `Wake`'s suspended resume and the rehydrator's start; two wakes on one machine resume it once. The rehydrator starts conversation servers through the owner so registration has a durable marker (constraint 4). Ephemeral becomes the policy "destroy on last detach" in `Machines.Policy`. Recovery checks the account-suspension and credit gates before resuming compute; an interrupt never provisions (#2262 stands). Cut in two: **7a**, the resume, the renew timer, the database clock, `Machines.Policy` and the owner supervisor's restart budget; **7b**, the provision bracket, `ProvisionWatchdog`, the three failure-arm destroys and the reattach-not-found write. As shipped, 7b also took `Launch.fail_initial_start/2` and `Wake.mark_old_sandbox_terminated/1`, and the **reservation** turned out to need no stamp at all: the row is inserted `pending` inside the quota transaction and `pending` already counts, so the bracket begins after that commit and takes no quota lock | behaviour | full suite, deployed suite, and a production smoke shaped like 0023's gate 7; changelog fragment |
| 8 | **Binding and admission; the fences come out.** `attach/2`, `detach/1`, `admit_turn/2`, `end_turn/1` with capacity counted per runtime; `retarget/2` for `Reapply`. Under the gate, `expected_sandbox_id` leaves `ExecutionGuard`, `Wake`, `Conversations` and the server; the epoch is the fence. `{:machine_gone, …}` is sent by the owner only. The server's last `update_sandbox` and `Managoat.Sandbox.destroy` sites go — **they went in 7b, not here, and the size pin does not drop in 8b**: making the last-detach decision the owner's costs the server twelve lines (three answers where the fence gave two, and a nil-sandbox clause), so 8b leaves the pin at 8a's 2025 and stage 9 is where it moves, with the fence columns and their writers. Cut in two: **8a** admission (built; the fence stays the binding, see above); **8b** binding, retarget, the owner-only cast, the turns the owner ends, the node-liveness takeover (built). **The ratchet does not read zero after 8b**: seven row writes remain, none a binding write — the row's creation (7b's reservation), the context's own door with the reaper's two passes as its callers, the registration marker, and the two fence columns — each stage 9's or named there | behaviour | ratchet reads zero under the gate (it reads 7 after 8b; the seven are stage 9's) |
| 9 | **Make `destroying` durable, then flip, then delete.** Cut in two. **9a:** `destroying` becomes the one durable transition — every reader refuses it regardless of lease and none clears it, `Lease.cas_update/4` keeps it through any write that does not retire the row, both fence writers stamp it beside the two columns, `Quotas` counts it until the row is terminal, and `SandboxReaper.sweep_fenced_teardowns/0` stops writing the row and becomes the driver that asks the owner to finish it (`SandboxResetReconciler` already did). Safe with the gate off and with a mixed-version fleet, because the columns are still written and still read. **9b:** turn `MACHINE_OWNER_ENABLED` on in the hosted overlay after every replica runs 9a, and watch the deploy. Then, one release later: drop the two fence columns and the readers of them, delete the old reaper writes, the retirement-match copies and the gate; delete the salvage branch. **Blocked on one reader first:** `Conversations.MachineEvents.reset/6` decides whether to tell a conversation its machine was *reset* by reading `reset_requested_at` on the already-terminal row — a column forced teardowns set too, so it does not discriminate today either and the stamp cannot replace it (the finalize clears it). 9b needs that notice to read something that does, most likely the reset's own `sandbox.reset` event. Then: amend 0023's Outcome ("there is now a per-sandbox owner, `Fountain.Machines.Machine`, per 0058"); close #2021's remaining items as superseded; move this ADR to Accepted with its own Outcome | behaviour, then a prod change | 9a: a `destroying` row with a dead lease is refused by every reader, one test per reader, each verified by planting the "abandoned → clear" behaviour back; the driver completes an abandoned destroy end to end; ratchet −1. 9b: the deployed suite green on production; the tracker closes |

Not in this tracker: #1089 (two agents on one machine) and #1910
(`CODEX_HOME` per conversation). They open up after stage 8 and get their own
tracker — `attach` takes an agent layer, `Layout` becomes runtime × agent →
path, the identity index drops `agent_id`. Do not pull them forward; the
owner is what makes them a day's work instead of a campaign.

### Rules the reviews have already paid for

- **Revalidate under the lock, every time.** A pre-lock verdict is stale by
  construction (#2307 constraint 1). Say the words in the brief; an agent told
  to "add the lock" will not add the recheck (#2286).
- **Provider I/O is never inside a lock or a transaction.** A nested
  `Repo.transaction` joins the outer one through a savepoint and holds a
  transaction-scoped advisory lock until the outer commit; a nested
  `Repo.rollback` aborts the whole enclosing transaction, so "not eligible,
  skip" is a plain return (#2309).
- **`update_sandbox/2` runs metering and the queue poke after its own
  transaction but inside any enclosing one.** Under a lock, write the row and
  run the effects after commit, with the status the `FOR UPDATE` read saw
  (#2309).
- **Ask of every message-shape change what an old node does with the new
  message, and the reverse.** A chain of squash merges cannot deliver
  "deploy the receiver first"; the gate exists for this (#1767 review).
- **A sweep over failure leftovers must not `{:ok, _} =` its write.** One
  refused row stopped machine cleanup fleet-wide (#2329).
- **Check the size pin and the ratchet against `origin/main` before review,
  not after.** Every green run in the #1767 programme predated the pin
  lowering that then blocked it.
- **Serialize suite re-runs.** Four parallel suites on one Postgres produce
  `tcp recv: closed` failures on unrelated files.
- **Every user-visible stage gets a `changelog.d/` fragment**, and the new
  refusal string touches docs/sdk.md and the SDK mappings in the same PR.
- **Five rounds of "one more finding" means stop and redesign**, not round
  six. That is how this ADR came to exist.

### Before stage 1, ten minutes of measurement

Two read-only production queries, so the tracker's first comment is a number:
live `persistent` homes and their conversations grouped by user, and
conversations per live machine in both modes. And one small PR: put
`sandbox_mode` and whether the launch attached to an existing machine on the
conversation-created analytics event, so the question answers itself next
month. Neither changes the decision.
