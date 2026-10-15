---
type: ADR
title: "Component libraries, extracted umbrella-first under the Managoat namespace"
description: "Current state (2026-10-15): Fountain depends on two managoat_* libraries as hex pins (broker, docs); acp, runtimes, sandbox and oauth are folded back into apps/fountain/lib/managoat/ with their Managoat.* module names (addendum 2026-10-15), managoat_substitution is folded back as Fountain.Substitution, managoat_mcp_auth left with Connections (#2617) and is archived with its hex releases retired (#2746), managoat_runner left with the self-hosted runner (0071), and no further extraction is planned. Originally: Fountain's database-free subsystems (sandbox, ACP peer, runtime provisioning, MCP authorization discovery, broker, runner protocol, docs, OAuth, substitution) are extracted one at a time as Apache-2.0 libraries named Managoat.*, first as apps in this umbrella and then as managoat/<name> repos on hex. Built so far: managoat_substitution (#1336), managoat_sandbox (#1337), managoat_mcp_auth (#1338), managoat_runner (#1341), managoat_docs (#1342), managoat_oauth (#1343), managoat_broker (#1340), managoat_acp (#1339) and managoat_runtimes (#1368). Graduated to hex so far: managoat_substitution, managoat_mcp_auth, managoat_oauth, managoat_acp, managoat_sandbox, managoat_docs, managoat_broker, managoat_runner, managoat_runtimes. All nine. goatherd is an external application consumer; ADR 0055 records its boundary with Fountain. Further extraction is paused (2026-09-14) unless an independent consumer or a release schedule of its own justifies the two-PR coordination cost. Addendum 2026-10-12: scripts/graduate-library.sh and templates/managoat-library are removed; a new library copies an existing managoat_* repository. Addendum 2026-10-13: managoat_substitution is folded back into the server as Fountain.Substitution; it never had a second consumer. Addendum 2026-10-13: the umbrella-first rule is dropped with its guards (umbrella_layout_test.exs, scripts/test-libraries.sh); no further extraction is planned, and a library that is ever needed starts as a repository of its own. Addendum 2026-10-15: managoat_acp, managoat_sandbox and managoat_runtimes are folded back into the server under apps/fountain/lib/managoat/, keeping the Managoat.* module names; in six weeks on hex they published 16, 15 and 25 releases and Fountain's lock moved 12, 8 and 18 times, each move a library PR plus a pin PR, and no other consumer tracks current versions. The Daytona adapter and the opencode runtime are left out. Their hex releases are retired and their repositories archived (#2748). Addendum 2026-10-15: managoat_oauth is folded back with its seam simplified (no use macro, no Host behaviour, one redirect check); Boruta lacks the RFC 8628 device grant and an external IdP adds a service per instance."
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

