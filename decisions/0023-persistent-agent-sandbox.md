---
type: ADR
title: "A persistent sandbox per agent, offered beside the sandbox-per-conversation model"
description: "Built 2026-08-24 (#1057–#1068). Adds a second sandbox mode, chosen per launch and defaulted per agent, where one long-lived sandbox serves many conversations of an agent (the 'grokbot' shape), with turns running concurrently where the runtime allows (amended 2026-08-23); keeps the per-conversation mode as the default; names the seven places the code hard-codes 1:1 today. Amended 2026-09-11 (#1565): a home's identity key moves through one narrow door, the reapply action, which refuses any selection that would change the build inputs, the runtime, or a cotenant's configuration. Companion design note: #805."
tags: [sandbox, lifecycle, conversations, product]
status: stable
adr: "0023"
adr_status: "Accepted"
date: 2026-08-17
generated: { by: human:jhgaylor, at: 2026-09-11T12:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-09-11T12:00:00-04:00 }
stale_after: 2027-02-01
---

# 0023 — A persistent sandbox per agent, beside the sandbox-per-conversation model

**Status:** Accepted — built 2026-08-24. The "what breaks today" survey below
describes `main` as it was on 2026-08-21; every item in it has since been
fixed by the gates listed under **Outcome**. The decision text is kept as
written (with its 2026-08-23 amendment); where the code differs from it, the
outcome section says so.
**Date:** 2026-08-17 (amended 2026-08-18: mode is chosen per launch and
defaulted per agent, not fixed per agent; the machine carries a lease/refcount;
`sandbox_id` attach — see #805 for the holistic picture this converges on)

**Amended 2026-08-23 — turns run concurrently, not serialized.** The target
is a computer with several agent processes on it at once, each its own
conversation with its own transcript — not the "room" of #1043 (a shared
transcript, many agents), and not the one-turn-at-a-time lease the 2026-08-18
draft proposed. A survey of `runtimes/acp.ex` and `runtimes/layout.ex` found
that the shared-cwd / shared-sqlite / shared-port problems the lease existed
to sidestep belong to two runtimes, not to the machine: claude and codex run
one adapter process per connection with sessions keyed by explicit id and
coexist on one disk the way several terminals do on a laptop; opencode starts
an HTTP server per process over one sqlite store, and gemini's session store
is consolidated at the end of every turn. So step 4 is now a per-runtime turn
capacity enforced by a small per-sandbox process that serializes *machine
operations* only, and the open questions on concurrency, ceiling, identity
key and attach are resolved below. The same amendment records where this
cuts across #817, whose approved plan assumed one adapter per sandbox.

**Renumbered 2026-08-21:** this ADR was drafted as 0021 on 2026-08-18 and lost
the number to [0021](0021-oauth-for-first-party-apps.md) (OAuth for first-party
apps), which was opened later the same day and merged first. Line references in
the survey below were re-checked against `main` on the same date. Anything
citing "ADR 0021" for a persistent sandbox — #793, #805 — means this file.

**Amended 2026-09-11 — a home's identity key moves, through one narrow door.**
The text below resolves the identity key as fixed, on the grounds that "a
machine built from one environment is not a machine built from another, and
re-materializing in place is not built". #1565 builds one door through that:
`Fountain.Conversations.reapply_conversation/3` re-selects a conversation's
Agent, Environment and Vault and writes the new triple onto the sandbox row it
is already running, keeping the disk. The same stack puts it on the API as
`POST /api/conversations/:id/reapply`. The reasoning that held the key fixed is
kept rather than reversed, and it is what the door refuses on:

- **The build inputs must be unchanged.** `sandboxes.build_fingerprint` records
  a digest of what provisioning turned into filesystem state — packages,
  repositories, the setup script, the network policy. A selection whose digest
  differs is refused with `{:rebuild_required, field}`, so a machine built from
  one environment still never becomes a machine built from another. What may
  move is everything that is process environment or a file: variables, vault
  values, the system prompt, skills, `.mcp.json`. The reattach path has
  rewritten those on every wake since #848, so this is an established mechanism
  rather than a new one.
- **The runtime must be unchanged.** The ACP adapter is installed before the
  network policy that would now block installing another.
