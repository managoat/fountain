---
type: ADR
title: "Component libraries, extracted umbrella-first under the Managoat namespace"
description: "Managoat depends on one managoat_* library, the broker, as a hex pin; acp, sandbox, runtimes and oauth are folded back under apps/fountain/lib/managoat/, and no further extraction is planned."
tags: [architecture, libraries, licensing, ci]
status: stable
adr: "0037"
adr_status: "Accepted"
date: 2026-09-01
generated: { by: claude-fable/5.1, at: 2026-09-14T14:00:00-04:00 }
verified: { by: claude-fable/5.1, at: 2026-09-02T04:00:00-04:00 }
stale_after: 2026-12-01
---

# 0037 — Component libraries, extracted umbrella-first under the Managoat namespace

**Status:** Accepted, 2026-09-01. Managoat depends on one `managoat_*`
library, `managoat_broker`, as a hex pin in `apps/fountain/mix.exs`. Of the
nine libraries once extracted, four are back in the server, four are retired
on hex and archived, and the umbrella holds no library app. No further
extraction is planned. The tracker was #1334.

Names the seams that [0018](0018-sandbox-provider-abstraction.md),
[0014](0014-agent-client-protocol.md), [0019](0019-egress-credential-brokerage.md)
and [0022](0022-self-hosted-runner-provider.md) drew, and gave them a package
boundary.

## Context

A survey of the dependency graph on 2026-09-01, counting module references
between `lib/fountain/<context>` directories, found three things:

1. Three subsystems never touched the database: the sandbox adapters, the
   ACP peer and the broker held no reference to `Fountain.Repo` or any Ecto
   schema. They were libraries in everything but packaging.
2. `Conversations` is the hub, not a seam. It referenced 26 other contexts;
   every extraction ends with `Conversations` calling the new library.
3. The coupling that resisted extraction was uniform: configuration read
   from `:fountain`, telemetry under `[:fountain, …]`, audit in the context.
   Each is mechanical to cut.

Two motivations. Several pieces looked useful to anyone building an agent
platform on the BEAM and could not be used without taking the whole server:
a sandbox behaviour with a conformance suite over three vendors, an MCP
authorization discovery chain (RFC 9728, 8414, 7591) with an SSRF guard, a
client-side ACP session with a permission policy. And the server is easier
to reason about when its database-free parts sit behind package boundaries
the compiler enforces.

The cost was known from this repository's history: a change across a
repository boundary is two pull requests, a version bump and a pin. A seam
that is still moving pays that on every change.

## Decision

**Extract a subsystem only when it earns it.** A library lives in its own
repository `managoat/managoat_<name>` and on hex when it has an independent
consumer that needs the package, or a release schedule the server cannot
serve. Otherwise it stays in `apps/fountain` behind the module boundary the
compiler already enforces. A library that loses that justification is
folded back into the server.

**Today that leaves one library.** `managoat_broker` (the native egress
credential proxy: `CONNECT` and absolute-form forward proxy, the derived CA,
the header injector, behind a `Managoat.Broker.Store` behaviour that the
server implements over `broker_sessions`) stays a hex pin: its pin moves
rarely. `contributing/component-libraries.md` keeps the library table and
the procedure for updating it.

**Folded-back code keeps its `Managoat.*` names.** `managoat_acp`,
`managoat_sandbox`, `managoat_runtimes` and `managoat_oauth` live under
`apps/fountain/lib/managoat/` with their module names unchanged, so no
caller changed; a rename to `Fountain.*` would be a separate change. Their
tests are in `apps/fountain/test/managoat/`, the sandbox adapters' billed
live suites in `apps/fountain/test/live/` (tagged `:live`, excluded by
default), and their test-only modules (the sandbox `Fake` and
`ConformanceCase`, `FakeRuntime`, `ScriptedAgent`) in `test/support/`.
Adapter settings are read from `:fountain` under the same module keys, and
the adapter map is `config :fountain, :sandbox_adapters`. The live adapter
suite is the gate for ACP and runtimes behaviour on a change to
`lib/managoat/acp/` or `lib/managoat/runtimes/`.

**Rules for a library, should one be extracted.** It starts as a
`managoat/managoat_<name>` repository copied from an existing one, and the
server takes it as a hex pin from its first release. Modules are
`Managoat.<Name>`, never `Fountain.*`; the package is `managoat_<name>`. It
is Apache-2.0, so it can be used inside someone else's product. It reads
its own otp_app or an options map, never `:fountain` configuration, and
emits telemetry under `[:managoat, :<name>, …]`. Its test support (fakes,
conformance cases) ships in the library.

**What stays in the server regardless.** The Ecto contexts, the web layer
and the API: their value is the tenant contract, not the code. The server is
never rebuilt on libraries in one motion; that would spend months
re-deriving the tenant and audit rules `CLAUDE.md` lists as easy to get
wrong.