**Current state (2026-10-15).** The umbrella holds no library app, and the
umbrella-first rule is dropped (addendum of 2026-10-13). Fountain depends on
two `managoat_*` libraries as hex pins in `apps/fountain/mix.exs`:
`managoat_broker` and `managoat_docs`. Of the nine that
were extracted, `managoat_acp`, `managoat_sandbox` and `managoat_runtimes`
are back in the server under `apps/fountain/lib/managoat/`, with their
`Managoat.*` module names unchanged (addendum of 2026-10-15),
`managoat_substitution` is back in the server as `Fountain.Substitution`
(addendum of 2026-10-13), `managoat_oauth` is back as
`apps/fountain/lib/managoat/oauth/` (addendum of 2026-10-15),
`managoat_mcp_auth` lost its one consumer when
Connections were removed (#2617) and is archived, its hex releases retired
(#2746, which also records what to build on if MCP authorization returns), and `managoat_runner` lost its one consumer
when the self-hosted runner was removed
([0071](0071-hosted-sandbox-providers-only.md), #2676). No further extraction
is planned. The text below records the decision as it was made and built;
the addenda at the end say what changed.

**Status:** Accepted, 2026-09-01. **Built so far:** `managoat_substitution`
(#1336, PR #1347, which also built the umbrella mechanics named below and
the guard test, `umbrella_layout_test.exs`) and `managoat_sandbox` (#1337:
the behaviour, the Sprites/E2B/Daytona adapters, `Retry`, the Fake and the
conformance case; the configured-providers policy stays in `fountain`),
`managoat_mcp_auth` (#1338: the RFC 9728 / 8414 / 7591 discovery chain and
its SSRF URL guard; provider rows, the OAuth client, the Gmail tool server
and the verified catalog stay in `fountain`), `managoat_runner` (#1341:
the runner wire protocol, the `WebSock` connection process, the sandbox
adapter over it, the sandbox-name shape and the `FakeDaemon`, behind a
`Managoat.Runner.Host` behaviour that `fountain` implements over Horde; the
`runners` table, placement and presence stay in `fountain`),
`managoat_docs` (#1342: the compile-time embedded manual as a `use` macro,
its nav parser and dialect compiler, the markdown renderer with both its
paths, and the `docs_test.exs` guardrails as `Managoat.Docs.GuardrailCase`;
`Fountain.Docs` survives as one `use` line, and `docs/`, `nav.yml`,
`Fountain.Help` (removed 2026-10-15 by
[0076](0076-console-without-configuration-pages.md)) and the `/docs`
controller stay in `fountain`; the prose
gates also stayed there at extraction and have since been removed),
`managoat_oauth` (#1343: the authorization code + PKCE and device-grant
state machine, its two schemas and a migration for a new consumer, as a
`use` macro over a `Managoat.OAuth.Host` behaviour that mints the token,
checks the subject and audits; `Fountain.OAuth` is the instance and
`Fountain.OAuth.Host` keeps tokens as API keys) and
`managoat_broker` (#1340: the native egress credential proxy from PR #1148,
ported rather than rebased; `CONNECT` and absolute-form forward proxy, the
derived CA, the header injector, behind a `Managoat.Broker.Store` behaviour
that `fountain` implements over the `broker_sessions` table; it is the only
backend since the 2026-09-03 deployment flip and Agent Vault client removal
(#1487), enabled by `BROKER_LISTEN_PORT`; see the amendment in
[0019](0019-egress-credential-brokerage.md#amendment-2026-09-03-production-flipped-and-the-vendor-client-is-gone))
and `managoat_acp` (#1339: the client-side ACP
session that outlives the turn, the JSON-RPC framing, the permission policy,
the block normaliser, usage accounting, the tracer and a `ScriptedAgent`,
behind a writer callback rather than a sandbox dependency; runtime
provisioning, `LegacyBlocks`, the stream-keyed `Conversations.Blocks`
dispatcher and the tool bridge stay in `fountain`; its README carries the
comparison against `acpex` and `agent_client_protocol`) and
`managoat_runtimes` (#1368: the provisioning half #1339 left behind — the
`Managoat.Runtimes` behaviour and dispatcher, the pinned ACP adapter table
and install, `Layout`, `Instructions`, `Quirks`, the `provider/model_id`
parser, the skills mechanism, gemini's session-store workaround and the
`FakeRuntime`, with the agent typed as a plain map; the model suggestion
catalog (`Fountain.Agents.ModelCatalog`), the bundled skill content, the
permission-ask timeout read (`Fountain.Conversations.Lifecycle`),
`LegacyBlocks` and `InferenceCredentials` stay in `fountain`). Not yet
built: the optional credits extraction (#1344). **Graduated** (#1345, the recipe is
`scripts/graduate-library.sh` and the CONTRIBUTING section "Graduating a
library"): `managoat_substitution` (managoat/managoat_substitution, hex
0.1.0, 2026-09-02), `managoat_mcp_auth` (managoat/managoat_mcp_auth, hex
0.1.0, 2026-09-02), `managoat_oauth` (managoat/managoat_oauth, hex 0.1.0,
2026-09-02), `managoat_acp` (managoat/managoat_acp, hex 0.1.0, 2026-09-02;
hexdocs now carries the README's comparison against `acpex` and
`agent_client_protocol`, which was the point), `managoat_sandbox`
(managoat/managoat_sandbox, hex 0.1.0, 2026-09-02; `managoat_runner`'s
dependency on it became the hex requirement in the same PR, since an
`in_umbrella` dependency on a deleted app cannot resolve), `managoat_docs`
(managoat/managoat_docs, hex 0.1.0, 2026-09-02; the package carries `lib/`
only, nothing from Fountain's `docs/` or the fixture manual under `test/`),
`managoat_broker` (managoat/managoat_broker, hex 0.1.0, 2026-09-02; the two
x509 dialyzer ignores travelled with it), `managoat_runner`
(managoat/managoat_runner, hex 0.1.0, 2026-09-02, last because it depends on
`managoat_sandbox`, whose Fountain-side PR switched runner's dependency to
the hex release first), `managoat_runtimes` (managoat/managoat_runtimes, hex
0.1.0, 2026-09-02, the same day it was extracted: its two dependencies were
already hex releases, and the package carries `priv/` for the gemini
session-store script, which is what taught `scripts/graduate-library.sh` to
keep a library's extra package files). All nine have graduated; the umbrella
holds no library app, and `umbrella_layout_test.exs` and
`scripts/test-libraries.sh` guard the next one. The tracker is #1334. Each PR
that extracts or graduates a library updates this block.

**Second consumer:**
[`managoat/managoat_examples`](https://github.com/managoat/managoat_examples)
(#1365, 2026-09-03) is three standalone Mix projects that depend only on the
Hex releases. `acp_stdio` runs an adapter as an Erlang `Port` and gives its
bytes to `Managoat.ACP.Peer` through the writer callback. `sandbox_agent`
runs the same peer behind `Managoat.Sandbox.write_stdin/2`; its default
`Managoat.Sandbox.Fake` script needs no credentials, and its opt-in Sprites
path provisions a real adapter through `Managoat.Runtimes`. `mcp_discovery`
starts with one verified server URL and uses `Managoat.McpAuth` through
dynamic client registration. CI compiles every example from exact Hex pins
and runs the Fake turn. The consumer needed no new library surface: the
writer callback, the Fake command vocabulary and `${VAR}` substitution were
enough outside Fountain.

**External application consumer, recorded 2026-09-14:**
[`managoat/goatherd`](https://github.com/managoat/goatherd) assembles
`managoat_sandbox`, `managoat_runtimes` and `managoat_acp` into a terminal
control plane for remote Sprites sandboxes. It has no dependency on Fountain,
no Fountain account, and no database of its own. It provisions an adapter,
drives ACP turns and reconnects to sandbox sessions without porting
`Fountain.Conversations`. This exercises the reuse boundary in a standalone
application as well as in the examples already recorded above; the examples
remain the earlier external consumer, so goatherd is not labelled the first
consumer of any kind. Verified against goatherd
[`20d0e5c`](https://github.com/managoat/goatherd/tree/20d0e5cf15f4d51a964c8dd2118df569870a9a37).
[ADR 0055](0055-hosted-fountain-and-local-control-planes.md) records the
hosted/local boundary and corrects #1516's four-field-state shorthand against
the source. goatherd is not positioned as Fountain's adoption on-ramp; the
Postgres decision, including demos, remains
[ADR 0004](0004-postgres-day-one.md#amendment--2026-09-14-the-postgres-on-ramp-includes-demos).

**Addendum, 2026-09-14: further extraction is paused.** The nine libraries
are built and on hex, the second consumer and goatherd exist, and the cost
this ADR accepted in its consequences has arrived: every change across a
seam is two PRs, a bump in the library and a pin here, and the pin PR is the
only place the new version meets Fountain. Nothing on the remaining list
(the optional credits extraction, #1344, or any subsystem not yet named) has
a consumer outside Fountain or a release cadence of its own, so extracting
it would buy that coordination cost and nothing else. A tenth library is
extracted when one of those two conditions holds: an independent consumer
that needs the package, or a release schedule the umbrella cannot serve.
Until then a subsystem stays in `apps/fountain` behind the module boundary
the compiler already enforces, and the recipes move from `CONTRIBUTING.md` to
`contributing/component-libraries.md`, kept for that day and for fixes to
the libraries that exist. This pauses the "one at a time" cadence in the
Decision; it supersedes nothing else here.

Extends [0010](0010-ee-directory-boundary.md) (the licence boundary inside
one repo) and [0027](0027-agpl-relicensing.md) (the server's licence). Names
the seams that [0018](0018-sandbox-provider-abstraction.md),
[0014](0014-agent-client-protocol.md), [0019](0019-egress-credential-brokerage.md)
and [0022](0022-self-hosted-runner-provider.md) already drew, and gives them
a package boundary.

## Context

Fountain is one OTP application (`apps/fountain`) plus `ee/`. A survey of the
dependency graph on 2026-09-01, made by counting module references between
`lib/fountain/<context>` directories, found three things:

1. **Three subsystems never touch the database.** `Fountain.Sandbox` with
   its Sprites, E2B and Daytona adapters, `Fountain.Runtimes` (the ACP peer)
   and `Fountain.Broker` hold no reference to `Fountain.Repo` or to any Ecto
   schema. They read configuration, call Req or the Sprites SDK, and return
   results. They are libraries in everything but packaging.
2. **`Conversations` is the hub, not a seam.** It references 26 other
   contexts, and `ConversationServer` alone is 4,489 lines. Every extraction
   ends with `Conversations` calling the new library; it is what remains.
3. **The coupling that resists extraction is uniform, not structural.**
   Configuration is read as `Application.get_env(:fountain, …)` (the sandbox
   adapters read ten keys, the broker nine), telemetry is emitted under
   `[:fountain, …]`, and audit is recorded inside the context. Each is
   mechanical to cut.

Two motivations. First, several of these pieces are useful to anyone
building an agent platform on the BEAM, and today they cannot be used
without taking the whole AGPL server: a sandbox behaviour with an executable
conformance suite over three vendors, an MCP authorization discovery chain
(RFC 9728, 8414, 7591) with an SSRF guard, a client-side ACP session with a
permission policy and a normalised block format. Nothing equivalent to the
first two is on hex; two ACP packages exist at 0.1.x. Second, the server
itself is easier to reason about, test and eventually rebuild when its
database-free parts sit behind package boundaries the compiler enforces.

The managoat GitHub organization exists and holds sixteen repositories, all
of them applications and templates built on the API. It holds no library.

The costs are known from this repository's own history. A change across a
repository boundary is two pull requests, a version bump and a pin (the SDK
release automation, #1305's CLI work). The CI gates here are strict enough
that a solo merge needs `--admin`. A seam that is still moving pays that
cost on every change.

## Decision

Extract the database-free subsystems as separate libraries, one seam at a
time, in this order and with these rules.

**Umbrella-first.** Each library begins life as an app in this umbrella,
`apps/managoat_<name>`, taken by `apps/fountain` as
`{:managoat_<name>, in_umbrella: true}`. The umbrella resolves dependencies
between its apps at compile time, so a seam that is not real fails to compile
before a second repository exists. A library graduates to a repository
`managoat/managoat_<name>` (the same string as the hex package) when its
public surface has stopped moving; the dependency line then becomes a hex
requirement (`~> 0.1.0`, patch-level while everything is 0.x). The recipe
for graduating is `scripts/graduate-library.sh` plus
`templates/managoat-library/` (#1345), written once and run eight times.

**Namespace.** Modules are `Managoat.<Name>`; hex packages are
`managoat_<name>`. No library module carries the `Fountain` prefix.

**Licence.** Every extracted library is Apache-2.0, with its own `LICENSE`
in its app directory while it is in the umbrella and a line in `NOTICE`
naming it. The server stays AGPL-3.0 (0027) and `ee/` stays Elastic 2.0
(0010). A library that cannot be used inside someone else's product is not
"useful elsewhere", which was the point. The one candidate this rules out
of the shared namespace is the credits ledger in `ee/`; if it is ever
extracted it is its own Elastic-licensed repository.

**Dependency direction.** Acyclic and pinned:

- standalone: `managoat_substitution`, `managoat_mcp_auth`,
  `managoat_broker`, `managoat_docs`, `managoat_oauth`;
- `managoat_acp` stands alone (transport is a callback; decided
  2026-09-02 in #1339 — the peer takes a writer function and is fed bytes
  by its owner, so the sandbox is the host's business, and this line as
  first written was a guess made before the peer was read);
- `managoat_runner` depends on `managoat_sandbox`;
- `managoat_runtimes` depends on `managoat_sandbox` (it writes files into
  and runs commands on the sandbox) and `managoat_acp` (the `initialize`
  params for the adapter it installed; decided 2026-09-02 in #1368);
- `fountain` depends on every library, and nothing depends on `fountain`.

A library holds no reference to `Fountain.*` or `FountainWeb.*`, reads no
`:fountain` configuration and emits no `[:fountain, …]` telemetry. A test
in `apps/fountain` walks every `apps/managoat_*` directory and fails on any
of the three (#1336).

**Configuration and telemetry.** A library reads its own otp_app
(`config :managoat_sandbox, …`) or takes an options map; `fountain`'s
`config/runtime.exs` populates it from the same environment variables as
before. A library emits telemetry under `[:managoat, :<name>, …]` and
`fountain` attaches its handlers there.

**Test support ships in the library.** `Fountain.Sandbox.Fake`,
`SandboxConformanceCase`, `FakeRuntime` and `FakeRunnerDaemon` are the most
valuable part of their packages; they move with the code, not into
`fountain`'s `test/support`.

**Order.** By how stable each seam is today: substitution (#1336, the
mechanics), sandbox (#1337), MCP authorization (#1338), ACP (#1339, after
the peer settles), broker (#1340, after #1148 decides native versus Agent
Vault client), runner protocol (#1341, after sandbox), docs (#1342), OAuth
(#1343), credits (#1344, optional).

**What stays.** The Ecto contexts (accounts, agents, environments, vaults,
team, connections' providers, conversations), the web layer and the API.
They are Fountain the product; their value is the tenant contract, not the
code.

**Not a rewrite.** The server is not rebuilt on the libraries in one
motion. Once the libraries take their weight out of `ConversationServer`,
what is left is orchestration, persistence and PubSub over library calls,
and that remainder is refactored in place with the suite green throughout.
A big-bang rewrite would spend months re-deriving the tenant, audit and
credit rules that `CLAUDE.md` lists as easy to get wrong.

## Consequences

- **The umbrella gains apps, and every gate has to see them.** Format
  (`subdirectories: ["apps/*"]` already), credo (`apps/*/lib/` already),
  dialyzer (root, already), the Dockerfile deps layer (one `COPY` per
  app's `mix.exs`, or `mix deps.get` fails in the image build), the release
  (transitive through `fountain`'s deps), and the test partitions. The
  partition scripts are written against `apps/fountain` and `ee/`; a
  library's tests run as their own step and export coverage into the same
  merge. #1336 settles each of these once.
- **Graduation is the moment the two-repository cost starts**, and it is
  deliberate: a seam graduates when it has stopped moving, not when it is
  extracted. Until then the umbrella gives the compile-time boundary at no
  release cost.
- **`Fountain.<Name>` modules disappear rather than delegate.** The
  libraries are not an API; nothing outside this repository calls
  `Fountain.Substitution`. A delegating shim would be a coverage hole
  with no caller.
- **Hex refuses git dependencies.** `managoat_sandbox` cannot publish while
  it depends on `{:sprites, github: "superfly/sprites-ex"}`; graduation
  needs a hex release of that client or a vendored one. Extraction into
  the umbrella is unaffected.
- **Two ACP packages already exist on hex.** Whether `managoat_acp` builds
  on one for its JSON-RPC and schema layer, or publishes the whole stack,
  is decided in #1339 before that library graduates. It does not gate
  extraction.
- **The credits ledger is the exception that proves the licence rule.** It
  is listed so the boundary is written down, not because extraction is
  assumed.
- **A second consumer now exercises the seams without Fountain.** The
  examples in `managoat/managoat_examples` compile only against Hex packages.
  The local-Port and sandbox transports share the same peer, and the Fake
  sandbox completes a scripted ACP turn in CI without provider credentials.

## Addendum (2026-10-12): the graduation tooling is removed

`scripts/graduate-library.sh` and `templates/managoat-library/` did their job
nine times and had no tenth use while extraction is paused. Both are deleted.
A future library starts its repository from an existing `managoat_*` one;
`contributing/component-libraries.md` ("Graduating a library") says what to
copy. The umbrella-first rule, the namespace, the licence and
the two-PR cost are unchanged.

## Addendum (2026-10-13): `managoat_substitution` comes back

`managoat_substitution` was extracted first because it was the smallest seam,
not because anything outside Fountain needed it, and nothing ever did: its one
caller is `Fountain.Conversations.McpServers`, and the hex package had one
release (0.1.0). By the paused-extraction test above (an independent consumer
or a release schedule of its own) it would not be extracted today, so it is
not kept extracted either. The module returns unchanged as
`Fountain.Substitution`, with its tests, and the hex pin is dropped; the
`managoat/managoat_substitution` repository is archived and 0.1.0 stays on
hex. The other libraries are unaffected; this is not a precedent for folding
back a library that has a second consumer.

## Addendum (2026-10-13): the umbrella-first rule is dropped

Fountain is self-hosted for a handful of users and no further extraction is
planned. The machinery kept "for the next one" guarded an umbrella that has
held no library app since #1345: `apps/fountain/test/fountain/umbrella_layout_test.exs`
defined no tests, `scripts/test-libraries.sh` exited 0 on every CI run, and
the coverage job counted zero sibling exports. All three are removed, with
the partition allocator's reserve for sibling suites. Should a subsystem ever
need extracting, it starts as a `managoat/managoat_<name>` repository copied
from an existing one, and Fountain takes it as a hex pin from its first
release; the decision's "Umbrella-first" rule no longer applies.
`contributing/component-libraries.md` keeps the library table and the
procedure for updating a library Fountain already pins. The namespace, the
licence and the two-PR cost are unchanged.

## Addendum (2026-10-15): acp, sandbox and runtimes come back

`managoat_acp`, `managoat_sandbox` and `managoat_runtimes` are folded back
into the server. The paused-extraction test above asks for an independent
consumer or a release schedule of its own, and these three had neither in
practice:

- **The two-PR cost was paid constantly.** Between graduating to hex on
  2026-09-02 and this addendum, `managoat_acp` published 16 releases,
  `managoat_sandbox` 15 and `managoat_runtimes` 25, and Fountain's
  `mix.lock` entry moved 12, 8 and 18 times. Every move was a library PR, a
  hex release and then a pin PR here, and the pin PR was the only place the
  release met Fountain.
- **No other consumer tracks current versions.** airlock is on acp 0.1.2,
  sandbox 0.2.1 and runtimes 0.3; goatherd and manasprites have been dormant
  since early September. The libraries' release schedule was Fountain's.

What came back is exactly the code Fountain ran: hex `managoat_acp` 0.6.0,
`managoat_sandbox` 0.5.5 and `managoat_runtimes` 0.5.7, identical to the
libraries' `v0.6.0`, `v0.5.5` and `v0.5.7` tags. It lives under
`apps/fountain/lib/managoat/` with every module name unchanged
(`Managoat.ACP.*`, `Managoat.Sandbox.*`, `Managoat.Runtimes.*`), so no
caller changed; a rename to `Fountain.*` would be a separate change. The
libraries' tests came with it into `apps/fountain/test/managoat/`, and the
sandbox adapters' billed live suites into `apps/fountain/test/live/`, still
tagged `:live` and excluded by default. The test-only modules (the sandbox
`Fake` and `ConformanceCase`, `FakeRuntime`, `ScriptedAgent`) moved to
`test/support/`, since nothing outside a test uses them now. Left out: the
Daytona sandbox adapter and the opencode runtime, which Fountain had already
removed, and the libraries' release scaffolding (release scripts, publish
workflows, their own NOTICE and CHANGELOG, mix aliases).

The adapter settings that were read from the library's own app
(`config :managoat_sandbox, Managoat.Sandbox.Sprites, ...`) are now read from
`:fountain` under the same module keys, and the adapter map is
`config :fountain, :sandbox_adapters`. The libraries started no processes of
their own, so nothing moved into the supervision tree. The live adapter
suite stays the gate for ACP and runtimes behaviour, now on a change to
`lib/managoat/acp/` or `lib/managoat/runtimes/` rather than on a pin bump
(`contributing/component-libraries.md`).

The three repositories and hex packages were not archived or retired by
that change; the same day, after v0.24.0 shipped it, every release of the
three was retired on hex as deprecated (a one-off workflow, #2748; the
releases stay installable and `mix deps.get` warns) and
`managoat/managoat_acp`, `managoat_sandbox` and `managoat_runtimes` were
archived on GitHub with a README pointing here. `managoat_broker`, `managoat_docs` and `managoat_oauth` stay hex
pins: their pins move rarely, and nothing here says they should come back
(`managoat_oauth` did, for its own reasons: the next addendum).

## Addendum (2026-10-15): `managoat_oauth` comes back

Jake decided on 2026-10-15 to bring `managoat_acp`, `managoat_sandbox`,
`managoat_runtimes` and `managoat_oauth` back into the server, and to keep
`managoat_broker` and `managoat_docs` on hex. This addendum records the
`managoat_oauth` part; the addendum above records the other three.

`managoat_oauth` had one consumer: neither goatherd nor `managoat_examples`
depends on it. Fountain pinned 0.1.2. The grant state machine and its two
schemas are back as `apps/fountain/lib/managoat/oauth/`
(`Managoat.OAuth.Codes`, `.Device`, `.AuthorizationCode`, `.DeviceGrant`).
The module names stay, and any rename is a separate change. The hex pin is
dropped. The tables and migrations do not change. Fountain's migrations
always created the two tables themselves, so `Managoat.OAuth.Migration` had
no caller here and is not carried over.

With the library in-tree, the seam's indirection did nothing, so it is
removed with no change in behaviour:

- The `use Managoat.OAuth` macro, its generated instance functions, the
  `defoverridable` overrides in `Fountain.OAuth` and the per-call
  `Managoat.OAuth.Config` struct are gone. `Fountain.OAuth` delegates to
  `Codes` and `Device`, which use `Fountain.Repo`. The client registry is
  read by `Fountain.OAuth.config_clients/0`.
- The redirect check runs once. `Fountain.OAuth.validate_request/2` checks
  the client, development mode, `redirect_registered?/2` and PKCE in that
  order. `Codes.authorize/4` takes the validated client's id and does not
  validate again. That removes `Managoat.OAuth.Clients` and the
  `grant_client/2` workaround, which existed only to keep the library's
  exact-match check in agreement with Fountain's RFC 8252 loopback rule.
- The `Managoat.OAuth.Host` behaviour had a single implementation and
  nothing injected through it, so it is removed. `Fountain.OAuth.Host` stays
  as an ordinary module and the state machine calls it directly. It is still
  the one place that knows a token is an API key and how the three grant
  events are recorded, so the state machine names neither of them.
- Functions nothing in Fountain called are not carried over:
  `prune_expired`, `redirect_origins`, `device_interval_seconds`, the
  `Config` loader's errors and the migration helper. Expired codes and
  device grants were never pruned before the fold either; they stay in
  their tables until something sweeps them.

**Why not an off-the-shelf server.** Boruta has no RFC 8628 device grant,
which the CLI login needs. It also issues its own tokens rather than
Fountain API keys, and it brings flows Fountain would have to disable. An
external identity provider would add a service to every self-hosted
instance. The in-tree state machine is two modules and two tables.

## Alternatives considered

- **Straight to separate repositories.** Faster to a public repo; every
  cross-seam change is two PRs from day one, on seams that are still
  moving. The umbrella step costs nothing and defers that.
- **Keep the `Fountain.*` namespace and publish `fountain_*` packages.** The
  cheapest move, and every library would carry the product's name into
  someone else's codebase. Renaming later is a breaking change on every
  consumer.
- **MIT instead of Apache-2.0.** Equivalent for consumers; Apache-2.0
  carries the patent grant, and the CLI and SDK already use it.
- **AGPL for the libraries too.** Uniform copyleft, and no downstream
  product could use them. That is the opposite of the goal.
- **Rewrite the server on the libraries in one pass.** See "Not a
  rewrite" above.
- **Extract `Conversations` too, as "the orchestrator".** It is the
  product's persistence and lifecycle model over the tenant tables; there
  is no second consumer for it.
