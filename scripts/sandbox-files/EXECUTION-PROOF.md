# Provider execution prerequisites for #2394

Status, September 18, 2026: **the existing execution paths do not yet prove the
required lifecycle exclusion.** This is an executable characterization and
implementation handoff, not a fix or a completed provider certification.

## Decisions made with the maintainer

- Complete the full guarantee: a remote file read must finish or be confirmed
  stopped before conflicting Fountain-controlled park/delete provider work.
- Once park/delete is waiting, refuse new reads promptly. A refused request
  cannot execute later; repeated polling must not delay reclamation indefinitely.
- Preserve existing provider coverage. Do not disable another provider's file
  reads to ship a Sprites-only guarantee.

These decisions settle product scope. The representation of command identity,
uncertain execution and lifecycle priority remains engineering work. In
particular, the `machine_lease_requests` table in the preparation brief is a
proposal, not an approved schema.

## Baselines and evidence level

The executed probes use Fountain main `6870016c6` and its locked
`managoat_sandbox` **0.3.0**, `managoat_runner` **0.2.2**, and `sprites` **0.2.2**.
Local host: macOS; Elixir 1.19.2 / OTP 28; Go 1.26.5. The runner probe was also
cross-compiled and executed in an isolated Linux arm64 container. The offline
probes need no credentials or database. A separate live Sprites run is recorded
below; E2B and Daytona have not been tested live.

The newer library source was also inspected: sandbox 0.4.2 at
`8c27ff32f38e62fd1840a3900a7c7a881edf6ec5`, runner 0.2.3 at
`60c84910b807d9a25087d0c6d645a114a7f2af23`. Their relevant collector and daemon
contracts do not supply the missing guarantees. Merely taking those newer
versions is not a remedy; the executed results below concern Fountain's pins.

| Provider | Executed offline evidence | What remains unproved |
| --- | --- | --- |
| Sprites | Both stdout and ignored stderr extended a 300 ms exec timeout to about 910 ms, ending with exit 0. A delayed spawn returned success after 101 ms with a 10 ms timeout. | The live run below also demonstrates a descendant surviving successful explicit termination. Absolute budget, public stable session identity and lost-response recovery remain required. |
| E2B | The real collector also returned exit 0 after about 910 ms for a 300 ms timeout, for stdout and ignored stderr. A paused-provider lookup called `connect` before exec. | Absolute budget, process-group stop confirmation, identity and uncertain-start recovery. |
| Daytona | A stopped-provider lookup called `start` before exec. | Its forwarded server timeout must be verified for descendants and transport loss; no live timeout claim is made here. |
| Runner | On both macOS and Linux, a real child executed after its parent's 100 ms timeout returned code 137. With an inherited output pipe, exec was still waiting at 500 ms. | Kill and confirm the command's descendants; bound output draining; identify/reconcile an execution across disconnect and daemon restart. Firecracker guest behavior requires separate validation. |

The facade capability check confirms that only Sprites among the four shipped
providers advertises `terminate_session`. E2B, Daytona and runner return
`:not_supported`. That is an adapter capability gap, not evidence that those
platforms cannot implement a safe mechanism.

The offline hosted-provider checks stub the transport boundary and execute the
real adapter collectors. They prove local behavior; they do not prove what a
remote provider does. The runner cases execute the real Go process backend and a
bounded helper subprocess. They do not exercise a WebSocket or Firecracker VM.

## Reproduce without provider credentials

Use the locked dependencies and toolchain as described in `SETUP.md`. From
the Fountain repository root:

```sh
MIX_ENV=test mise exec -- mix run --no-start scripts/sandbox-files/execution_probe.exs
python3 scripts/sandbox-files/run_runner_execution_probe.py
```

The first command starts only Mimic, loads an isolated ExUnit suite and stubs
the provider boundaries. It does not start Fountain or connect to the database.
The second uses a temporary Go overlay to inject the probe into the runner's
test package without adding it to normal test discovery. Its helper processes
use temporary files, have a ten-second self-exit bound, and get a cleanup signal
on test exit. The Go test itself is capped at twenty seconds.

Observed results: **8 Elixir cases and 2 runner subcases passed**. Here,
passing means the existing gaps were reproduced. When production behavior is
fixed, these expectations should fail: replace them with ordinary correctness
regressions rather than weakening the new behavior to retain this result.