- **The machine must have no cotenants.** Skills, the instructions file and
  `.mcp.json` live at per-sandbox paths, so reconfiguring a shared machine
  would reconfigure it for conversations nobody asked about. A shared home
  accepts only the selection its cotenants already have, which is a refresh.

Two consequences for the model below. The lifecycle row for "vault or env
changed" is no longer destroy-the-home unconditionally: a change that leaves
the build inputs alone is applied in place instead, and the row is corrected.
And a home's identity is now mutable, so the partial unique index on
`(user_id, agent_id, environment_id, vault_id)` is load-bearing on update as
well as on insert — a reapply onto a triple that already has a home comes back
as a changeset error on `:home` and rolls back, rather than producing a second
home for one identity.

Turn admission is fenced against this with `conversations.configuration_revision`:
a server that has not read the committed selection cannot open a turn on it.

**Companion:** #805 is the "if we had designed it this way from the start"
sketch — the sandbox as a first-class machine, a conversation as a binding of
an agent to one. This ADR is the incremental proposal; #805 is what it should
be measured against.

## Outcome (2026-08-24)

Shipped as seven gates, one PR each, in dependency order:

| gate | what | PR |
|---|---|---|
| amendment | turns run concurrently per runtime capacity, not behind a lease | #1057 |
| 1 | per-process identity env and sessions tagged with the conversation (`Fountain.Conversations.Identity`) — steps 2 and 3 | #1058 |
| 2 | capacity (`Runtimes.ACP.concurrency/1`), the guarded live terminate, idle over the union of activity, `{:machine_gone, …}` to every co-tenant — steps 4, 5 and 7 | #1061 |
| 3 | `sandbox_id` attach on `POST /api/conversations`, `GET /api/sandboxes[/:id]`, `sandboxes.agent_id`/`vault_id`, SDK 0.1.6, `fountain run --sandbox` — step 1 (attach half) and step 8 | #1064 |
| 4 | turn hours summed per turn (`turn_seconds`) beside union `busy_seconds`; ADR 0026 addendum — step 6 | #1065 |
| 5 | a wake onto a fresh sandbox takes the machine's co-tenants along — step 1 ("wake stops repointing") | #1067 |
| 6 | `sandbox_mode` on the agent and on the launch, `home_or_new`/`_unsafe_find_home`, the partial unique index (`NULLS NOT DISTINCT`), home kept on terminate, parked at the ceiling, destroyed with its agent; SDK 0.1.7, `fountain run --sandbox-mode`, the agent form — steps 1, 5 and 8 | #1068 |
| 7 | live smoke against production (below) | — |

**Where the code differs from the text above.**

- There is no `SandboxServer` process. The machine-operation lock is a
  per-sandbox Postgres advisory lock taken by the conversation that needs it
  (`Conversations` around `pg_advisory_xact_lock`), the refcount is the
  conversation rows on the sandbox, and the idle clock is
  `SandboxReaper.last_activity_at/1` over all of them. Each
  `ConversationServer` keeps its own adapter, key and transcript exactly as
  step 4 says; only the coordinator is a lock plus a query rather than a
  registered process. Revisit if the handle and sprite env ever need to
  move into one owner. **Revisited 2026-09-16:**
  [0058](0058-the-machine-has-one-owner.md) proposes that owner, a
  per-sandbox process backed by a durable lease, and names the fences built
  in its absence as what it replaces.
- At capacity a turn is refused (`sandbox_at_capacity`); the `queued` stage
  of the original step 4 was dropped with the lease and is not built.
