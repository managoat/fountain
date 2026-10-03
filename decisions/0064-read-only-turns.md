---
type: ADR
title: "A read-only turn is enforced by the sandbox, not by the harness"
description: "Proposed, unbuilt: a prompt may run read-only; Fountain starts that turn's adapter in a read-only mount namespace with capabilities dropped, rejects its permission requests, withholds write credentials and MCP servers, and refuses runtimes it cannot hold to it. Harness modes alone were measured and do not enforce it."
tags: [conversations, sandbox, acp, permissions]
status: draft
adr: "0064"
adr_status: "Proposed"
date: 2026-10-02
---

# 0064 — A read-only turn is enforced by the sandbox, not by the harness

## Context

Ravix is adding ask-only access to shared tracks (#2533). A collaborator with
"Can ask" may ask the agent about a thread. The answer has to come from that
thread's own context, so the question runs as a turn of the same
conversation. The collaborator must not be able to change the checkout. That
is a permission, so a prompt instruction does not satisfy it. The issue asks
for a per-prompt flag (`read_only: true` on
`POST /api/conversations/{id}/prompts`) that works on claude and codex. The
turn must still finish with an answer, and turns before and after it must be
unaffected.

[ADR 0062](0062-acp-session-config-options.md) left this open: both adapters
expose a mode option, so a read-only switch could travel through a prompt's
`session_config`, but "whether that is enough to enforce read-only is
#2533's decision". A spike on 2026-10-02 measured it. The full results are on
#2533 (issuecomment-5964592954) and the probe scripts are in the comment after
it.

### How the spike measured

A scratch sprite (Ubuntu 26.04, kernel 6.12.105-fly) ran the pinned
adapters, driven by a minimal ACP client that records every permission
request and answers it as told. Each case used a fresh git repository and one
prompt: create `notes.txt` with the edit tool, run `touch made_by_bash`, run
`git log` and report the commit subject. Passing means: no file was written,
`git log` ran, and the prompt ended with `stopReason: "end_turn"` and an
answer.

### The harness modes do not enforce it

**Claude** (claude-agent-acp 0.81.2, Claude Code 2.1.251):

| Case | Writes | Turn |
|---|---|---|
| default mode, client rejects every request | asked, refused | `end_turn`; `git log` ran without a request |
| `plan` mode | not attempted | `cancelled`: the model calls ExitPlanMode, and rejecting it ends the turn before the answer |
| `dontAsk` | — | `session/set_mode` refuses it: "not available in this session" |
| repository `.claude/settings.json` allows `Bash(touch:*)` and `Write`, untrusted workspace | asked, refused | `end_turn`; the CLI ignores project rules until the workspace is trusted |
| the same, workspace trusted (`hasTrustDialogAccepted`) | **written, no request** | the allow rules skip the client |

Plan mode fails the acceptance criteria. Default mode with every request
rejected passes, but only for what reaches the client: anything the CLI
allows on its own, from a trusted allow rule or its read-only command
classifier, never asks.

**Codex:**

| Case | Edit | `touch` | `git log` | Turn |
|---|---|---|---|---|
| codex-acp 1.10.0 `read-only`, client rejects | asked | — | — | `cancelled` |
| codex-acp 2.1.1 `read-only`, client rejects | asked | — | — | `cancelled` |
| 1.10.0 + local `read-only-strict` (readOnly sandbox, approval `never`) | refused, no request | failed: Codex's own bwrap refused the session's capabilities | failed | `end_turn` |

- The pinned 1.10.0's `read-only` mode is `workspaceWrite` with `on-request`
  approvals, so it doesn't stop writes.
- agentclientprotocol/codex-acp#480 made `read-only` a real `readOnly`
  sandbox, first in stable release 2.0.0, but it still asks before an edit.
- Rejecting any Codex request cancels the turn, because Codex offers
  `cancel` and not `decline` for file changes (agentclientprotocol/codex-acp#556).
  The open agentclientprotocol/codex-acp#558 adds an opt-in `decline`.
- The mode resets to the default on every `session/load`.

### The sandbox does enforce it

Sprites allow unprivileged user namespaces. Their exec sessions carry
ambient capabilities, `CAP_SYS_ADMIN` and `CAP_DAC_OVERRIDE` among them.
bwrap refuses to start with those, and with them the agent could remount.
`Fountain.Conversations.CodexSandbox` already clears the inheritable and
ambient sets for Codex's own sandbox, but it keeps the bounding set and
`sudo` on purpose, for approved privileged commands. A read-only turn
clears the bounding set too and sets `no_new_privs`, which takes `sudo` away:

```
setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs \
  bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp \
        --bind <harness state> <harness state> \
        --unshare-user --uid 1001 --gid 1001 --die-with-parent --new-session \
        <adapter>
```

- Writes to the workspace, `~/.bashrc`, `/etc` and `/var/tmp` fail with
  EROFS.
- `mount -o remount,rw`, `umount`, a nested `unshare -Urm` and `sudo` all
  fail.
- **Claude**, with the client approving every request: both writes failed
  with EROFS. The turn ended `end_turn` with a correct answer that named the
  read-only filesystem.
- **Codex** in `read-only-strict`: the edit was refused without a request,
  `touch` failed with EROFS, `git log` ran, and the turn ended `end_turn` with
  the answer.
- **Codex** in its normal `agent` mode, inside the same namespace: every
  command failed, reads included, because Codex's sandbox creates `.agents`
  in the workspace. Codex needs its read-only mode as well as the namespace.
- bubblewrap is not in the sprite base image.

## Decision

1. **A prompt may ask for a read-only turn.**
   - `read_only: true` on `POST /api/conversations/{id}/prompts` applies to
     that turn only, following the rule for per-prompt settings in
     [ADR 0061](0061-conversation-model-override.md) and 0062.
   - It is stored on the prompt and the turn, so clients can label the turn.
   - Read-only cannot be loosened inside the turn. No later setting, policy
     or prompt field widens it.

2. **The boundary is a read-only mount namespace around the turn's
   adapter.** Fountain starts the adapter under the command above.
   - Writable: only the harness's own session state: `~/.claude`,
     `~/.claude.json` and `CODEX_HOME`. Any settings file inside them that
     changes permissions is mounted read-only over the writable directory, so
     the turn cannot loosen what a later turn may do.
   - A turn whose adapter can't be started this way fails before the prompt
     is sent. Running it without the namespace is never a fallback.

3. **A read-only turn never shares an adapter process with a normal turn.**
   An idle peer can carry over from one turn to the next (`Connection`). A
   change between read-only and normal is a new stale reason, in both
   directions, so the idle peer is closed and the turn spawns its own.

4. **Inside the namespace, the harness is kept from fighting it.**
   - **Claude** runs in its default permission mode. Fountain answers every
     `session/request_permission` in the turn with a rejection, which ends
     with `end_turn` and an answer. Plan mode is not used.
   - **Codex** is set to its read-only sandbox on every read-only turn. If
     the mode is refused, the turn fails. A rejection must decline the
     action without cancelling the turn. That needs codex-acp 2.x plus #558's
     `continueOnReject`, or a mode that never asks. Until one of them is
     pinned, a read-only codex turn is refused (decision 6).

5. **Credentials and tools that bypass the filesystem are withheld.**
   - The broker session for a read-only turn refuses credentialed writes.
     A `git push` reads `.git`, and only writes refs after the remote
     accepted it, so a read-only mount does not stop a push.
   - The sandbox's Fountain credential is not exported to the turn.
   - The turn's MCP servers are dropped. They run outside both harness
     sandboxes and outside the namespace's reach.

6. **A runtime that can't be held to it is refused.**
   - The refusal is a 422 before the turn is admitted, in the same way
     `permission_policy_unenforceable` refuses a policy today.
   - opencode never sends permission requests.
   - Codex is refused until decision 4's condition is met.
   - Gemini is refused until it is measured.

7. **Read-only is not confidential.** The turn can read environment values,
   vault overrides and the checkout. Clients that offer read-only access to
   other people must say so. Ravix's "Can ask" grants reading secrets.

## Implementation status

Nothing in this ADR is built. Prerequisites:

- **bubblewrap in every sprite.** Installed at provision, or shipped as a
  static binary as #2530's layer does with zstd.
- **The codex-acp upgrade (#2553).** 1.10.0 → 2.x, and `continueOnReject`
  after agentclientprotocol/codex-acp#558 ships.
- **Broker support** for a per-session read-only flag.

Not yet measured:

- whether `Write` and `Edit` fail the same way inside the namespace when the
  harness runs subagents;
- gemini;
- how long the namespace adds to adapter start.

## Consequences

- One mechanism covers every runtime that can run inside the namespace. The
  harness-specific parts only shape behaviour, so a runtime that loosens its
  own modes doesn't loosen read-only.
- A read-only turn always pays for a fresh adapter spawn, and pays again on
  the next normal turn.
- Reads still run. The CLI's read-only classifier, `git log` and file reads
  behave as in a normal turn, so the answer can draw on the checkout.
- Fountain owns a confinement launcher with its own failure modes: a missing
  bwrap, a provider without user namespaces, a self-hosted runner (ADR 0022)
  with different capabilities. Each of those refuses the turn.
- The read-only flag reaches the broker and the MCP configuration, not only
  the adapter.

## Alternatives considered

- **Harness modes alone (`plan`, Codex `read-only`) through
  `session_config`.** Rejected: plan mode ends the turn as `cancelled`; a
  trusted repository's allow rules skip the client; Codex 1.10.0's mode
  doesn't stop writes, and every Codex rejection cancels the turn.
- **A per-turn `permission_policy` that denies `edit` and `execute`.**
  Rejected as the boundary for the same reason: it sees only what the
  harness asks about. It also denies read-only commands, though Claude
  already lets those run without asking.
- **Read-only for a whole conversation.** Rejected: the asker needs the
  thread's own context, which lives in the owner's conversation.
- **A forked session (`session/fork`) for the question.** Not chosen: it
  keeps the question out of the thread, but it doesn't remove the need for
  enforcement, and the session file's location is an open problem (#2541).
  It stays an option for keeping read-only turns out of the owner's
  transcript.
- **Carrying a patched codex-acp with a mode that never asks.** Drafted and
  measured (`read-only-strict`), then set aside. Upstream already has the
  read-only sandbox, and #558 addresses the cancelled turn.