The live probe's cleanup has a separate offline correctness regression:

```sh
MIX_ENV=test mise exec -- mix run --no-start scripts/sandbox-files/sprites_cleanup_test.exs
```

Its two cases force a real recovery-file write failure after a stubbed successful
creation. They verify that cleanup still checks the resource ID, deletes the
owned resource and confirms its absence, while refusing to delete a different
incarnation. No provider resource or credential is used. Passing these cases
means the cleanup safeguards hold, rather than that a production gap persists.

## Live Sprites counterexample

The opt-in [Sprites probe](sprites_execution_probe.exs) used the same locked
adapter and SDK against `api.sprites.dev`, with a newly created private sandbox.
Guest platform: `Linux-6.12.105-fly-x86_64-with-glibc2.43`. These are measured
observations from one run, not provider certification:

| Case | Observation |
| --- | --- |
| Continuous stdout, timeout 500 ms | Exit 0 after 2,206 ms. |
| Continuous ignored stderr, timeout 500 ms | Exit 0 after 2,212 ms. |
| Silent parent waiting for ordinary child | Local timeout after 716 ms; child's heartbeat advanced from 9 to 15 afterward. Explicit termination returned `:ok` in 71 ms, then heartbeat remained at 16 during the observation window. |
| Silent parent waiting for a child ignoring `SIGTERM` | Local timeout after 712 ms; child's heartbeat advanced from 8 to 10 afterward. **Explicit termination returned `:ok` in 65 ms, but the child's heartbeat then advanced from 12 to 19.** |

The second child inherited its parent's process group; the probe does not call
`setsid` or create a new process group. It writes its own PID to a marker every
100 ms, with at most 150 writes. Its parent waits for it, with an 18-second
timeout. Independent commands count the marker lines before and after the
termination acknowledgment, separated by a 500 ms observation interval. An
increasing count demonstrates execution after the acknowledgment. A stable
count in the ordinary-child case is only that run's observation, not a universal
process-tree proof.

This is a counterexample to treating the adapter's successful `terminate_session`
result as confirmation that all descendants have stopped. The pinned adapter
requests `SIGTERM`, and accepts an affirmative `exited`/`killed` event followed
by `complete`. The next implementation must establish process-group completion
even when a parent exits before a child. A second request after parent exit must
also account for session identity disappearing; do not assume a 404 proves the
absence of remaining descendants.

The sandbox was deleted after the run and GET returned 404. No existing sandbox
was used. The credential was supplied through the process environment and was
not saved in the evidence or repository.

To repeat with a configured `SPRITES_TOKEN`:

```sh
MIX_ENV=test mise exec -- mix run --no-start scripts/sandbox-files/sprites_execution_probe.exs
```

**This command creates a real provider resource and incurs provider usage.** It
does not start Fountain or access its database. It creates a random name,
records that name and the returned provider ID in a temporary recovery file,
and checks the ID before deleting. It does not adopt existing resources or
automatically retry creation. Local execution guards bound probe calls; remote
test children have finite lifetimes. Cleanup runs after a confirmed creation
even when an ordinary probe error occurs. If creation, cleanup, or the host
process itself fails, use the printed recovery record to reconcile that exact
resource; an uncertain creation is deliberately not treated as ownership.

Session discovery matches a unique marker within this disposable sandbox.
That is sufficient for this diagnostic, **not** the durable execution identity
or lost-start recovery needed by the production contract.

## Execution contract needed before read admission

The existing `exec/4` outcome loses too much information for lifecycle recovery.
Prepare the component-library change and its Fountain consumer together:

1. Persist an unreused operation identity, exact sandbox incarnation and fixed
   deadline before any remote dispatch. Carry that identity through start,
   completion, stop and reconciliation. A locally generated stream reference
   is not a provider execution identity.
2. Bound the entire operation, including resolution, startup, output, cleanup
   and transport. Continuous stdout or stderr must not reset its deadline.
   Keep the existing thirty-second script ceiling; select admission and cleanup
   allowances from measured semantics, not the preparation brief's provisional
   45/60-second arithmetic.
3. Distinguish **never submitted**, **completed**, **confirmed stopped** and
   **uncertain**. A failed transport after submission is uncertain. A stop
   acknowledgment supplies termination evidence, not a successful read result.
