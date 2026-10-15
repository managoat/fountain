---
type: ADR
title: "The acp runtime runs a command you name"
description: "An agent may name a shell line as runtime_command instead of a coding-agent CLI."
tags: [runtimes, sandboxes, security]
status: stable
adr: "0049"
adr_status: "Accepted"
date: 2026-09-10
generated: { by: claude-code/opus-5, at: 2026-09-10T14:20:00-04:00 }
verified: { by: claude-code/opus-5, at: 2026-09-10T14:20:00-04:00 }
---

# 0049 — The acp runtime runs a command you name

**Status:** Accepted, 2026-09-10. Built (#1634).

## Context

Every runtime Managoat had was an LLM coding agent. `Managoat.Runtimes` is a
closed map of CLIs, each with a pinned ACP adapter, a provider and an
inference credential resolved per turn. That shape is load-bearing for those
and wrong for anything else.

A deterministic program wants most of what Managoat gives an agent and none
of what a model gives one: a machine that holds the repo and the toolchain,
an environment and a vault, a thread a human can read, a permission policy,
an audit trail. It does not want a model, an API key, or a config file
written on its behalf by a runtime that assumes which CLI is running.

Three things blocked it. The registry is a closed map. The model parser
expects a canonical `provider/model_id`. And a turn resolved an inference
credential it would never use, so an account holding no key could not run
one at all.

## Decision

`agents.runtime` accepts `acp`. An agent on that runtime carries
`runtime_command`, a shell line that Managoat runs inside the sandbox with
`bash -lc`, and speaks the Agent Client Protocol
([0014](0014-agent-client-protocol.md)) to it over stdio exactly as it does to
the coding agents.

`runtime_command` is a free string, not an entry in a catalog of blessed
commands. It runs inside the sandbox under the same isolation an
environment's `setup_script` runs under. An operator who can write a setup
script can already run anything a command could, so a catalog would restrict
a self-hoster and protect nobody.

`model` is optional on this runtime and inert. No inference credential is
resolved, no model is pinned on the ACP session, and `turn.usage` is null.
`model` is still validated when given: a value stored and ignored is worse
than one refused. `runtime_command` is a 422 on every other runtime, which
resolves its own executable from a pinned table.

Managoat installs no adapter and writes no system-prompt file. Skills still
mount, borrowing claude-code's layout, and the path arrives as
`MANAGOAT_SKILLS_DIR`. Everything else the protocol carries is unchanged. The
runtime is `Fountain.CommandRuntime`, in the server rather than in
`Managoat.Runtimes`, because the field it reads is the server's own column.

## Consequences

- A turn runs on an account with no API key at all, and costs nothing in
  inference.
- The isolation is whatever the sandbox provider gives, which on Sprites and
  E2B is a machine of the conversation's own. The runtime docs say so beside
  the field rather than leaving a reader to infer a stronger guarantee.
- The argv is a property of the agent, not of the runtime name, so
  `RuntimeDispatch.command/2` takes the agent, and a conversation whose agent
  was deleted has nothing to spawn. `TurnMachine.open/4` refuses that turn
  before a turn row exists.
- Two shell traps belong to whoever writes the command, and both are silent.
  Without `exec` the login shell stays the parent, so an interrupt stops the
  shell and can leave the program running in the sandbox. And a profile that
  prints a banner puts those bytes before the first protocol message, failing
  the turn on a line the client cannot read.
- `Agent.model` is nullable on the wire; clients that assumed a string need a
  null check.
- `Fountain.RuntimeDispatch` is the only runtime lookup. Resolving `acp`
  through `Managoat.Runtimes.for_runtime/1` directly returns
  `{:error, "unsupported runtime: acp"}`, which is how skills silently stopped
  mounting before #1634 fixed it.

## Alternatives considered

- **A catalog of blessed commands** — buys nothing. The command runs where a
  setup script runs, so the catalog restricts a self-hoster and stops no
  attacker who already controls the environment.
- **A parsed argv rather than a shell line** — loses the sandbox's own `PATH`
  (a login shell puts `~/.local/bin` and the language shims on it), forces an
  invented `chdir` field, and replaces the quoting rule the author already
  knows with one of ours.
- **A new entry in `Managoat.Runtimes`** — its registry is a closed map keyed
  on runtime name, and this runtime's command is a property of the agent.
- **Generalising `fountain-fixture`** — that was one fixed, account-restricted
  testing seam (#1611/#1007) with a pinned model and a changeset that refuses
  skills; generalising it would have made a test seam a product surface.

## History

- 2026-09-10 — The `acp` runtime runs an agent's `runtime_command` over ACP, with no model or inference credential (#1634).
- 2026-10-12 — Credits removed (#2609); an `acp` turn is no longer priced by sandbox time, and still reports null usage.
- 2026-10-14 — The self-hosted runner, whose default backend gave this runtime only a directory and the daemon's user, is removed (0071).
- 2026-10-15 — The skills path variable is `MANAGOAT_SKILLS_DIR` after the rename (#2790).
