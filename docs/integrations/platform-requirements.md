# Sandbox platform requirements

<!-- The ten requirement names are identifiers: exit-truth, replay-cursor,
     honest-listing, url-or-nothing and the rest. "Blocking", "Costly" and
     "Wanted" are priority values. "blocking" and "streaming" name the two
     exec paths, and "naming system", "provisioning", "billing" and
     "scheduling" are Technical Names. STE exempts a Technical Name from Rule
     3.4, and the linter has no vocabulary hook for that rule, so the exemption
     is declared for the page. -->

This page is for teams that build sandbox platforms. It defines the ten
capabilities Fountain needs to run long-lived, interactive agents safely.

For the interface that Fountain guarantees to operators, read
[The sandbox contract](sandbox-contract.md). To implement an adapter, read
[Add a provider](adding-a-sandbox-provider.md).

## The workload

An agent turn can run for hours. A person watches its output in real time and
can send more input while it runs. The next turn resumes on the same disk, so
that disk contains user work and agent state.

Fountain must also survive its own deploys. After a restart, the control plane
must find each live process, replay any missed output and continue the session.
It must know whether each command succeeded. It must also know whether the
provider deleted a missing sandbox or cannot reach it before the reaper acts.

Most sandbox APIs support short, disposable jobs well. The gaps appear at the
boundary between a long-lived command and the client that supervises it.
Fountain fills those gaps today with shell shims, journals, sentinels and local
registries. This page defines the native platform support that would let us
delete that code.

## Priorities

- **Blocking** means Fountain cannot meet its contract without an in-sandbox
  workaround.
- **Costly** means Fountain can operate, but with more code, weaker guarantees
  or manual work.
- **Wanted** means the absence removes a useful product capability.