4. Cover the process tree used by the fixed file scripts. Killing the parent
   shell, closing a socket, sending a signal, or receiving HTTP acceptance is
   insufficient. A wrapper that runs `timeout` is only a candidate until tested
   for child cleanup, late start, caller/node loss and supported guest images.
5. Prevent expired work from starting remotely after ownership has moved on.
   A local pre-dispatch clock check cannot alone rule out a delayed request.
   Define the provider-side start deadline or reconciliation mechanism and the
   clock assumptions it relies on.
6. Retain a durable execution barrier on unknown startup or termination. Another
   owner may recover that barrier after a lease expires, but expiry does not
   authorize conflicting lifecycle work. Recovery needs a confirmed terminal
   outcome or a provider-enforced bound whose expiry actually proves termination.
7. Never retry an uncertain start as a new command. Reconcile its original
   identity and preserve the sandbox incarnation through replacement/reuse.

A strict exclusion guarantee and unconditional finite reclamation cannot both
be inferred from a local timeout during an arbitrary provider partition.
Resolve that with a proven remote lifetime bound or retain uncertainty until
recovery. Do not describe lease CAS as fencing remote provider effects.

## Provider implementation work

- **Sprites:** repair and prove descendant termination; the live `:ok`
  counterexample rules out using today's kill-session acknowledgment as the
  whole execution barrier. Expose reliable execution identity from start.
  The pinned public command handle contains a stream `ref`
  and opaque `private` field, not a portable session ID. Cover start-with-lost-
  response, delayed start, command descendants and uncertain kill. Its current
  blocking collector and startup both need a single absolute deadline.
- **E2B:** the adapter already tags commands, but one-shot exec does not expose
  that identity for recovery and its timeout kills a local collector. Add a
  bounded execution/termination contract against the actual envd protocol and
  verify process-group completion; a sent signal alone is not confirmation.
- **Daytona:** the adapter passes timeout seconds to `/process/execute`.
  [Official documentation](https://www.daytona.io/docs/en/typescript-sdk/process/)
  says expiry terminates the command. Verify the deployed toolbox version's
  process-tree and late-dispatch behavior, and preserve uncertainty when its
  terminal response is missing. A one-shot response with no durable command
  identity is not enough for owner-loss recovery.
- **Runner:** fix timeout cancellation of descendants and bounded pipe draining
  in Fountain's Go daemon, then add the matching identity/recovery contract to
  `managoat_runner`. Validate both trusted-process and Firecracker guest modes;
  forwarding to the guest is not independent proof. Cover old-daemon behavior
  explicitly before claiming fleet-wide rollout safety.

[Sprites documents](https://sprites.dev/api/sprites/exec) that commands can
continue after disconnect and provides an explicit kill operation. Disconnect
lifetimes are not an absolute command deadline and must not be substituted for
one without proving the bound in all relevant connection states.

E2B's automatic `connect` and Daytona's automatic `start` are also relevant to
#2395. This pass exposes them but does not change that separate product contract
or infer a provider-level no-wake capability.

## Acceptance matrix and rollout

Run the same fixed-command cases on all providers: quick success, silent hang,
continuous stdout, continuous ignored stderr, a descendant keeping pipes open,
a descendant running after parent exit, caller loss, owner/node loss, lost start
response, delayed start, lost stop response, replacement identity, and recovery
after reconnect. Require both the local result and independent evidence of the
remote terminal state; record versions and elapsed bounds. Confirm the verifier
itself does not wake the sandbox when testing the separate no-wake promise.

Then integrate one Machines admission path for list/read/diff/status, using
fresh scoped state, the existing lease and durable lifecycle priority. Preserve
`destroying` intent regardless of lease age; keep provider I/O outside locks and
transactions. Add separate-database-connection and owner/inline contention
proofs, repeated polling with a waiting park/destroy, and cancellation that
cannot dispatch later. Do not accidentally turn lifecycle priority into an
unapproved permanent restriction on concurrent reads.

The Sprites live run establishes defects, not readiness. E2B and Daytona live
validation, the full failure matrix, and Firecracker guest validation remain
outstanding. Rollout remains gated on all supported providers. #2394 and #1715
remain open.
