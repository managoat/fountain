---
type: ADR
title: "A sandbox's files and git diff over the API, and no exec"
description: "Apps that watch an agent get four read-only full-scope requests on a sandbox (listing, file, git status, git diff), redacted, confined, and never resuming a parked sandbox; a raw exec endpoint is refused."
tags: [api, sandbox, security, apps]
status: stable
adr: "0039"
adr_status: "Accepted"
date: 2026-09-02
generated: { by: claude-fable/5.1, at: 2026-09-02T02:00:00-04:00 }
verified: { by: claude-opus/5, at: 2026-09-04T12:00:00-04:00 }
---

# 0039 — A sandbox's files and git diff over the API, and no exec

**Status:** Accepted, 2026-09-02. Built in the same PR: `Fountain.SandboxFiles`,
`FountainWeb.SandboxFilesController`, the three routes, the SDK's
`sandboxFiles` / `sandboxFile` / `sandboxDiff` (1.15.0). A fourth route,
`git status`, was added on 2026-09-04 under decision 2's own procedure — see
the amendment at the end. A second amendment (2026-09-18) records how a read
is admitted against a park or a destroy of the same machine (#2394). A third
(2026-10-14) moves the configuration writes a sandbox token could reach behind
full scope. A 2026-10-15 addendum narrows decision 6: a read never resumes
a sandbox Managoat parked, but it may wake one the provider put to sleep by
itself (#2395). Nothing described here is unbuilt.

## Context

Two of the apps built on the API (ADR 0003, [0021](0021-oauth-for-first-party-apps.md))
asked for "sandbox exec and file APIs". Both are apps that watch an agent
work, and the transcript is not always enough: the app wants to show the
file the agent just wrote, the tree it is working in, and what changed in
the repository since the turn began.

What the codebase already says about that request:

- **The seam has exec and no read.** `Managoat.Sandbox` ([0018](0018-sandbox-provider-abstraction.md),
  [0037](0037-component-libraries.md)) requires `exec/4`, `spawn/4` and
  `write_file/4` of every adapter and has no `read_file`, `list_dir` or
  download callback. Fountain reads a file out of a sandbox by `exec`ing
  `cat` — the E2B adapter's only read primitive is internal, to poll an
  exit-code file. Exec is therefore cheap to expose, and a file API is the
  one that would need new seam work across four adapters and the runner
  daemon's protocol.
- **Nothing under `fountain_web/` touches a sandbox.** Every side effect
  goes through `Fountain.Conversations` and its server, which is what makes
  audit ([0013](0013-audit-trail.md)) and redaction hold by construction.
- **There are two API key scopes, `full` and `sprite`,** and everything
  under the plain `:api` pipeline is reachable with a `sprite` key — the
  token a conversation hands its own sandbox. That is deliberate (the
  bundled `fountain` skill fans out sub-agents) and it is the fact that
  decides the shape of anything that reads a disk.
- **A sandbox is keyed by `{agent, environment, vault}`** ([0023](0023-persistent-agent-sandbox.md))
  precisely so that a compromised home never holds two identities'
  credentials. `.env` on that disk is the identity's secrets in plaintext;
  the callback token and the broker session token are process-only and
  never reach it (`Fountain.Conversations.Identity`).
- **Redaction is applied in exactly one place,** `Conversations.log!/1`.
  Raw exec output and raw file bytes never pass it.
- **Credits burn on turns** ([0031](0031-credits-are-the-product.md)).
  `Billing.check_spend/1` gates conversation creation, attach, wake and
  every turn, and nothing below that. An exec that opens no turn burns
  nothing while costing provider time.
- **The broker's protection is network-shaped** ([0019](0019-egress-credential-brokerage.md)):
  a placeholder is worthless off the box because egress is pinned to the
  proxy. A read channel out of the box is one the proxy does not sit in
  front of.
- **A runner sandbox is a directory on the user's own machine** in trusted
  mode with no isolation ([0022](0022-self-hosted-runner-provider.md)).

## Decision

1. **Read-only requests, on the sandbox, not the conversation.**
   `GET /api/sandboxes/:id/files` (a directory), `/file` (one file's
   bytes), `/diff` (`git diff`, with `staged` and `ref`) and, since the
   2026-09-04 amendment, `/git-status`. They are
   addressed by sandbox because on a persistent home the disk is shared by
   every conversation of the identity, and a conversation-scoped read
   would mislead the app about what it is looking at.

2. **No exec.** The three operations are fixed scripts in
   `Fountain.SandboxFiles`; the caller chooses a path and a few flags,
   never a command. A raw exec endpoint would be a second I/O path beside
   ACP ([0014](0014-agent-client-protocol.md)) that routes around the
   governance proxy ([0016](0016-governance-as-an-acp-proxy.md)); it would
   be unmetered under 0031; its output would never pass redaction; on a
   shared home it could read every other conversation's process
   environment, which is exactly what `Identity` keeps out of `.env`; and
   on a runner it would turn a leaked API key into a shell on the user's
   laptop. If a further purpose-shaped read is wanted (`git status`, a
   test run's report), it gets the same treatment: a fixed script, a
   named endpoint, this ADR amended.

3. **Full scope only.** The routes sit behind `require_full_scope`, with
   the egress log (#1152). A `sprite` key must never read another sandbox
   of the tenant, whose disk was built from a different vault — that is
   the cross-identity leak 0023's key exists to prevent, and it would
   otherwise be one HTTP call from inside any sandbox.

4. **Confined to the home and the workspace.** A path resolves against the
   agent's working directory (`Managoat.Runtimes.ACP.cwd/1`) and must be
   `/home/sprite`, that directory, or inside one of them
   (`422 path_outside_sandbox`). On a hosted provider this costs the
   caller `/etc`, which "watching an agent" does not need; on a runner it
   is what keeps the API off the rest of the user's filesystem.

5. **Redacted like the transcript.** Every byte that leaves — file
   content, diff text, a failing command's output — passes the same
   replacement `Conversations.log!/1` applies: the values of the
   identity's environment and vault (decrypted for the request, eight
   bytes or longer) plus whatever a live `ConversationServer` registered,
   which is how the inference credential and the callback token are
   covered. Without this, the `.env` on that disk would be readable back
   through a third-party app holding the user's key.

6. **Never a wake.** Only a `ready` sandbox answers; a `suspended` one is
   `409 sandbox_not_ready` and stays parked. A read that resumed a sandbox
   would cost provider time outside any turn, with nothing in 0031 to
   charge it to; a prompt is the door that wakes, and it is gated.
   [0063](0063-a-parked-sandbox-answers-from-its-snapshot.md) answered a
   parked sandbox from the snapshot its park took from 2026-10-02 until it
   was retired on 2026-10-14; a parked sandbox is `409` again. Narrowed on
   2026-10-15: a read on a `ready` row may still wake a machine the provider
   put to sleep by itself. See the addendum of that date.

7. **Over `exec`, not a new callback.** The scripts run through
   `Managoat.Sandbox.exec/4`, which every adapter already implements, with
   the path as a positional parameter (`bash -c SCRIPT NAME ARGS…`) so a
   filename is data whatever it contains, and paths crossing
   `Managoat.Sandbox.host_path/2` so the runner's `/home/sprite` mapping
   holds. Bytes travel base64-encoded from inside the sandbox so they
   survive whichever transport an adapter streams stdout over. Adding a
   `read_file` callback would have meant four adapters, the runner
   daemon's protocol, and new public surface on a library heading for hex
   (0037), for a read the existing primitive already serves.

8. **Bounded.** A file read returns at most `max_bytes` (default 256 KiB,
   cap 4 MiB) and reports `size` and `truncated`; a listing returns at most
   2,000 entries; a diff is capped the same way; every script has a
   30-second timeout. Reads are not audited (0013 audits mutations) and
   not gated by `check_spend/1` (they spend nothing: the sandbox is
   already running and is not woken; the 2026-10-15 addendum records
   when a provider wakes it anyway).

## Consequences

- The two apps get what they need — a file tree, a file, a diff — through
  three SDK calls beside `sandboxes()`, and nothing they did not ask for.
- The one new attack surface is a read channel out of the sandbox. It is
  bounded by full scope, the path confinement and redaction, and it is
  the user's own disk. What it does not cover: a secret an agent wrote to
  disk *itself* is not in the redaction set (the same limit the transcript
  has), and a brokered API's response, fetched through the proxy and
  written to a file, is readable through this API by the same user who
  could have asked the agent to print it.
- Every provider is covered on the day it ships, including the runner,
  without touching `managoat_sandbox` or `managoat_runner`.
- The `api_spec_test` route walk and the SDK freshness check mean the
  routes could not land undocumented; the SDK's resource and the Swift
  client's vendored spec are hand-written follow-ups by design.

## Alternatives considered

- **A raw `POST /api/sandboxes/:id/exec`.** Refused, for the five reasons
  in decision 2. The honest version of "we need exec" is a list of the
  commands the app would run, and that list is a set of named endpoints.
- **`read_file` / `list_dir` callbacks on the seam.** The cleaner
  architecture, and the right move if a provider ever offers a file API
  that is materially cheaper than a process. Deferred: it is four adapters
  and a daemon protocol change for no behaviour the scripts do not
  already deliver.
- **Conversation-scoped routes** (`/api/conversations/:id/files`).
  Rejected because the disk is the sandbox's, not the conversation's
  (0023), and because a conversation's own `sprite` key could then reach
  the route by the plain `:api` pipeline unless it, too, were full-scope —
  at which point the conversation adds nothing but a misleading name.
- **Allowing any absolute path.** Rejected for the runner's sake, and
  because nothing an app watching an agent needs lives outside the home
  and the workspace.
- **Waking a parked sandbox on read.** Rejected: unmetered provider time,
  and a surprise to a user whose parked home starts costing money because
  a dashboard polled it.

## Amendment (2026-09-04): `git status`, the read a diff cannot serve

Decision 2 named `git status` as the example of a further purpose-shaped
read, and set the procedure for one: a fixed script, a named endpoint, this
ADR amended. This is that amendment. Nothing about the shape of the decision
changes; the fourth request is bound by every rule the first three are.

**Why a fourth request rather than a flag on `/diff`.** `git diff` compares
tracked content. A file the agent created and never staged is not in the
index and not in any commit, so no combination of `staged` and `ref` shows
it — the file is invisible to the endpoint that exists. That is the common
case for an app that watches an agent work: the agent writes a new file, and
the app that renders "what changed" renders nothing. Deletions are already
visible (a tracked file's removal is a diff hunk), so the gap is precisely
the untracked half, and `git status` is the command that closes it.

**`/git-status`, not `/status`.** A sandbox has a `status` of its own —
`ready`, `suspended` — and it is a field on the sandbox resource that
decision 6 turns on. A route named `/status` under `/api/sandboxes/:id`
would read as that field to everybody who met it before this file.

**Decisions it inherits unchanged.** Full scope (3), path confinement (4),
redaction (5) — a path is data the agent chose, so it passes the same
replacement the transcript's bytes do — never a wake (6), over `exec` with
the path as a positional parameter (7), and bounded (8): at most 2,000
entries, the same 30-second timeout, no audit and no `check_spend/1`.

Confinement (4) covers the path the caller never names. Both git reads
find their repository with `git rev-parse --show-toplevel`, which walks up
the ancestors of the request path, so the root it lands on is checked
against the same home and workspace and a root outside them is
`not_a_repository` rather than a listing of it. On Sprites no ancestor of
`/home/sprite` is a repository; on a self-hosted runner (ADR 0022) a
sandbox is a directory under the operator's home, and an operator whose
`$HOME` is a dotfiles repository is exactly the case this refuses.

**What is new, and what it costs.**

- The response is one entry per changed path, with git's two porcelain
  columns read separately (`index` and `worktree`), the rename origin, the
  branch, and paths relative to `repo_root` rather than to the sandbox home.
  A caller that mixes the two path shapes will ask `/file` for the wrong
  thing, which is why the field is named `repo_root` and documented twice.
- One flag, `untracked`, passing `--untracked-files` through as `normal`,
  `all` or `no`. It is the one knob that decides whether a new directory
  arrives as one entry or as everything beneath it, and an unignored build
  tree makes that the difference between 1 entry and 40,000. The value never
  reaches the command line: the script maps it to a fixed flag with a `case`.
- `--no-optional-locks` matters more here than for a diff. A plain
  `git status` refreshes the index, so without it a read takes `index.lock`
  and breaks the agent's own commit. The read that observes the work must not
  be able to stop it.
- An internal byte cap (1 MiB) sits under the entry cap, because `-uall` on a
  large tree is read into memory before anything counts it. A record the cap
  cuts in half is dropped rather than half-read, and `truncated` says so.

**What it does not add.** No new error, no new exit code, no seam change, no
adapter change: the script reuses `path_not_found`, `not_a_directory` and
`not_a_repository`, and runs through `Managoat.Sandbox.exec/4` like the other
three. The endpoint declares its own 403 rather than take a line in the
schema guard's allowlist, which is a ratchet for the debt #1432 already owes.

## Amendment (2026-09-18): a read is admitted against the machine's owner

Decision 6 said a read never wakes a parked sandbox, and it checked that on
the row the controller had fetched. That check was not atomic with the exec:
a park or a destroy committing between the two was not seen, so a read could
run against a machine being suspended or deleted (#1715). #2394 closes the
part of that gap that Fountain controls. The decision itself is unchanged.

- **Admission.** `Fountain.Machines.Reads` re-reads the row under the
  per-sandbox advisory lock that a lease claim takes (ADR 0058). A row that
  is not `ready` is still `409 sandbox_not_ready`. A row that carries a
  transition stamp or a live lease is now `503 sandbox_unavailable`, with a
  `Retry-After`. The response was already declared on all four routes, for an
  unreachable provider.
- **Exclusion.** An admitted read writes a `sandbox_reads` row with a
  40-second window. A park or a destroy that claimed the machine after it
  waits for the read before its provider call. No read is admitted while the
  operation's lease is live, so the wait is bounded by one window. A client
  that polls cannot keep a machine awake.
- **The window is enforced locally.** The exec runs in a task that is killed
  at a cutoff five seconds before the window ends, whether or not its caller
  is still alive, because the adapter's `:timeout` bounds only output
  collection.

What this does not promise: whether a provider that suspends a machine by
itself wakes it for an exec. That question stays with #2395, under #1715,
and decision 6 is not restated here on the strength of this change.

## Amendment (2026-10-14): a sandbox token cannot rewrite what a launch runs

The Context above records that everything under the plain `:api` pipeline is
reachable with a `sprite` key, so that the bundled `fountain` skill can fan
out sub-agents. That reach included the writes on agents, environments and
vaults. An agent's `sandbox_provider`, `runtime` and `runtime_command` are
ordinary fields of its changeset, and an environment carries a setup script.
A prompt-injected agent in a hosted sandbox could therefore create or patch
an agent with `sandbox_provider: "runner"`, `runtime: "acp"` and any command,
and then start it with `POST /api/conversations`. On a trusted-mode runner
(ADR [0022](0022-self-hosted-runner-provider.md)) that is a shell on the
owner's machine from a bearer token, which is the outcome decision 2 refuses
for exec. No exec endpoint was needed.

**The rule.** A `sprite` key may read what a launch is built from, and run
it. It may not change it. These routes now sit behind `:require_full_scope`
and answer `403` with `reason: "insufficient_scope"` and
`required_scope: "full"`:

- create, update and delete on `/api/agents`, and the avatar writes;
- create, update and delete on `/api/environments` and its secrets;
- create, update and delete on `/api/vaults`, its secrets, and
  `/api/vaults/:id/copy`;
- `POST /api/apply`, which writes all three;
- `POST /api/conversations/:id/reapply`. Its operation had declared
  "Sprite keys may not reapply a conversation" since #1565 (#1892), but no
  gate enforced it. A reapply can move a conversation onto another agent,
  environment or vault of the account.

**What stays open.** Reads of agents, environments, vaults and their secret
metadata stay open, because the `fountain` skill lists `/api/agents` from
inside a sandbox. Starting, prompting, streaming and ending conversations
stay open too. `POST /api/conversations` accepts no `sandbox_provider`,
`runtime`, `runtime_command` or setup script: the provider comes from the
agent (`Conversations.resolve_sandbox_provider/1`). Its `environment_id` and
`vault_id` must be on the agent's allowlists, and `permission_policy` may only
narrow (ADR [0016](0016-governance-as-an-acp-proxy.md)). With the writes
gated, a sandbox token can launch only what the owner configured. A guest
attach already needed full scope (ADR [0023](0023-persistent-agent-sandbox.md),
2026-09-27). The team routes (`/api/team`, its schedules and messages) run an
agent the owner configured on the same allowlists, and stay open.

**What it costs.** The bundled `create-team` skill created agents with the
sandbox token. It now writes the roster as a `fountain apply` manifest for the
person to apply with their own login, and reads the team back afterwards. An
audit row from a refused attempt keeps `actor: "sprite"` (ADR
[0013](0013-audit-trail.md) §4), so a run of refused writes from a sandbox
stays visible on the trail.

This amendment changes no decision above. It closes the route that made
decision 2's refusal of exec moot.

## Addendum — 2026-10-14: no spend gate, fewer adapters

Two facts in *Context* (and the decisions that lean on them) no longer hold.
Neither changes a decision.

- **There is no `Billing.check_spend/1`.** Credits and `Fountain.Billing`
  were removed on 2026-10-12 and [0031](0031-credits-are-the-product.md) is
  retired, so nothing gates a turn on spend. "Unmetered under 0031" in
  decisions 2 and 6 now reads as unaccounted: an exec outside a turn costs
  provider time that no turn records. The reads still open no turn, and
  decision 6 still never wakes a parked machine for one.
- **The seam has two provider adapters and the runner**, not four adapters:
  `Managoat.Sandbox.Sprites`, `Managoat.Sandbox.E2B` and
  `Managoat.Runner.Adapter` (`config/config.exs`). The Daytona adapter
  was removed with opencode (#2613), and Render's
  ([0040](0040-render-sandboxes.md)) was never written. A file API would still need seam
  work in each of them, so building the reads over `exec` stands.

## Addendum — 2026-10-14: reapply is removed

`POST /api/conversations/:id/reapply`, one of the full-scope writes the
amendment above lists, is removed (#2676) and answers 404 to every scope. The
rest of that list stands.

## Addendum — 2026-10-14: the self-hosted runner is removed

[0071](0071-hosted-sandbox-providers-only.md) removes the runner provider
(#2676). The runner-specific reasons above (a leaked key becoming a shell on
the user's machine, the `/home/sprite` mapping, a dotfiles `$HOME` above the
sandbox) are history, as is the runner scenario in the sandbox-token
amendment above; its gates stay. The seam now has the two adapters,
`Managoat.Sandbox.Sprites` and `Managoat.Sandbox.E2B`. The paths still cross
`Managoat.Sandbox.host_path/2`, and the confinement checks are unchanged.

## Addendum — 2026-10-14: one sandbox per conversation

[0023](0023-persistent-agent-sandbox.md) is superseded by
[0073](0073-one-sandbox-per-conversation.md) (#2676). A sandbox now belongs to
exactly one conversation, so the files a read returns are that conversation's
alone. A relative path resolves from that conversation's runtime, since the
sandbox no longer records a runtime of its own.

## Amendment — 2026-10-15: the team routes and `create-team` are gone

[0074](0074-remove-the-team.md) removed the team. The 2026-09-27 addendum's
sentences about the team routes staying open to a sandbox token, and about
the bundled `create-team` skill writing a roster as a manifest, describe
code that no longer exists. The rest of that addendum stands.

## Addendum — 2026-10-15: admitted reads are held in memory

The 2026-09-18 amendment's exclusion wrote a `sandbox_reads` row per admitted
read so that a park or destroy on one node could see a read admitted on
another. Since [0072](0072-fountain-runs-as-one-node.md) Fountain runs as one
node and two BEAMs never overlap, so every read a drain can be asked about was
admitted in the same BEAM, and one admitted by an earlier boot died with it.

`Fountain.Machines.Reads` now records an admitted read as an entry in a named
ETS table owned by `Fountain.Machines.Reads.Table`, with an expiry on the
node's monotonic clock. Nothing else changes: the admission still re-reads the
row under the per-sandbox advisory lock and refuses on a status, a stamp or a
live lease; it inserts the entry before it releases that lock, so a claim that
takes the lock next is guaranteed to find it; the drain waits for unexpired
entries; the window, the cutoff and the 503 are the same. An entry is bounded
by its expiry and not by its caller's process, because the read's task can
outlive a caller that was killed. The table is unwritten from this release and
dropped one release later, by migration `20261017120000`.

## Addendum — 2026-10-15: a read may wake what the provider put to sleep

Decision 6 promised that a read is never a wake. Managoat can keep half of
that promise and not the other half, so the promise is narrowed (#2395, under
#1715; Jake's decision of 2026-10-15).

**What still holds.** A read never resumes a sandbox Managoat parked, and
never races Managoat's own park or destroy of it. A `suspended` row is
`409 sandbox_not_ready`, decided on the row read under the machine's lock,
and a machine that a park or destroy holds or has stamped is
`503 sandbox_unavailable`. A park or destroy waits for a read admitted before
it (the 2026-09-18 amendment, `Fountain.Machines.Reads`).

**What no longer holds.** A read admitted on a `ready` row runs through
`Managoat.Sandbox.exec/4`, and both providers wake a machine that they put to
sleep themselves when it is asked to run a command:

| Provider | When a `ready` row's machine is asleep | What an exec does | A no-wake exec? |
|---|---|---|---|
| Sprites | Routinely. A sprite scales to zero on its own when nothing runs in it, and Managoat's `suspend/1` is a no-op, so a sprite under a `ready` row is often asleep. | Wakes it ("when you run a command … it wakes up"). The sprite sleeps again on its own. | None. The exec endpoint takes only the sprite's name. |
| E2B | When its timeout lapsed without a heartbeat. The adapter creates sandboxes with `autoPause: true`, so a lapsed timeout pauses rather than kills. | The adapter finds the sandbox paused and calls `/connect`, which resumes it with a 30-minute timeout, before it runs the command. | None. Running a command needs a connection, and a connection resumes a paused sandbox. |

This is the same for all four reads (listing, file, `git status`, `git diff`):
each is one fixed script over `exec`. `GET /api/sandboxes/:id` and its
`status` are read from Managoat's database and never call the provider.

A preflight probe does not close this. Asking the provider whether a machine
is awake and then running the script is two calls, and the provider can put
the machine to sleep between them, so it would narrow the window without
making the read atomic. Managoat does not probe, and does not describe a
probe as enforcement.

**What it costs.** The machine runs, and the provider bills, from the wake
until the provider puts it to sleep again: on Sprites its own idle sleep, on
E2B the 30-minute timeout `/connect` granted, or Managoat's idle park if that
comes first. A read is not turn activity, so it does not postpone Managoat's
idle park (`SANDBOX_IDLE_TIMEOUT_MINUTES`). A client that polls the files API
can therefore keep a machine awake until that park, and no longer. With the
idle timeout off (`0`), nothing bounds it. The time is outside any turn, and
no turn records it (the 2026-10-14 addendum on spend).

**Why not strict no-wake.** Neither provider documents an operation that runs
a command only if the machine is already awake, and a check by Managoat cannot
be atomic with the provider's own sleep. Strict no-wake would mean refusing
every read on Sprites that might find a sleeping sprite, which is most reads
outside a turn, or a new provider capability that does not exist. The cost of
the narrower promise is bounded by the idle park on the default settings, and
the reads stay useful.

**How it is checked.** The lifecycle half is proved by Managoat's tests: a
`suspended` row is refused with no exec, and the admission and drain tests in
`Fountain.Machines.Reads` cover the park and destroy orders. Those tests mock
`exec/4`, so they prove nothing about the provider's own sleep and wake. That
half is the provider's documented behaviour, recorded in the table above as
of this date, and is not tested here.
