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

**Status:** Accepted. Everything below is built (#1634).

## Context

Every runtime Fountain had was an LLM coding agent. `Managoat.Runtimes` is a
closed map of four CLIs, each with a pinned ACP adapter, a provider and an
inference credential resolved per turn. That shape is load-bearing for those
four and wrong for anything else.

A deterministic program wants most of what Fountain gives an agent and none of
what a model gives one: a warm machine that holds the repo and the toolchain,
an environment and a vault, a thread a human can read, a schedule, a
permission policy, an audit trail. What it does not want is a model, an API
key, or a config file written on its behalf by a runtime that has assumptions
about which CLI is running.

Three things blocked it. The registry is a closed map. The model parser
expects a canonical `provider/model_id`. And a turn resolves an inference
credential it would never use, so an account holding no key could not run one
at all.

## Decision

`agents.runtime` accepts `acp`. An agent on that runtime carries
`runtime_command`, a **shell line** that Fountain runs inside the sandbox with
`bash -lc`, and speaks the Agent Client Protocol (ADR 0014) to it over stdio
exactly as it does to the four CLIs.

`runtime_command` is a **free string, not an entry in a catalog of blessed
commands.** The command is resolved and executed inside the sandbox, under the
same isolation an environment's `setup_script` already runs under. An operator
who can write a setup script can already run anything a command could, so a
catalog would restrict a self-hoster and protect nobody.

`model` is optional on this runtime and inert. No inference credential is
resolved, no model is pinned on the ACP session, and `turn.usage` is null, so
credits price the turn by sandbox time alone. `model` is still validated when
it is given — a value that is stored and ignored is worse than one refused.
`runtime_command` is a 422 on every other runtime, which resolves its own
executable from a pinned table.

Fountain installs no adapter and writes no system-prompt file. Skills still
mount, borrowing claude-code's layout, and the path arrives as
`FOUNTAIN_SKILLS_DIR`. Everything else the protocol carries is unchanged.

## Consequences

- **A turn runs on an account with no API key at all.** That is the point, and
  it is also the first Fountain turn that costs nothing in inference.
- **The isolation claim has to be stated where it is weakest.** On a hosted
  sandbox provider it is a machine of its own. On `sandbox_provider: runner`
  with the default backend it is a directory and the daemon's own user, which
  is what trusted mode (ADR 0022) already means for a setup script. The
  runtime docs say so beside the field rather than leaving a reader to infer
  a stronger guarantee than holds.
- **The argv is a property of the agent, not of the runtime name.** So
  `RuntimeDispatch.command/2` takes the agent, and a conversation whose agent
  was deleted has nothing to spawn. `TurnMachine.open/4` refuses that turn
  before a turn row exists, the way it refuses one at capacity.
- **Two shell traps belong to whoever writes the command**, and both are
  silent. Without `exec` the login shell stays as the parent, so an interrupt
  stops the shell and can leave the program running on a persistent sandbox.
  And a profile that prints a banner puts those bytes in front of the first
  protocol message, failing the turn on a line the client cannot read.
- **`Agent.model` is nullable on the wire.** Clients that assumed a string
  need a null check; the Swift SDK's typed model had to widen with it.
- **`Fountain.RuntimeDispatch` is now the only runtime lookup.** Anything
  resolving a runtime string through `Managoat.Runtimes.for_runtime/1`
  directly gets `{:error, "unsupported runtime: acp"}`, which is how skills
  silently stopped mounting before #1634 fixed it.

## Alternatives considered

- **A catalog of blessed commands** — buys nothing. The command runs where a
  setup script runs, so the catalog restricts a self-hoster and stops no
  attacker who already controls the environment.
- **A parsed argv rather than a shell line** — loses the sandbox's own `PATH`
  (a login shell is what puts `~/.local/bin` and the language shims on it),
  forces Fountain to invent a `chdir` field, and replaces the quoting rule
  whoever wrote the string already knows with one of ours.
- **A fifth entry in `Managoat.Runtimes`** — the library's registry is a
  closed map keyed on runtime name, and this runtime's command is a property
  of the agent. The field it reads (`agents.runtime_command`) is Fountain's
  own column, so the module belongs in Fountain.
- **Reusing `fountain-fixture`** — that is one fixed, account-restricted
  testing seam (#1611/#1007) with a pinned model and a changeset that refuses
  skills. Generalising it would have made a test seam into a product surface.

## Addendum — 2026-10-14: credits are gone

The Decision's "credits price the turn by sandbox time alone" no longer
applies: credits were removed on 2026-10-12 (#2609), and no turn is priced.
An `acp` turn still resolves no inference credential, pins no model and
reports `turn.usage` as null.