| Requirement | Priority | Fountain fallback |
|---|---|---|
| [exit-truth](#exit-truth) | Blocking. | Write an exit-code sentinel from a shell wrapper, then poll for it. |
| [replay-cursor](#replay-cursor) | Blocking. | Journal output with `tee`, replay it with `tail` and remove duplicate bytes. |
| [detached-sessions](#detached-sessions) | Blocking. | Use the journal shim and maintain a session registry. |
| [absence-definitive](#absence-definitive) | Blocking. | Classify every provider error as definitive absence or transient failure. |
| [stdin-total](#stdin-total) | Costly. | Feed a private FIFO with `tail -f`; kill the tail process to close stdin. |
| [named-create](#named-create) | Costly. | Store a second identity in metadata and reconcile duplicate sandboxes. |
| [park-not-expire](#park-not-expire) | Costly. | Send heartbeats and configure missed heartbeats to park the sandbox. |
| [honest-listing](#honest-listing) | Costly. | Disable automatic cleanup and remove leaked sandboxes by hand. |
| [egress-deny](#egress-deny) | Costly. | Fail open and tell operators that the environment is not contained. |
| [url-or-nothing](#url-or-nothing) | Wanted. | Report `:unsupported`; agents cannot link to their previews. |

## Requirements

### exit-truth

**Requirement.** Emit exactly one terminal event for each command. Include the
true process exit code on both the blocking and streaming paths. Keep a command
failure distinct from a transport failure that ends the stream.

**Why.** Without a trustworthy verdict, Fountain can mark a failed setup as
complete. A fabricated exit code of 0 is worse than no verdict because the
control plane acts on it.

**Test.** Run `sh -c 'exit 3'` through both exec paths. Each path must report 3.
Then destroy a sandbox during a command. The client must report a transport
error, not exit 0.

### replay-cursor

**Requirement.** Keep an output journal for each session. Let a client read it
from byte zero or from a platform cursor. Keep stdout and stderr separate.

**Why.** A deploy can disconnect the process that reads a turn without ending
the turn. After reconnect, Fountain must add every missed byte to the transcript
exactly once. A fixed-size replay can begin mid-line and cannot guarantee that.

Fountain currently asks adapters to replay from byte zero because no integrated
platform supplies a cursor. The caller removes bytes that it already stored from
each stream.

**Test.** Read part of a session, disconnect, then resume from the last cursor.
The combined output must match one uninterrupted read byte for byte.

### detached-sessions

**Requirement.** Support three operations: start a detachable session, list the
sessions on a sandbox and rejoin a session by id.

**Why.** A control-plane restart must not end a turn. Fountain must discover the
processes that survived before it decides how to recover them.

**Test.** Disconnect the client during a command. List the sessions, rejoin the
command by id and receive its terminal event with the true exit code.

### absence-definitive

**Requirement.** Document which responses prove that a sandbox no longer
exists. A partition, throttle, expired credential or slow region must never
produce one of those responses.

**Why.** The sandbox disk contains persistent agent state. Fountain must keep a
temporary control-plane failure distinct from permanent absence before cleanup
can safely run.

This failure mode has caused data loss. A Fountain control-plane partition once
made nine live sandboxes appear absent, and the next sweep destroyed them.

**Test.** During an induced control-plane outage, no endpoint may return a
not-found response for a sandbox that still exists. Publish the complete set of
responses that are safe to treat as definitive.

### stdin-total

**Requirement.** A write to a process that has exited must return a distinct
`already exited` result, not a transport error. A separate close operation must
send EOF exactly once.

**Why.** Agent protocols send many messages to one process. A process can exit
while Fountain writes to it, so the race is part of normal input handling. A
channel that sends EOF after each write cannot carry the protocol.

**Test.** Start `cat`. It must exit only after the client closes stdin. A later
write must return `already exited`, not a transport error.

### named-create

**Requirement.** Accept a caller-defined identity at creation. Repeated or
concurrent creates with that identity must return the existing sandbox.

**Why.** A create request can succeed after the client times out. Without a
stable identity, the retry creates an orphan that Fountain pays for but cannot
address. Metadata can emulate identity, but it adds another naming system and a
duplicate-reconciliation loop.

**Test.** Send two concurrent creates with the same name. Both must return the
same handle, and the account must contain one sandbox.

### park-not-expire

**Requirement.** Supply a pause or stop state that keeps the filesystem at
storage-only cost. Do not destroy a parked sandbox on a TTL. If a TTL is
unavoidable, expiration must park the sandbox.

**Why.** Fountain parks idle sandboxes because the disk makes the next turn a
continuation. A destroy-on-TTL policy turns every long turn into a heartbeat
loop and turns one missed heartbeat into data loss.

**Test.** Write a file, park the sandbox, wait one week, resume it and read the
same file.

### honest-listing

**Requirement.** Make pagination explicit and finite. If the API cannot return
a complete account view, return an error instead of a successful partial list.

**Why.** Fountain compares the provider list with its database during cleanup.
An outage stops cleanup. A truncated list that appears complete can cause the
control plane to act on false information.

**Test.** Interrupt a paginated list on the server. The client must receive an
error, never a truncated collection that looks complete.

### egress-deny

**Requirement.** An empty allowlist must deny all outbound traffic. The policy
must be available per sandbox at creation on every plan tier, without manual
support work.

**Why.** Agents hold credentials and run text supplied by other people. Network
egress is the main exfiltration path. A tier-gated control leaves lower-tier
environments without the containment their configuration claims.

**Test.** Allow exactly one host. Connections to every other DNS name and raw IP
address must fail.

### url-or-nothing

**Requirement.** Return one browser-ready HTTP URL for each sandbox, or state
that the platform has no such concept. Opening the URL must not need a platform
credential.

**Why.** Agents often build a preview that a person needs to open. Fountain
cannot safely guess a hostname from a port. A guessed URL that does not resolve
is worse than an explicit unsupported result.

**Test.** Serve HTTP inside the sandbox. Open the reported URL in a browser that
has no platform account or credential.

## Current platform support

The table is a point-in-time measurement, not a vendor scorecard. We measured
Sprites, E2B and the self-hosted runner through their Fountain adapters in
August 2026. Render Sandboxes entered Early Access in September 2026. We
measured that API directly; no Render adapter exists yet.

| Requirement | [Sprites](sprites.md) | [E2B](e2b.md) | [Runner](runners.md) | Render (Early Access) |
|---|---|---|---|---|
| exit-truth | Yes | Yes | Yes | Yes for the client that owns the stream. Later readers see only the result that client reported. |
| replay-cursor | Partial. Replays the last 16 KiB and can begin mid-line. | No. Fountain adds a journal and replayer. | Yes | No. The documented endpoint is absent in production. |
| detached-sessions | Yes | No. Fountain emulates sessions. | Yes | Partial. The process survives, and the API lists executions, but supplies no output or verdict. |
| absence-definitive | Undocumented | Undocumented | Yes. Offline states are transient by construction. | Partial. A terminated sandbox remains readable, but missing entitlement and missing sandbox both return 404. |
| stdin-total | Yes | Yes | Yes | No stdin API. |
| named-create | Yes | No. Fountain stores names in metadata. | Yes | No names or metadata. |
| park-not-expire | Yes. Scales to zero. | Partial. Pause keeps the disk, but a TTL remains active. | Yes | No. Lifetime expiration destroys the sandbox. |
| honest-listing | Yes. Uses continuation tokens. | Not measured | Yes | Yes. Cursors are explicit, and an excessive limit returns an error. |
| egress-deny | Partial. Fountain's translation fails open. | Yes | No by design. The user owns the machine. | Partial. Deny-all works, but allowlists do not exist. |
| url-or-nothing | Yes | No. Supplies a hostname per port, not a URL. | No | No |

Treat every negative result as a prompt to verify both the platform and the
adapter. This table once said that Sprites failed `exit-truth`. Sprites sent the
correct one-byte exit field, but the Elixir client tried to read four bytes and
substituted 0 when the frame did not match. [Issue
#880](https://github.com/managoat/fountain/issues/880) fixed the adapter.

The Render column has the opposite limitation. Direct API tests remove adapter
errors, but they do not expose failures that appear only during long production
runs.

The [self-hosted runner](runners.md) is an existence proof, not a peer vendor.
It meets most of these requirements because Fountain controls both ends of the
protocol.