- Checkpointing (Consequences, "becomes meaningful"): a home is
  checkpointed when it parks, behind `CHECKPOINT_CREATION_ENABLED` (#1073),
  and the id is on `GET /api/sandboxes/:id`. A Sprites checkpoint is scoped
  to the sprite that made it and the SDK cannot create a sprite from one, so
  it rolls a home back and does **not** feed the `{:machine_gone, …}`
  re-provision; a machine that is gone is rebuilt from environment, vault
  and repositories. There is no retention: every park adds one.
- The continuous-run ceiling (0017) is **off by default** since #936's
  fix (the PR after #1069). An operator who sets `SANDBOX_MAX_LIFETIME_HOURS`
  gets the table's interim behaviour: a home at the ceiling is parked, not
  destroyed (`Lifecycle`); an ephemeral sprite is destroyed.
- Every step 8 door takes the override since #1070: `POST /api/conversations`,
  `fountain run`, the SDK, the agent form, `fountain acp` (`--sandbox-mode` /
  `--sandbox`, and `sandboxMode` / `sandboxId` in `session/new` `_meta`),
  the Buzz identity's `sandbox_mode`, and the `fountain` skill through
  `FOUNTAIN_SANDBOX_ID`. Channel resume takes the agent's default, as the
  step says. The conversations app shows no "home" badge;
  `GET /api/sandboxes/:id` is the sandbox's detail, and the on-demand reset
  the step-5 table names is `DELETE /api/sandboxes/:id` plus
  `fountain sandbox reset` (#1077).
- The step-5 table's "vault or env changed" row was half-built until #1084:
  deleting the agent destroyed its homes (#1068), but moving the agent's
  `environment_id`, or deleting the environment or vault the key names, left
  the home `ready` under an identity nothing looks up. All three now retire
  the affected homes through the same path as the on-demand reset, with the
  cause on each transcript and in the audit row
  (`environment_changed` / `environment_deleted` / `vault_deleted`), and are
  refused with `sandbox_mid_turn` while a conversation on one runs a turn.
  The two deletion doors were worse than an orphan: `sandboxes.environment_id`
  and `sandboxes.vault_id` are `ON DELETE SET NULL`, so a home left behind
  became the *no environment* or *no vault* home for its identity — the next
  launch that named neither landed on a disk still holding the deleted
  secrets — or collided with `sandboxes_home_identity_index` and failed the
  delete with a constraint error. Retiring the homes before the row goes is
  the same ordering `delete_agent/2` already used.

**Gate 7, run 2026-08-24 against production** (server `sha-94b6022f`,
Sprites, a throwaway `claude` agent on haiku with no environment or vault):

- First persistent launch provisioned one sandbox row (`mode = persistent`,
  `agent_id` set); a second launch attached to it without provisioning —
  one `sandboxes` row for three conversations.
- Conversation B read the file conversation A wrote and appended to it:
  one disk.
- A turn on A and a turn on B, each `sleep 20`, started together and ended
  within one second of each other — concurrent, not serialized — and each
  transcript carried its own `FOUNTAIN_CONVERSATION_ID`.
- After `kubectl rollout restart` of the server (what a deploy does), both
  conversations reattached to the same sprite (`reattach` stage,
  `no_running_turn`) and the file had every line: nothing re-provisioned.
- Terminating B left the sandbox `ready`; a third conversation landed on
  it and read three lines.
- Deleting the agent terminated the home (`204`, row `terminated`).

**Wake policy, decided 2026-08-24 (#1072):** a prompt to *any* conversation
on a parked home wakes the machine — a Buzz message, a schedule firing, an
API prompt, an AG-UI run all go through `ConversationServer.send_prompt/4`,
and that is the one door — and it wakes it for that conversation alone. A
co-tenant's server comes back on its own next prompt, which attaches to the
machine that is already awake (no second resume, no new row). The idle clock
is the union of every conversation's activity, so a wake for one keeps the
machine up for all. There is no "owner's turns only" mode: an agent that
should not answer at 3am is an agent whose channel is muted, not a machine
that refuses to boot. `wake_policy_test.exs` states it.

Open from the questions list: pricing the mode rather than the
sandbox-minutes (#798). Now tracked as #1120 (rent for a persistent home,
ADR 0031 decision 7). Note the framing there: the two modes are one
lifecycle policy on the machine (#805), so the price goes on the machine's
kept time, not on `persistent` as a product.

## Context

### The decision we made, and why

Fountain provisions one sandbox per conversation
(`conversations.ex:6` — "v1 keeps these 1:1"; the public schema doc says "one
chat with one agent inside one sandbox"). The reasons were good and still
hold for the cases they were chosen for:

- **Isolation as the only defence.** Every runtime runs with permission
  prompts bypassed (0014); the sandbox is the whole security boundary. A fresh
  sandbox per conversation means a bad turn poisons one transcript, not an
  agent's entire history.
- **Fan-out is the headline use case.** The bundled `fountain` skill and
  `parent_conversation_id` exist so one agent can spawn N children that each
  get "its own fresh Sprite" and run concurrently on separate disks.
- **The lifecycle is simple.** Conversation and sandbox share a lifetime, so
  idle/ceiling/terminate/wake all reason about one row, and
  `max_concurrent_sandboxes` is a concurrent-conversation cap for free.

### What people want instead

The "grokbot" shape is one long-lived machine per agent: every conversation —
every Buzz channel, every DM, every UI chat — lands on the same disk. The
appeal is not cost; it is that **the disk is the agent's memory**. Notes,
cloned repos, installed tools, `~/.claude` project state and the agent's own
scratch files accrue across conversations. Our per-conversation model
guarantees amnesia across conversations by construction, and 0017 already
conceded the same point *within* a conversation ("every idle reclaim
guaranteed the agent's amnesia to save money we were not spending").

The two models serve different jobs and we should offer both, not replace one
with the other:

| | Per-conversation (today) | Persistent per agent (this ADR) |
|---|---|---|
| Sandbox lifetime | = the conversation's | = the agent's (until reset/deleted) |
| Cross-conversation memory | none | shared disk, shared runtime session store |
| Concurrency | N conversations = N sandboxes, fully parallel | one machine; turns concurrent where the runtime allows, one at a time where it does not (step 4) |
| Best for | fan-out, one-shot tasks, untrusted inputs | assistants, channel bots, "my agent's computer" |
| Blast radius of a bad turn | one conversation | the agent's whole state |

### The 1:1 assumption is structural, not incidental

The schema is already N:1 (`Sandbox has_many :conversations`,
`conversations/sandbox.ex:35`) and the reaper is already written for N
(`server_alive?` and `last_activity_at` fold over all of a sandbox's
conversations; `_unsafe_reap_sandbox` terminates all of them). But no write
path ever produces a second conversation on a sandbox row, and these paths
would misbehave if one did:

1. **Reattach binds to the wrong process.** `attempt_session_attach`
   (`conversation_server.ex:1000`) takes the *head* of the sandbox's session
   list. Two conversations' detachable turns on one sandbox → a reattaching
   server streams B's agent into A's transcript. Sessions carry only a
   provider id and a command line, no conversation tag.
2. **Per-conversation identity lives at one shared path.** `/home/sprite/.env`
   (`provisioning.ex:32`) mixes environment/vault values with
   `FOUNTAIN_TOKEN` (the per-conversation callback key) and
   `FOUNTAIN_CONVERSATION_ID`, and is rewritten on every reattach
   (`conversation_server.ex:689,880`). Two conversations would stomp
   each other's identity.
3. **cwd is per runtime, not per conversation** (`runtimes/acp.ex:113-145`):
   claude/codex share `/home/sprite`, opencode a single sqlite db and an HTTP
   port, gemini `--resume`s "the most recent conversation in the workspace"
   (`gemini.ex:62`; called out as unsafe at `acp.ex:33-36`). ACP session ids
   themselves are explicit and safe; the disk around them is not.
4. **Terminate/park/destroy flip the shared row for one conversation.**
   `:terminate_conv` (`conversation_server.ex:1390`) destroys the sprite
   unconditionally; `park_sandbox` (`:1886`) suspends the row when *this*
   server's clock says idle — on Daytona/E2B that is a real pause of the other
   conversation's running turn.
5. **Idle/ceiling verdicts are per-server state acted on per-row**
   (`conversation_server.ex:1571-1588`, `sandbox_reaper.ex:211-250`).
6. **Quota counts sandboxes as a proxy for concurrent runs** (`quotas.ex:32`).
   Share sandboxes and the cap stops bounding compute.
7. **Wake's fallback repoints one conversation to a fresh row**
   (`conversations.ex:1536-1541`) and retires the old one, orphaning
   co-tenants; the schema comment at `conversation.ex:52` already describes
   only this fallback.

Also worth naming: `sandboxes` has no `agent_id` — a sandbox is not findable
by the identity a persistent mode needs; sprite names are random per call
(`fountain-<tenant>-<hex>`) so nothing reuses by name; and checkpointing is
disabled *because* names are fresh each time (`conversation_server.ex:748`).

## Decision

Add a **sandbox mode** with two values. The mode is a property of the
**launch**, defaulted from the agent — the same shape `environment_id` has had
since #783: the agent's setting is the default, a conversation may name another
at launch. The agent is the brain (model, runtime, skills, MCP); it holds an
opinion about *where* it runs only as a default.

- `ephemeral` — a sandbox per conversation. Unchanged, and the default.
- `persistent` — one sandbox per **agent identity**, where the identity is
  `(agent_id, environment_id, vault_id)`: the same key `find_channel_conversation`
  already resumes by, for the same reasons (#727: two vaults on one agent are
  two identities; #783: an environment override is a different baseline). A
  persistent sandbox is a "home" — the agent's computer.

So agent `foo` may run ephemeral in one conversation and on its home in
another; a persistent-by-default agent may fan out ephemeral children; a
second conversation may be opened *onto* an existing home by `sandbox_id`.
Which of these a launch does is decided at the door, not baked into the agent.

Concretely, in the order the pieces depend on each other:

**1. Make the sandbox row findable by identity.** `sandboxes` gains
`agent_id`, `vault_id`, `mode`, and a partial unique index on
`(user_id, agent_id, environment_id, vault_id) WHERE mode = 'persistent' AND
status NOT IN ('terminated','failed')`. The row is designed as if it were a
first-class machine — its identity does not depend on any conversation.
`start_conversation` takes `sandbox_mode` (launch attr, default
`agent.sandbox_mode`) and optionally `sandbox_id`:

- `sandbox_id` given → attach to that home (tenant-scoped; must be
  `persistent`, must belong to the same agent identity — a home is never
  shared across agents).
- mode `persistent` → `find_or_create_home/4` under the existing per-user
  advisory lock.
- mode `ephemeral` → `create_sandbox` as today.

Wake stops repointing: a persistent conversation resolves its sandbox by
identity, so if the home has to be re-provisioned (sprite gone), every
conversation on it follows automatically.

**2. Move per-conversation identity off the shared disk.** `FOUNTAIN_TOKEN`,
`FOUNTAIN_CONVERSATION_ID` and `TRACEPARENT` become **per-turn process env**
on the exec that spawns the ACP peer, not lines in `/home/sprite/.env`. The
`.env` file keeps only environment + vault values (identical for every
conversation on the home, by construction of the identity key). This change is
correct for the ephemeral mode too and can land first, on its own.

**3. Tag detachable sessions with the conversation.** Spawn the turn's session
with a recognisable marker (a `FOUNTAIN_CONVERSATION_ID=<id>` prefix on the
command line, or provider metadata where the adapter supports it), and make
reattach filter `list_sessions` by it instead of taking the head. Also correct
for ephemeral mode (it closes a latent bug that only 1:1 hides).

**4. Turns run concurrently, up to a per-runtime capacity; a per-sandbox
process owns the machine.** *(Rewritten 2026-08-23; the 2026-08-18 text
serialized every turn behind a lease.)* Several conversations on one home run
their turns at the same time, each with its own adapter process and its own
transcript — the laptop shape, several terminals in one repo. What actually
collides when two adapter processes start on one disk is a property of the
runtime, not of the machine:

| runtime | process model | shared state on disk | two at once |
|---|---|---|---|
| claude | `claude-agent-acp` per connection, spawns its own `claude` | `~/.claude/projects/<cwd>/<session>.jsonl` keyed by explicit id; `settings.local.json` grants; one `CLAUDE.md` | fine |
| codex | `codex-acp` per connection, App Server per process | rollouts keyed by session id under `~/.codex` | fine |
| opencode | `opencode acp` starts a local HTTP server per process | one sqlite store under `/tmp/.config/opencode`, one port | no — port and writer collision |
| gemini | `gemini --acp` per process | a store that erases a session while loading it; `SessionStore.consolidate` runs at the end of every turn as the workaround | no — a second live session during consolidation is the collision the workaround exists to avoid |

So `Runtimes.ACP.concurrency(runtime)` is unbounded for claude and codex and
1 for opencode and gemini. Below capacity a turn simply starts. **At capacity
the turn is refused** with a named error (`sandbox_at_capacity`), not queued:
a queue is the whole lease this amendment removes, and it would only ever be
exercised for the two runtimes the mode is not built for. Working-tree
contention between two claude processes on one repo is the user's, as it is
on a laptop; the audit trail records which conversation ran which turn, not
which wrote which file (#805 already concedes this).

Mechanism: a per-sandbox `SandboxServer`, registered in `Horde.Registry` under
`{:sandbox, sandbox_id}`, that is a lock on **machine operations** and a
counter — not a scheduler. It serializes provision, resume, park, destroy and
re-provision (two prompts waking one suspended machine resume it once, and
the second waits, as #803 already makes a prompt wait for a pending sandbox's
server); it holds the refcount of live conversations and which are mid-turn;
it keeps the idle and ceiling clock over the union of their activity
(`SandboxReaper.last_activity_at/1` already computes exactly this); and it
enforces the capacity above at turn start. Each `ConversationServer` keeps its
own adapter, its own callback key and its own transcript, and asks the
machine for a turn slot instead of flipping the row. The first cut is small —
registry entry, refcount, clock, capacity check, the guarded terminate and
park of step 5 — and the handle stays in each `ConversationServer` because
`Fountain.Sandbox.build_handle/2` is pure and every server can rebuild it
from the row; the handle and the sprite env move into the machine process
later.

**Where this cuts across #817.** #817's approved plan (2026-08-22, session-
scoped ACP connections) states as its invariant 2 "at most one adapter
connection per sandbox, cluster-wide", registered under this same
`{:sandbox, sandbox_id}` key, and adds a "reap on reattach" step that stops
every live ACP session on the sandbox when the reattaching server has no
running turn. Both are one-process-per-computer assumptions: the first is the
opposite of this mode, and the second would let conversation A's deploy
reattach kill conversation B's turn in flight. The invariant becomes *one
adapter per conversation* — which the existing conversation registry already
provides — the registry key belongs to the `SandboxServer`, and the reap is by
conversation tag (step 3). Everything else in #817 composes: each
conversation's adapter stays alive between its turns, background follow-ups
land on their own transcript, and codex's session grant survives per
conversation. Step 3 therefore lands before #817's PR 3; its PRs 1 and 2 are
unaffected.

**5. Split the lifecycle by mode.**

| Event | ephemeral (unchanged) | persistent |
|---|---|---|
| conversation terminated | destroy sprite, row `terminated` | revoke that conversation's callback key; sandbox untouched |
| idle timeout | park row `suspended` | park only when **no** conversation on the home is mid-turn and the newest activity across all of them is past the timeout (the `SandboxServer` decides); parking closes every conversation's adapter |
| max lifetime (continuous run) | destroy | **out of scope here — the ceiling itself is going away.** Decided 2026-08-23: a tenant who wants a machine running 24/7 is not something to stop, so the continuous-run ceiling (0017) is to be removed for every mode in its own change, not solved by this ADR. Until that lands, a home at the ceiling must not be destroyed (the disk is the product, #936); force-suspend, with every cut conversation's stage message saying so, is the interim behaviour. |
| conversation terminated while others run | n/a | revoke the key, conversation `terminated`; the sprite is destroyed only when this was the last live conversation — the guard `_unsafe_sandbox_held_by_other?` that the no-server path already applies (`conversation_server.ex:245`) extends to the live `:terminate_conv` path |
| provision failure | row `failed`, conv `failed` | row `failed`, conv `failed`; next conversation on the identity re-creates the home |
| agent deleted / vault or env changed | n/a | destroy the home (identity no longer exists); a "reset home" action does the same on demand. **Amended 2026-09-11 (#1565):** a *selection* change that leaves the build inputs alone no longer destroys anything — `POST /api/conversations/:id/reapply` moves the home's identity onto the new triple and keeps the disk, refusing when the build inputs, the runtime or a cotenant say otherwise |
| reaper abandoned pass | as today | as today — already N-aware |

**6. The slot is the computer; the meter is two numbers.** *(Decided
2026-08-23.)* A home counts as one toward `max_concurrent_sandboxes` while
`ready`, exactly as `Quotas.active_sandbox_count/2` counts today, and there is
no per-sandbox turn ceiling: four turns on one machine is one slot, on
purpose. That makes a slot more compute than it was under 1:1, and the plans
(0026) sell "concurrent sandboxes", so the sentence stays true. What changes
is the meter. `SandboxUsage.merge_intervals/1` unions turn intervals ("two
conversations prompting on one sandbox at the same moment is one busy
sandbox"); that is right for **sandbox busy time** and wrong for **turn
hours**, which is the plan's included allowance (#1016). Under concurrency
turn hours **sum per turn** while sandbox busy time **stays a union** — two
numbers, both computed from `turns`, and every usage surface labels which is
which.

**7. Runtimes.** claude and codex run concurrently on a shared cwd, sessions
resumed by explicit id. opencode and gemini have capacity 1 (step 4): a home
of either runtime takes one turn at a time and refuses a second. gemini is on
the ACP path since #659, so its exclusion from the mode is lifted; its legacy
`--resume` guess is gone (#941). Enforce with `Runtimes.ACP.concurrency/1` at
turn start and `Runtimes.ACP.supported_runtimes/0` at agent save time.

**8. Surface — every launch door, the same shape.** `PATCH /api/agents/:id`
gets `sandbox_mode` (the default); the agent form gets a radio with the table
above as copy. Every door that starts a conversation accepts the override:
`POST /api/conversations` (`sandbox_mode`, `sandbox_id`), `fountain run` /
`fountain conversations create` (`--sandbox-mode`, `--sandbox`), ACP
`session/new` `_meta`, Buzz provision, and the `fountain` skill's fan-out. No
allowlist for the override — unlike `environment_id`, the mode is not a
security boundary; the tenant scope on `sandbox_id` is. **Channel resume takes
the agent default**, not a per-message override: a channel identity should be
stable, and `find_channel_conversation` already lands each channel on one
conversation, so persistent mode makes those conversations share a disk —
which is what a channel bot wants. The conversation list shows a "home" badge
and the sandbox row gets its own detail (status, last resumed, disk age,
conversations on it, reset button).

Not a fifth primitive *in the UI* — yet. The sandbox row already exists as the
record; giving it `agent_id`, a mode and a lease is enough, and it should be
designed as if it were one (#805): a machine whose identity does not depend on
any conversation. Promote it to a user-facing "Machine" only if the UI needs
to show something a conversation-centric view cannot.

## Consequences

- **Memory across conversations, at the cost of blast radius.** In persistent
  mode a prompt injection in one channel can read and alter what every other
  conversation on that agent left on disk. This is inherent to the model and
  is the trade the user makes by choosing it; the mode-selection copy must say
  so, and it is one more reason the identity key includes the vault (a
  compromised home never holds two identities' credentials).
- **Fan-out and persistence compose, per launch.** Children spawned via the
  `fountain` skill go through `start_conversation`, so a persistent parent can
  fan out ephemeral children (fresh disks, parallel) or, by passing its own
  `sandbox_id`, children onto its home (shared disk, running at once) — the
  choice is the launch's, not the agent's. Two agents can never share a home
  (identity includes `agent_id`), so per-agent skill mounts at the
  runtime-global skills path do not collide.
- **Steps 2 and 3 improve the ephemeral mode on their own** and should ship
  first as bug fixes; nothing else in this ADR is needed to justify them.
- **Checkpointing becomes meaningful.** With a stable, named home the
  "fresh name each time" reason to keep checkpoints disabled goes away.
- **The `suspended`-never-aged-out cost from 0017 grows** in the way that
  ADR anticipated: homes accumulate one sprite per agent identity per tenant,
  forever. Still treated as zero until it isn't; the retention knob 0017 names
  is the answer.
- **Metering.** A home that stays `ready` under back-to-back or overlapping
  turns from many conversations bills as one sandbox. That is the intended
  cost shape but it is a different plan shape from "runs"; billing may want
  to price the mode (always-on agent) rather than the sandbox-minutes. Turn
  hours sum per turn regardless (step 6), so the allowance still sees every
  turn.

## Alternatives considered

- **Replace the per-conversation model outright.** No — fan-out and
  untrusted-input jobs want fresh disks; the two are different products.
- **Serialize every turn behind a per-home lease** (the 2026-08-18 draft of
  step 4). Sidesteps the shared-sqlite and shared-port problems in one move,
  but the survey in step 4 shows those belong to opencode and gemini alone,
  and serializing claude — the runtime the mode is for — would make one
  computer slower than two. Replaced 2026-08-23 by per-runtime capacity.
- **Per-conversation cwd subdirectories inside one sandbox.** Gives up the
  shared workspace that is the whole reason people want this. Not needed for
  concurrency, which the shared cwd supports for claude and codex. A
  per-launch `cwd` (a different repo on the same computer) is a natural later
  addition and needs nothing here.
- **A shared sandbox per *user* (one machine for all agents).** Skill mounts,
  runtime configs and vault credentials from different agents would collide on
  one disk; the identity key would have to be the user and every credential
  the user owns would sit on one machine. Rejected.
- **A new "Machine" primitive with its own CRUD.** Cleaner ownership story,
  but the sandbox row already is the machine; add a mode and an agent pointer
  first and promote only if the UI demands it.
- **Sandbox provider snapshots/forks (clone the home per conversation).**
  Gives memory *and* isolation, but 0018's provider matrix does not offer it
  uniformly (Sprites checkpoints exist; E2B/Daytona differ) and it is a
  different, larger project.

## Open questions

- Pricing: mode-based (always-on agent) vs sandbox-minutes as today (#798).

### Resolved 2026-08-24

- Wake on any inbound prompt, for that conversation alone; co-tenants
  attach on their own next prompt. See the Outcome section (#1072).

### Resolved 2026-08-23

- **Concurrency.** Parallel turns on one machine, per runtime capacity
  (step 4). Serialized-per-home was not what the target user wanted.
- **Ceiling.** The 24 h continuous-run ceiling went away for every mode in
  its own change (#936) — a tenant who wants a machine up 24/7 is not
  stopped. The knob stays for operators; when set, a home at the ceiling is
  suspended, never destroyed (step 5).
- **Identity key.** `(user_id, agent_id, environment_id, vault_id)` stays.
  The disk is materialized from the environment and vault at provision —
  env vars, packages, cloned repos, setup scripts — so a machine built from
  one environment is not a machine built from another, and re-materializing
  in place is not built. It is also the key channel resume already uses
  (#727, #783). **Amended 2026-09-11 (#1565):** the key is the same four
  columns and still never spans two differently-built disks, but it is no
  longer immutable — a reapply moves it onto the conversation's new selection
  when the build inputs match. See the amendment at the top of this file.
- **Attach.** `sandbox_id` onto a `suspended` home wakes it, under the quota
  lock. Onto a home whose launch names a different environment, vault or
  runtime: refused, the disk was shaped by the other one. Onto a home at
  capacity (opencode, gemini): refused with `sandbox_at_capacity`.
- **The cap and the meter.** The slot is the computer; turn hours sum per
  turn, sandbox busy time stays a union (step 6).

## Gates (if accepted)

1. Per-process identity env + session tagging (steps 2–3) — ships alone,
   fixes today's head-of-list reattach, no schema change. Lands before #817's
   PR 3, which needs the tag for its reap.
2. `SandboxServer`: machine-operation lock, refcount, idle/ceiling clock,
   `Runtimes.ACP.concurrency/1` enforced at turn start; the guarded live
   terminate and the union-clock park (steps 4–5). Its registry is the one
   #817 planned, with the per-conversation invariant.
3. `sandbox_id` attach on `POST /api/conversations` with the attach rules
   above, `sandboxes.agent_id/vault_id`, and `GET /api/sandboxes` (+ `/:id`:
   conversations on it, which are mid-turn). `Team.open_fresh_conversation`
   re-based on it. From here two claude conversations run at once on one
   sprite.
4. The meter split: turn hours summed per turn beside the unioned sandbox
   busy time in `SandboxUsage`, and the usage surfaces labelled.
5. Wake re-provision moves every co-tenant: `create_fresh_sandbox_and_start/4`
   repoints every conversation of the old row in one update, clearing each
   `runtime_session_id` (#778).
6. `sandboxes.mode` + partial unique index + `find_or_create_home`; agent
   default + per-launch `sandbox_mode` on every door (API, CLI, ACP `_meta`,
   Buzz provision, `fountain` skill), UI copy, docs; reset / agent-delete.
7. Live smoke: two claude conversations on one sprite, both mid-turn, a
   deploy in the middle — each reattaches to its own process, neither
   transcript takes the other's output, terminating one leaves the other
   running, idle park waits for both; then two Buzz channels on one
   persistent agent under interleaved turns.