## Consequences

- Every change to the broker across the seam is two PRs: a library release
  and a pin bump here, and the pin PR is the only place the release meets
  the server. That cost is why the others came back.
- The folded-back OAuth state machine lost the seam's indirection with no
  change in behaviour: no `use Managoat.OAuth` macro or `Managoat.OAuth.Host`
  behaviour; `Fountain.OAuth` delegates to `Managoat.OAuth.Codes` and
  `.Device`, `Fountain.OAuth.validate_request/2` runs the redirect check
  once (client, development mode, `redirect_registered?/2`, PKCE), and
  `Fountain.OAuth.Host` is an ordinary module, still the one place that
  knows a token is an API key. Expired codes and device grants are not
  pruned; they never were.
- Retired hex releases stay installable, with a deprecation warning, for
  anyone still pinning them (Ravix's fork pins `managoat_runner`).

## Alternatives considered

- **Keep acp, sandbox and runtimes on hex.** Between graduating on
  2026-09-02 and 2026-10-15, `managoat_acp` published 16 releases,
  `managoat_sandbox` 15 and `managoat_runtimes` 25, and the server's lock
  entry moved 12, 8 and 18 times, each a library PR, a release and a pin PR.
  No other consumer tracked current versions (airlock sat on acp 0.1.2,
  sandbox 0.2.1, runtimes 0.3; goatherd and manasprites were dormant), so
  the libraries' release schedule was the server's. Rejected.
- **An off-the-shelf OAuth server instead of folding `managoat_oauth` back.**
  Boruta has no RFC 8628 device grant, which the CLI login needs, issues its
  own tokens rather than API keys, and brings flows to disable. An external
  identity provider adds a service to every self-hosted instance. The
  in-tree state machine is two modules and two tables.
- **Umbrella-first extraction** (the original rule: a library starts as
  `apps/managoat_<name>` in the umbrella and graduates when its surface stops
  moving). It gave a compile-time boundary at no release cost while seams
  moved, and was dropped once no further extraction was planned: its guard
  test defined no tests and its library test script ran nothing.
- **Straight to separate repositories.** Every cross-seam change is two PRs
  from day one, on seams still moving.
- **A `fountain_*` package namespace.** Carries the product's name into
  someone else's codebase; renaming later breaks every consumer.
- **MIT, or AGPL, for the libraries.** MIT is equivalent but lacks
  Apache-2.0's patent grant; AGPL would stop any downstream product using
  them, the opposite of the goal.
- **Extract `Conversations` as "the orchestrator".** It is the product's
  persistence and lifecycle model over the tenant tables; there is no second
  consumer for it.

## History

- 2026-09-01 — Decided: extract the database-free subsystems umbrella-first,
  one at a time, as Apache-2.0 `managoat_*` libraries.
- 2026-09-02 — All nine extracted and graduated to hex 0.1.0
  (substitution #1336, sandbox #1337, mcp_auth #1338, acp #1339, broker
  #1340, runner #1341, docs #1342, oauth #1343, runtimes #1368; recipe
  #1345). The optional credits extraction (#1344) was never built.
- 2026-09-03 — A second consumer, `managoat/managoat_examples` (#1365),
  compiles three standalone projects against the hex releases.
- 2026-09-14 — goatherd recorded as an external application consumer
  ([0055](0055-hosted-fountain-and-local-control-planes.md)); further
  extraction paused until a library has an independent consumer or its own
  release schedule.
- 2026-10-12 — The graduation script and library template removed.
- 2026-10-13 — `managoat_substitution` folded back as `Fountain.Substitution`
  (one caller, one release) and its repository archived; the umbrella-first
  rule and its guard machinery dropped.
- 2026-10-13 — `managoat_mcp_auth` lost its one consumer when Connections
  were removed (#2617).
- 2026-10-15 — `managoat_mcp_auth` archived and retired on hex (#2750;
  #2746 records what to build on if MCP authorization returns).
- 2026-10-15 — acp 0.6.0, sandbox 0.5.5 and runtimes 0.5.7 folded back
  (without the Daytona adapter and opencode runtime, already removed);
  retired on hex and archived after v0.24.0 (#2748).
- 2026-10-15 — `managoat_oauth` 0.1.2 folded back and its seam removed;
  retired and archived.
- 2026-10-15 — `managoat_runner` retired and archived (#2759): its consumer,
  the self-hosted runner, was removed ([0071](0071-hosted-sandbox-providers-only.md), #2676).
- 2026-10-15 — `managoat_docs` dropped when the manual became a static build
  in `site/` ([0081](0081-the-manual-is-a-static-build.md)); retired and
  archived (#2771).
