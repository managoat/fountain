# Sandbox files versus machine lifecycle (#2394)

**Status: preparation only; the defect is not fixed.** Implementation should
reconcile with [#2386](https://github.com/managoat/fountain/pull/2386), which
was open, approved and passing CI when checked on September 18, 2026 at head
`fd0c5bc9d66a552f57d0dffc3008af5dea6799fd`. This checkout's baseline is
`361c5c6bd9f3abfed07809f626b6b2b365bbb670`.

## Deterministic local reproduction

[`race_probe_test.exs`](race_probe_test.exs) is an opt-in characterization
probe outside the normal application test paths. **Passing means the bug was
observed.** Its assertions intentionally describe current broken behavior;
do not add this file to normal CI as a correctness regression. When the fix
lands, invert the assertions and move them into the regular Machines/files
suite, or remove the characterization in favor of those regressions.

The probe requires a dedicated local test database, real sandbox rows and the
real `Machine.park/2` protocol. Provider exec and suspend are mocked with
explicit message barriers, and unexpected provider lifecycle calls are
rejected. There are no provider resources or credentials. Ecto Sandbox rolls
fixtures back, test Tasks are awaited, and every owner is stopped on exit.

From the repository root, prepare the dedicated database:

```sh
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fountain_2394_test \
  MIX_ENV=test mise exec -- mix ecto.create
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fountain_2394_test \
  MIX_ENV=test mise exec -- mix ecto.migrate
```

Then run from `apps/fountain` (so the existing test helper and Mimic copies
are loaded):

```sh
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fountain_2394_test \
  mise exec -- mix test ../../scripts/sandbox-files/race_probe_test.exs
```

The 24 cases cover `list`, `read`, `diff` and `status`, with the owner gate
both on and off, in each of these schedules:

1. Save a `ready` struct, complete a real park, and call files with the saved
   struct. Provider exec sees the persisted row already `suspended`.
2. Pause park inside provider suspend, after the real lease claim and
   `parking` stamp. The files operation enters provider exec while the row
   has that stamp and a live lease.
3. Pause a files operation inside provider exec, then park from a competing
   process. Park enters suspend and completes before the read is released.

The barriers establish order without sleeps or probabilistic loops. The
provider callbacks assert `Repo.in_transaction?() == false`. These are
competing BEAM processes sharing one SQL Sandbox connection, sufficient for
the demonstrated ordered gap; they are **not** a distributed or independent
database-connection exclusion proof. The eventual fix needs those stronger
checks too.

On the baseline above, the probe completed with **24 cases, 0 failures**
(seed `297838`): all 24 expected defective schedules were observed. This is
reproduction evidence, not a passing acceptance suite for a fix.

## Proposed admission contract — not implemented

Add one `Fountain.Machines.Read` protocol, exposed through a
`Machine.read_files` door, and have all four `SandboxFiles` operations use it.
Pass the tenant-scoped sandbox's ID and immutable tenant identity plus one
fixed operation descriptor; do not expose arbitrary exec or accept a caller's
`status` as authority. Keep path validation, fixed scripts, physical-root
confinement, redaction and parsing in `SandboxFiles`.
Coordinate with #2379's stored sandbox runtime: preserve its `cwd/1` change
and resolve roots from the machine's runtime, with its defined legacy
fallback, rather than reintroducing the mutable agent runtime here.

The door must reject an enclosing transaction before dispatch, as the park
door does. With the gate on it routes through the machine owner; with the
gate off it runs the **same** protocol inline. Both paths acquire the
existing durable machine lease under the same advisory lock. The owner
mailbox only routes work; it is not the exclusion primitive. Start with one
exclusive read at a time, avoiding a second shared-reader lock protocol.

Acquire and validate in a short transaction on the existing machine lock:

- Read the current row and database clock after acquiring the lock. Verify
  tenant identity and that the row still exists; build provider identity,
  runtime roots and redaction context from this fresh row, not the supplied
  struct or its preloads.
- Require `status == "ready"`. Refuse pending, starting, suspended, failed
  and terminated rows. A stale non-ready supplied struct must also be judged
  from fresh state; it is not an authoritative refusal.
- Refuse an existing live lease or a pending lifecycle reservation described
  below. Do not poll/retry an ordinary files read or let it occupy the queue
  for a fresh 30-second budget after waiting.
- Refuse `transition == "destroying"` **even if its lease is absent or
  expired**. #2386 makes this durable intent. Also honor the migration-era
  reset/teardown fences through a private Machines predicate; they must not
  become fields in the public read contract.
- Refuse other non-null transition stamps conservatively. An abandoned park
  may have suspended the provider before losing its finalize. A read must
  neither erase that stamp nor call `ensure_up`, `resume` or `provision` to
  repair it. Recovery remains with the lifecycle protocol.
- Claim an epoch and record the read request's fixed absolute deadline, then
  commit. Execute provider I/O only after every transaction/advisory lock has
  ended. Verify the same epoch, live lease, deadline and caller cancellation
  immediately before dispatch; do not rebuild a fresh deadline on retry.

The lease spans execution and cleanup. No provider call may be made merely
because a second row read still said ready: exclusion must remain held across
the call. Do not update idle activity, `woken_at` or turn timestamps for a
files read; dashboard polling must not restart the reclamation clock.

## Deadlines, caller death and release

Use an absolute total request budget measured from entry, including owner
queue time, admission, provider work and cleanup. Preserve today's 30-second
provider budget as a ceiling, not a new 30 seconds after each phase. Reserve
an explicit cleanup allowance and pin all bounds against `Lease`'s 10-second
absent-node early-takeover headroom. Use the database clock for persisted and
cross-node deadlines; use monotonic time only for local remaining waits.

A concrete initial budget to validate is 45 seconds total: at most 5 seconds
for queue/lock admission, at most 30 seconds for provider execution and
10 seconds reserved for cleanup. Use a 60-second lease without renewal for
this bounded operation: even the absent-node early-takeover threshold is
50 seconds after claim, beyond its remaining request/cleanup window. These
are proposed numbers; pin the inequalities in `machine_bounds_test.exs` and
verify outer HTTP timeouts before adopting them. Reduce the provider's
remaining allowance when earlier phases overrun; never extend the original
request deadline to accommodate a late owner message.

The owner message carries the original request ID, deadline and caller
identity. A message past its deadline must refuse before claiming and again
after any lock wait. A caller timeout cancels that request ID; the owner must
consume or reject the cancellation before a delayed request can dispatch.
Caller death must also cancel queued work. A mailbox timeout by itself does
neither. Remote-caller monitoring must work across nodes; PID identity must
not be inferred from the lease's node-name field.

Define the cancellation race explicitly: cancellation that wins the request's
serialized admission before submission prevents provider dispatch; submission
that wins first transfers responsibility to cleanup. Monitoring notices death
asynchronously, so wall-clock death alone cannot be claimed to have prevented
a call already crossing that boundary. Keep the cancelled/expired request ID
authoritative so a delayed mailbox copy cannot create another attempt.

Once admitted, a supervised operation worker owns the lease and monitors the
requester. It should survive long enough to clean up if the requester dies.
The owner must remain able to process cancellation rather than block inside
a synchronous provider call. Inline mode uses the same worker/bracket, not
an unmonitored call in the HTTP process. Use bounded renewal from
`Machines.Renewal` if needed, with a fixed total ceiling; its existing default
of ten TTLs is not the files deadline, and stopping renewal does not cancel
the provider work.

| Outcome | Required action |
| --- | --- |
| Successful provider completion | Stop renewal, release the exact epoch in `after`, return parsed/redacted result |
| Provider error or exception before submission | Same release; preserve existing unreachable/command-failed translation |
| Caller death or timeout before submission | Cancel queued/admitting worker, release if claimed, zero provider calls |
| Caller death or timeout after submission | End/confirm provider execution as supported, stop worker and renewal, then release; a late success cannot revive the response |
| Lost epoch or uncertain execution termination | Do not publish success or release another epoch; preserve the uncertainty until the defined cleanup/expiry boundary |
| Worker/node death | The lease expires without renewal; reclaim using the documented boundary, with no callback or queued read replay |

There is an implementation prerequisite hidden by today's `timeout: 30_000`:
Sprites and E2B `exec` collectors restart the receive timeout on every output
message. It is an inactivity timeout, not an absolute duration bound.
Sprites kills its local command process at timeout; that alone is not remote
termination evidence. Daytona's `exec` also calls `ensure_started`, relevant
to the separate provider-wake decision in #2395.

Therefore a plain `try/after Lease.release` around today's blocking `exec/4`
is not enough for a strict remote-execution exclusion claim. Before calling
the fix complete, choose and prove the supported boundary: either use an
existing controllable command/session primitive with confirmed termination,
or add a provider-side absolute execution bound whose stop semantics are
tested for the fixed scripts. If only local dispatch/collection can be
bounded, state that narrower guarantee and retain an explicit follow-up;
do not report remote termination as proved by a killed BEAM process. A
provider/DB partition can also leave an old request in flight after lease
expiry; row CAS prevents stale writes, not remote provider effects.

## Fairness across nodes and inline calls

Fail-fast reads and a finite individual lease do not prove fair reclamation:
a poller can repeatedly win the gap between release and the reaper's next
claim. The existing `Lease.claim/4` is an opportunistic claim and has no
writer queue. An owner mailbox cannot repair this while other nodes or
inline callers can claim directly.

Recommended design: extend **the existing Lease protocol** with a bounded
durable lifecycle reservation, checked under its existing lock. A small
`machine_lease_requests` table can hold a unique request ID, sandbox ID,
kind (`park`/`destroy`), requester identity, insertion order and expiry on the
database clock. No second coordinator process is needed. Register before
waiting, refuse new reads while a live lifecycle request is pending, and
claim the oldest eligible lifecycle request when the active read drains.
Remove/cancel by request ID on completion, supersession or known refusal;
expire abandoned requests. Cap/deduplicate requests per machine so polling
cannot build an unbounded database queue.

The reservation lifetime must span the **maximum remaining admitted read
plus cleanup plus lifecycle claim allowance**, not merely today's five-second
park/destroy busy wait. Otherwise a 30-second read outlives the reservation
and polling wins again. A reclaim operation that outlives its requesting
HTTP call can continue through its owner as existing park/destroy do, but a
read cannot. Preserve destroy's durable intent even after a request record
expires. If the implementation chooses another representation, require the
same competing-process and separate-connection proof; a shorter polling
interval or read cooldown alone is not that proof.

This reservation extension is proposed, not a settled schema or shipped
behavior. Reassess its size after #2386 lands and record the final protocol
and cancellation limits in ADR 0058's outcome when implementing.

## Refusal/API compatibility and implementation checks

Keep existing non-ready rows as `{:sandbox_not_ready, actual_status}` (HTTP
409), and missing/foreign rows as 404 through the existing scoped fetch.
Proposed busy/fenced/deadline refusals use the existing 503 unreachable error
envelope with fixed, non-secret reason text; a ready row with a lifecycle
conflict must not be reported as successfully read. This is a proposed
translation to pin in context/controller tests, not an implemented API.
If code or schema changes the declared response contract, regenerate and
check SDK propagation per `CONTRIBUTING.md`.

The implementation's proof should include:

- Invert the 24 probe cases into normal regressions, and add corresponding
  destroy-wins/read-wins schedules; assert provider-call ordering and zero
  calls after refusal rather than only return values.
- Fresh/stale supplied structs in both directions; all non-ready statuses;
  live leases; stamp-only destroying with an expired lease after #2386;
  migration-era fence-only rows and abandoned parking stamps.
- Provider success, error, raise, never returning, and continuous output;
  cancellation while queued, waiting for lock, just before dispatch and
  inside provider execution; caller/worker/owner death; stale epoch release;
  cleanup/renewal stops and eventual park/destroy.
- Two real database connections at the claim boundary, two competing owner
  processes, and gate-on/gate-off contenders for one machine. Use a dedicated
  local database and explicit backend-PID checks, as the existing
  `scripts/verify-*-races.exs` probes do; the SQL Sandbox characterization
  above does not supply this evidence.
- Continuous read submissions while a lifecycle request waits; bounded
  request count; abandoned waiter expiry; duplicate request IDs; no late
  provider calls after a refused deadline. Assert an actual reclamation
  result within the stated bound.
- Preserve `sandbox_files_test.exs`, `sandbox_files_script_test.exs` and
  `sandbox_files_controller_test.exs` confinement, output-bound and redaction
  cases; cover controller refusal translation and audit semantics.

Run focused tests plus `mix precommit` and repository policy/changelog checks
for the implementation. The exact claim should be exclusion from
Fountain-controlled park/destroy during the proved execution window.
Autonomous provider sleep and no-wake behavior remain #2395 under #1715;
this work does not close either or silently amend ADR 0039's promise.
