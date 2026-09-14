---
type: ADR
title: "First-party extensions: Buzz becomes an OTP app installed at build time and enabled at runtime"
description: "Buzz leaves the Fountain core as fountain_buzz, an AGPL OTP application depending on :fountain that the host reaches only through eleven Fountain.Extension callbacks. Build-time install, runtime enable, no hot code loading. The bundled image keeps every Buzz path, command and provider behavior; a new -core image carries none of it. Built so far: gates 2, 3 and 4 — the seam, migration and OpenAPI composition, and the move itself: apps/fountain_buzz exists and core names no FountainBuzz module. A second extension, fountain_support, moved the problem-report feature out under three of the ten callbacks and added none. Every gate but the repository split is built: the supply chain, the -core image and its release tags, the manual as a callback, and core marketing that renders only what its distribution can serve."
tags: [buzz, extensions, packaging, architecture, licensing, support]
status: stable
adr: "0043"
adr_status: "Accepted"
date: 2026-09-03
generated: { by: claude-opus/5, at: 2026-09-04T00:00:00-04:00 }
verified: { by: claude-opus/5, at: 2026-09-04T00:00:00-04:00 }
stale_after: 2026-12-04
---

# 0043 — First-party extensions: Buzz becomes an OTP app installed at build time and enabled at runtime

**Status:** Accepted — **partially built.** Gates 2, 3 and 4 (#1505, #1506,
#1507) are built, and so is the second extension (#1528, `fountain_support`),
which used three of the ten callbacks and added none. `Fountain.Extension` (now eleven callbacks — see decision 3 and ADR 0054),
`Fountain.Extensions`, the authenticated dispatch, the conversation MCP
fan-out, `Fountain.Migrations` and `FountainWeb.ApiSpec.Compose` exist; and
Buzz has moved: `apps/fountain_buzz` is an AGPL OTP application depending on
`:fountain`, `apps/fountain/lib` names no `FountainBuzz.*` module (a guard test
enforces it), and the bundled release includes both apps.

Gate 5 (#1509) is built too: the extension owns its `buzz-acp` pin, its fork
override and the paths its binaries install to, and `BUNDLE_EXTENSIONS=false` builds
a core image — no extension application in the release, no binaries in the
image, one switch for both halves. Both images were built and their contents
checked.

Gate 7 (#1510) is built: the `-core` release tags (`vX.Y.Z-core`), the manual
as the tenth callback (#1548), and decision 8's marketing rule (#1525) — core
copy that needs an extension declares it and renders only where it is
installed, asserted on the running core release by the `core-distribution` CI
job. The repository split is deliberately not done; #1550 tracked it and
was closed as not planned on 2026-09-14, so this ADR is the record.

Gate 7's distribution half is built too: CI builds and boots a core release
against an empty database on every PR, and each release publishes
`vX.Y.Z-core` and `vX.Y-core` beside the bare tags, with the published core
image opened and checked for extension applications and native assets.

The docs move is built too: `docs/0` (see decision 3) and `Fountain.Manual`,
with Buzz's two pages living in `apps/fountain_buzz/docs/` and served at the
URLs they always had.

**Not built:** the graduation to `BinaryBourbon/fountain_buzz`, which is
deferred rather than blocked — its precondition was met by `fountain_support`
(#1528), and the maintainer has chosen to keep the extensions in this
repository for now. #1550 carried that deferral and was closed as not planned
on 2026-09-14; there is no open issue for the split, and none is needed until
someone wants it. The Go CLI split is #1508.

ADR [0020](0020-buzz-as-a-client-of-the-acp-gateway.md)'s hosted harness and
brokered signer ship in the image today and keep working unchanged throughout.
The "what Buzz occupies today" inventory in *Context* was read off `main` at
e44c5c89 and is accurate as of 2026-09-03; the PR that builds each gate removes
the corresponding caveat here.

## Context

### Buzz is a product integration wearing a core's clothes

ADR 0020 decided that Fountain hosts `buzz-acp` and brokers the Nostr signature,
so an agent's whole Nostr presence runs at the gateway and the sandbox holds
neither the relay connection nor the identity key. That decision was right and
is live. The way it landed is the problem: it landed *in the core*, and it now
crosses every layer of the server.

Read off `main`, the surface is:

| Layer | What Buzz owns there |
|---|---|
| Context | `Fountain.Buzz` (534 lines), `Fountain.Buzz.{BuzzIdentity,BootSweep,Harness,Manager,Mcp}` (909 lines) |
| Supervision | `Fountain.Application` starts `Fountain.BuzzRegistry`, `Fountain.BuzzSupervisor` and `Fountain.Buzz.BootSweep` |
| Turn assembly | `Conversations.McpServers.fountain_served/2` calls `Fountain.Buzz.conversation_mcp_servers/2` first of four |
| HTTP | `FountainWeb.Router` declares `/api/buzz/agents` (4 actions) and `/api/mcp/buzz/:conversation_id` |
| OpenAPI | `FountainWeb.Schemas` defines `BuzzIdentity`, `BuzzProvisionRequest`, `BuzzAccessUpdateRequest` and two response wrappers |
| Database | `buzz_identities` and two ALTERs, in the main `priv/repo/migrations` path |
| Config | `config/runtime.exs` sets `:buzz_acp_path`, `:buzz_acp_base_url`, `:fountain_cli_path` |
| Assets | `priv/buzz-acp-launch.sh`, `priv/buzz-base-prompt.md` |
| Image | a `buzzacp` Docker stage, `buzz-acp.version` / `buzz-acp.source`, `.github/workflows/buzz-acp-publish.yml`, a smoke check in the runtime layer |
| Go CLI | `cli/internal/cmd/buzz.go` and `cli/cmd/buzz-backend-fountain` |
| Docs | `docs/integrations/buzz.md`, `docs/catalog/mcp-servers/fountain-buzz.md`, a `/buzz-launch` marketing page |

Two facts about that table are load-bearing for what follows.

**The host→Buzz call surface is already tiny.** Outside `lib/fountain/buzz/`
and the two Buzz controllers, the core references Buzz in exactly three places:
the three child specs in `Fountain.Application`, one line in
`Conversations.McpServers`, and two `resources`/`post` lines in the router. The
mess is not entanglement; it is *placement*. That is why an in-process
extraction is credible at all.

**The Buzz→host call surface is small and ordinary.** `Fountain.Buzz` uses
`Accounts`, `Agents`, `Vaults`, `Environments`, `Conversations`, `Crypto`,
`Audit` and `Repo` — public tenant-scoped context APIs, the same ones a
third-party extension would use. It reaches nothing private.

### Why this is not ADR 0037's problem

ADR [0037](0037-component-libraries.md) extracted nine subsystems as
`managoat_*` libraries: Apache-2.0, `Managoat.*` namespace, **no reference back
into Fountain**, published on hex for anyone. Buzz fails every one of those
tests. It owns a table and a tenant-scoped context; it calls eight Fountain
contexts by name; it is useful to precisely one product. Packaging it as a
`managoat_*` library would either strand the database half in core (leaving the
product integration exactly where it is) or push Fountain's schema and contexts
into an Apache library that pretends to be reusable.

So Buzz needs the other shape: not a *component library* Fountain depends on,
but an *extension* that depends on Fountain.

### Why decide now rather than during the extraction

[#1502](https://github.com/BinaryBourbon/fountain/pull/1502) is open and adds a
per-tenant ceiling and a credit gate to hosted Buzz agents. Every such change
deepens the crossing and makes the boundary harder to draw later. More to the
point, the six implementation gates on #1503 each contain an architectural
question — where do migrations run, who owns the OpenAPI paths, what does the
router forward, what happens to the CLI — and answering those one PR at a time
is how a boundary gets decided by accident. This ADR answers them once so the
gates are implementation.

## Decision

**Fountain grows a first-party extension seam: an extension is an OTP
application that depends on `:fountain`, is chosen at build time, enabled by
configuration at runtime, and reached by the host only through a fixed set of
`Fountain.Extension` callbacks. Buzz is the first one.**

### 1. Build-time install, runtime enable. Hot installation is out of scope.

An extension is compiled into the release. Enabling it is a configuration
change; installing it is a rebuild. Hot code installation into a running
release — fetching a package, loading BEAM files, running its migrations,
composing its routes, rolling that back on failure, and carrying native
executables through all of it — is **explicitly not being built**, and this ADR
is the record that it was considered and declined (see *Alternatives*). Nothing
in the callback set below assumes a future in which it becomes possible; if it
ever does, that is a new ADR.

### 2. The host knows descriptors, never modules

```elixir
# config/runtime.exs — the bundled distribution
config :fountain, :extensions, [FountainBuzz.Extension]
```

`apps/fountain` contains no reference to `FountainBuzz` in any form: not a
module, not an atom, not an alias in a comment. It reads the configured list
and calls the behaviour. The direction is `fountain_buzz -> fountain`, and the
umbrella's dependency resolution proves it at compile time.

### 3. `Fountain.Extension` has ten callbacks, and no eleventh without an ADR

Each replaces exactly one thing the core hard-codes today.

| Callback | Replaces | Contract |
|---|---|---|
| `id/0 :: atom()` | — | Stable identifier. Namespaces routes, telemetry and error payloads. `:buzz`. |
| `enabled?/0 :: boolean()` | `File.exists?(buzz_acp_path)` in `runtime.exs` | Asked before every dispatch, so it must be cheap. An installed-but-not-enabled extension mounts nothing and contributes nothing, and is indistinguishable from an absent one — answering `false` is a supported state, not an error. |
| `migrations/0 :: [{otp_app, path}]` | `buzz_identities` sitting in the core migration path | Appended after the core's at every entrance — the boot migrator's `:migrator` hook, `Fountain.Release.migrate/0` and `rollback/2`, and `mix ecto.migrate` / `ecto.rollback` / `ecto.setup` — so core ordering never depends on an extension being present. One `schema_migrations` for everyone, so version numbers are global; moving a file between paths never re-runs it, because Ecto matches on version and never on path. |
| `api_mounts/0 :: [{path, plug}]` | the router's Buzz lines | One to three lowercase static segments under `/api`, and the Plug behind each. Mounted **inside** the existing `:api` pipeline by `FountainWeb.Plugs.ExtensionDispatch`, declared last so core routes always win, longest mount matching first, and called with the mount moved from `path_info` to `script_name`. Authentication, the rate limit, `current_user` and the request audit stay host-owned; there is no path an extension can choose that reaches its plug without them. Validated at boot for shape, uniqueness and overlap with a core route **in either direction**, so a bad mount is a failed deploy rather than a route that quietly serves nothing. |
| `openapi_paths/0 :: OpenApiSpex.Paths.t()` | `Paths.from_router(Router)` seeing Buzz routes directly | Absolute; the host refuses any path outside the extension's own mounts, so a described path and a served path cannot drift. Merged after the core resolves, with a path or component-title collision raising rather than letting the last writer win. **This callback exists because a forward is opaque:** `Paths.from_router/1` reads `router.__routes__()`, and the host's `forward` is one route whose plug exports no `open_api_operation/1`, so it is filtered out and the mounted routes are invisible. Verified in `deps/open_api_spex/lib/open_api_spex/path_item.ex`. |
| `docs/0 :: module() \| nil` | `docs/integrations/buzz.md` and `docs/catalog/mcp-servers/fountain-buzz.md` in the host's manual | A `Managoat.Docs` instance over the extension's own `docs/`, merged by `Fountain.Manual`. Sections merge by title, so a moved page keeps its place; a slug the core manual serves, and a mount other than `/docs`, are refused at boot. |
| `conversation_mcp_servers/2 :: [map()]` | the `buzz/2` clause in `Conversations.McpServers` | The one hot-path callback. Called per turn kick with the conversation id and callback token; returns `[]` for a conversation the extension does not claim. Host order is fixed: extensions first, in configured order, then team, team comms, caller. |

**Amended 2026-09-03 (#1507): three more callbacks, and one prefix became
mounts.** Building the move found three things the six could not express.

`api_prefix/0` + `api_plug/0` became `api_mounts/0`, because Buzz serves both
`/api/buzz/agents` and `/api/mcp/buzz/:conversation_id` and the second is not
under the first — one prefix could not express the surface decision 6 promises
to keep. `openapi_paths/0` became absolute in the same change, since prefixing
mount-relative paths has no meaning for an extension holding two mounts;
the host now checks each described path against the mounts instead, which is
the stronger form of the same property.

`admin_overview/0` and `admin_user_columns/0` exist because #1017 and #1519 put
two Buzz figures on the admin pages while this campaign was in flight — a
running-harness count and a per-account identity count, both measuring a
standing OS process no sandbox meter reports. Moving Buzz would otherwise have
deleted the only view an operator has of it. Extensions hand the console
**data**; the console owns every element of the markup.

`oban_cron/0` exists because the reconciliation sweep (#1017) is scheduled from
`config :fountain, Oban`, and a core-only release naming a worker module it does
not carry is a crash on start rather than a missing feature. The host merges
extension entries into its own cron at boot.

**Supervision is not a callback (amended 2026-09-03, #1505).** This table
originally carried a seventh entry, `children/1`, aggregating the extension's
supervision subtree into `Fountain.Application`. Building #1505 replaced it
with the OTP application dependency that was already there: `fountain_buzz`
depends on `:fountain`, so OTP starts the host first and stops it last with no
callback at all. That buys the same ordering guarantee, keeps a crash in an
extension's supervisor off the host's tree by construction rather than by a
`:temporary` child spec, and fixes something the callback had backwards — an
extension's processes now start *after* the Endpoint, which is what a harness
talking HTTP back to this server actually needs. The host aggregates no
extension children.

**Amended 2026-09-04 (#1510): a tenth, for the manual.** `docs/0` returns a
`Managoat.Docs` instance whose pages and nav join `/docs`. The alternative this
ADR allowed — a build-time step copying an extension's pages into the host's
`docs/` — was rejected on inspection: it makes the *repository* the thing that
varies, so `docs/` in git either carries pages a core distribution must not
serve or carries nav entries pointing at files that are not there, and the
guardrails that walk it both ways have to be taught which is which. Embedding
each manual in its own module puts the variation where the rest of the
distribution's already is: a core image has no extension module, so its manual
is complete rather than pruned, and nobody has to remember to run a step.

`Fountain.Manual` is the composition point, as `FountainWeb.ApiSpec.Compose` is
for the OpenAPI document, and every renderer asks it instead of
`Fountain.Docs`. Sections merge by title so a moved page keeps its place in the
sidebar; a slug the core manual already serves, and a mount other than the
host's, are refused at boot.

One consequence worth stating plainly: **a core page may not link to an
extension's page.** `Fountain.DocsTest` walks the core manual alone, so such a
link is a dead link on a core distribution and fails there; the extension's own
suite runs the link checks over the merged manual, which is where a link in the
other direction is legitimate. Thirteen such links existed when Buzz's two
pages moved, and the guardrail found all of them.

**Three callbacks that will not be added.** No callback that wraps or vetoes a
host mutation — an extension may call `Fountain.Audit`, `Billing.check_spend/1`
and the context APIs, and may not interpose on them. No second hot-path
callback beyond `conversation_mcp_servers/2`. No callback that returns SQL,
Ecto queries or schema modules for the host to run.

**Amended 2026-09-04 (#1529): a contribution is an HTTP server, never a stdio
one.** `conversation_mcp_servers/2` reaches a runtime by exactly one path:
`Conversations.McpServers.for_session/3` appends it after ACP conversion, into
`session/new`'s `mcpServers`. It never reaches the sandbox's provisioned
configuration — `write_runtime_config` is called with the agent's own servers
and nothing else, at provision and again on wake.

On the claude runtime that path is half broken upstream. `claude-agent-acp`
never launches **stdio** servers passed through `session/new`
(`Managoat.Runtimes.Quirks` `:claude_mcp_via_files`,
agentclientprotocol/claude-agent-acp#883), which is why the agent's own servers
are written into the sandbox as a project `.mcp.json` instead. The HTTP half
works, and that was measured rather than assumed before a third extension was
designed against it: the team tools are contributed through this callback, are
never written to that file, and answer on claude conversations in production —
211 `mcp__fountain-team__*` log events, 28 of them carrying a successful tool
response, read 2026-09-04.

So an extension **may contribute an HTTP MCP server and may not contribute a
stdio one.** A stdio contribution is not refused; it is silently dropped on one
runtime, which is the worst shape a broken contract can take. An extension that
needs a process inside the sandbox owns getting it there itself. This is a
constraint on the existing callback rather than a new one, and it stops being
necessary — rather than becoming wrong — the day #883 lands and
`Managoat.Runtimes.Claude.write_config/2` goes away.

The callback set has now survived three extractions without an eleventh
entry: the Gmail extension, specified here as `fountain_gmail` (#1529)
against `api_mounts/0` and `conversation_mcp_servers/2` before it existed,
was built as `apps/fountain_google` under #2152 with #1529 (amended
2026-09-14) on exactly those two plus `docs/0`, and added nothing. The name
is the provider's rather than the product's because one Google connection
covers Gmail and Calendar, and the Google connection provider itself follows
into the same app. What it took from core with it is the meaning of
the connection-only `mcp_servers` shape: `Fountain.Connections.McpServers`
now drops `%{"connection" => id}` with no URL rather than rewriting it, and an
extension that recognises the connection's provider serves the sandbox an HTTP
server through the callback. The remote shape (URL + connection) stays core's.

**Amended 2026-09-14 (#2152, ADR 0054): an eleventh, for connection
providers.** `connection_providers/0` returns config-backed
`Fountain.Connections.Provider` structs that the host lists beside its own
platform providers, reserves the slugs of, and drives with the one OAuth
client. It exists so the Google, Microsoft and Slack providers can leave core
with the products behind them; it is not a hot-path callback, wraps no host
mutation and returns data, so it stays inside the three rules above. The
decision, the validation and the convention for configuration are ADR 0054's.

### 4. `fountain_buzz` starts at `apps/fountain_buzz` and may graduate

It begins as an umbrella app, for the same reason every `managoat_*` library
did (ADR 0037, CONTRIBUTING "Adding an umbrella library app"): the compiler
proves the boundary while the host contract is still moving, and a change on
both sides of the seam is one PR rather than a release dance. It graduates to
`BinaryBourbon/fountain_buzz` — **not** `managoat/` — once `Fountain.Extension`
has stopped changing and a second consumer or a second extension has exercised
it. Until then it is `{:fountain_buzz, in_umbrella: true}` in
`apps/fountain/mix.exs`, and, unlike a library, `apps/fountain` may declare it
only in the *bundled* build (see decision 7).

`apps/fountain/test/fountain/umbrella_layout_test.exs` walks `apps/managoat_*`
and does not apply. `fountain_buzz` gets its own guard, asserting the rules that
actually bind it: `apps/fountain/lib` mentions no `Buzz` or `FountainBuzz`
identifier, declares no Buzz route, and holds no Buzz migration.

**Amended 2026-09-04 (#1528): `fountain_support` is the second one, and it
starts the same way.** The problem-report feature — `Fountain.Support`, its
table, its controller, its OpenAPI schemas and its forwarder — became
`apps/fountain_support`, an AGPL umbrella app under `FountainSupport.*` on the
same terms. It exists to prove the seam against a second feature *without*
widening it: it implements `api_mounts/0`, `migrations/0` and `openapi_paths/0`
and inherits the contribute-nothing default for the other six. In particular it
needs no `oban_cron/0` entry, because its one background job is enqueued by its
own context rather than scheduled from the host's configuration; and it starts
no processes, so its `mix.exs` declares no `mod:` at all.

Two things the second extraction settled that the first did not have to:

  * **Shared configuration stays the host's.** `SUPPORT_GITHUB_REPO` and
    `SUPPORT_GITHUB_TOKEN` exist for this feature and moved to
    `:fountain_support` with it. `SUPPORT_EMAIL` did not: the account emails and
    the team-comms replies name the same address (#450), so it stays
    `config :fountain, :support_email` and the extension reads it the way any
    caller would. The rule is that a key with one consumer moves and a key the
    host also reads does not — the alternative is one env var writing two config
    keys, or core reading an extension's.
  * **A core guardrail with an extension row moves the row, not the rule.** The
    audit guardrail's `support.report.created` entry, four schema-enum rows, two
    envelope entries and one schema-guard allowlist line each left core for
    `FountainSupport.BoundaryTest`, which checks the same properties from the
    extension's side. That is the same treatment #1507 gave Buzz's seven, and it
    is why an extension needs a boundary test rather than only a guard test.

### 5. AGPL-3.0-or-later, `FountainBuzz.*`, and not a component library

`apps/fountain_buzz/lib` is AGPL-3.0-or-later, like `apps/fountain` (ADR
[0027](0027-agpl-relicensing.md)). It is Fountain-specific product code that
depends on the server; a hosted fork that changes it owes those changes back for
the same reason it does for the server. It carries no hex publication and no
promise of reusability, and it is not named `Managoat.*` — that namespace means
"Apache-2.0 library that does not know Fountain exists", and applying it here
would make the one meaningful thing about the name untrue.

The Go clients keep ADR 0027's other half. `cli/` and whatever `cli/` becomes in
a graduated `fountain_buzz` repository stay **Apache-2.0**: 0027 licenses by
artifact kind, not by repository, and an integrator writing against the Buzz API
should carry no obligation. This repository already holds AGPL `apps/fountain`
beside Apache `cli/`; a graduated extension repository holds the same pair.

### 6. What the bundled distribution promises

The bundled release is **behaviour-compatible across the extraction**. Named
exactly, so a gate PR can be judged against it:

- **HTTP paths are unchanged.** `/api/buzz/agents` (index, create, update,
  delete) and `/api/mcp/buzz/:conversation_id` keep their paths, verbs, request
  and response bodies, status codes and error shapes. The extension mounts at
  those paths; it does not get a `/api/ext/buzz/...` prefix and a redirect.
- **OpenAPI operations are unchanged.** Same `operationId`s, same schema titles
  (`BuzzIdentity`, `BuzzProvisionRequest`, `BuzzAccessUpdateRequest`), same
  positions in `/api/openapi.json`. **The published spec is the bundled spec** —
  the four SDKs generate from it (#1411), so a rename here is an SDK break, and
  there is to be none.
- **The provider protocol is unchanged.** `buzz-backend-fountain` keeps
  protocol_version 1, its `info`/`deploy` ops, and convergence on the Nostr
  pubkey. Buzz's desktop must not notice.
- **`fountain buzz agents ...` keeps working**, from the same `fountain` binary.
- **The Nostr trust boundary is unchanged.** The nsec stays in a vault,
  decrypted server-side into the harness process env; `buzz-acp` holds the relay
  connection; nothing about the identity enters a sandbox. ADR 0020's whole
  point survives the move or the move is wrong.
- **Audit, tenant scoping and billing are unchanged.** `buzz_identity.created`
  / `.updated` / `.deleted` keep their event names and `resource_type:
  "buzz_identity"`; the actors `system:buzz_harness` and
  `system:buzz_boot_sweep` stay in ADR [0013](0013-audit-trail.md)'s closed
  vocabulary, recorded through `Fountain.Audit` — the extension does not get a
  trail of its own. `Billing.check_spend/1` remains the gate.
- **Buzz stays included by default**, in the image the hosted deployment runs
  and every existing self-hoster pulls.

Two things this ADR **declines** to promise, against the tracker's first
reading:

- **The Go CLI does not move for the sake of moving.** `fountain buzz` is a
  thin HTTP client against `/api/buzz/agents` with no Nostr code and no server
  state; subtracting a subcommand from a released binary is a user-visible break
  with nothing bought. It stays in `cli/`, documented as a bundled-distribution
  command that answers `404` against a core server, and stays covered by
  `cli/internal/cmd/docs_test.go`'s diff against `docs/cli.md`.
  `buzz-backend-fountain` is a separate `main` package with its own release
  artifact that Buzz's desktop discovers by name on `PATH`, never through
  `fountain`, so it *does* move to the extension's ownership with no
  compatibility question at all. **#1508 should be rescoped to that split**
  rather than moving both.
- **`conversation_mcp_servers/2` ordering is a host decision, not a promise to
  the extension.** Buzz is first today because it was written first. The
  callback contract fixes "extensions before team", not "Buzz before
  everything".

### 7. Two images from one repository; uninstall is a config change, not a migration

**Distribution.** Built. `ghcr.io/binarybourbon/fountain:vX.Y.Z` stays the **bundled**
image — extension compiled in, `buzz-acp` and `buzz` binaries present — because
that is what runs in production and what every existing tag has meant.
`…:vX.Y.Z-core` is the same tree built without `apps/fountain_buzz` and without
the `buzzacp` Docker stage. Same repository, same version, a tag suffix rather
than a second image name, so nobody has to decide which product they are
running.

**Support.** The bundled image is what the maintainer runs and what a bug report
is triaged against. The `-core` image is CI-verified to boot, migrate, serve
`/api`, pass the OpenAPI validation and run a conversation to completion with no
Buzz application, table or native binary present; it is the supported base for
anyone writing their own extension. A Buzz-shaped report against `-core` is
closed as not-installed, not as a bug.

**Uninstall.** Removing an extension from `:extensions` stops its supervision
subtree, unmounts its routes and drops its OpenAPI paths. It does **not** roll
anything back and does not delete a row.

- **Migrations stay applied.** `buzz_identities` is tenant data, not extension
  scaffolding. Rolling it back is an explicit operator act against the
  extension's migration path, never a side effect of a config change or an
  image swap, and a bundled→core downgrade leaves the table present and unused
  so that swapping back converges instead of reprovisioning.
- **Identity rows survive, and keep cascading.** The foreign keys to `users`,
  `agents` and `vaults` are `on_delete: :delete_all` in the schema, so ADR
  [0009](0009-account-deletion-and-export.md) account deletion stays correct
  whether or not the code that reads the table is loaded. This is the reason
  the table is not conditional on the extension.
- **The one thing uninstall must do is stop.** Harnesses terminate, so the
  agents' Nostr presence leases expire at the relay within 180s rather than
  leaving a hosted agent that looks online and answers nothing.
- **A core release that never installed the extension never creates the
  table**, and its account deletion is correct for the same reason: there is
  nothing to cascade.

### 8. Core-owned marketing declares the extension it needs

Built (#1525). Two images means the sales copy is a distribution question too.
`/buzz-launch` is a campaign page entirely about one extension, and the Nostr
card on `/integrations` advertises `POST /api/buzz/agents` — a path decision 7's
own core release answers `404`. Marketing that sells an endpoint the image does
not serve is marketing that lies, and #1510 had already forced a partial answer
by making three core marketing links point at a manual page core no longer
carries.

The rule: **core-owned marketing content carries `requires_extension: <id>`,
and renders only where that extension is installed.** A whole page gates its
route (`/buzz-launch` raises `NoRouteError`); a section or a card drops out;
prose neither counts nor enumerates what varies, because a number is wrong on
one image or the other.

Two properties make this consistent with decision 2 rather than a hole in it:

- **The argument is an id, not a module.** `Fountain.Marketing.available?/1`
  takes a value out of `config :fountain, :extensions`, so core still names no
  extension code and the guard test stays green. This is what `id/0` is for.
- **A gated page may link the extension's manual again.** The route gate runs
  first, so every reader of `/buzz-launch` is on a distribution that serves
  `/docs/integrations/buzz`. #1510's rule — a *core* page must not link an
  extension's page — is unchanged; a page that only exists alongside the
  extension is not a core page in the sense that rule means.

This deliberately **inverts** `FountainWeb.Plugs.ExtensionDispatch`, which
answers one uniform `404` for every unknown `/api` path precisely so a client
cannot read the installed set off a status code. That is right for an API and
wrong here: marketing is public copy about this deployment, and the failure it
must avoid is claiming a capability that is absent, not disclosing one that is.

The `core-distribution` CI job asserts it on the running core release, beside
the OpenAPI check and guarded the same way: if no card declares
`requires_extension` any more, the check fails rather than passing on nothing.

## Consequences

- **The compiler becomes the boundary check, in one direction only.**
  `fountain_buzz -> fountain` is enforced by dependency resolution.
  `fountain -/-> fountain_buzz` is enforced by a guard test, because a stray
  atom, string or comment compiles fine. That test is part of gate #1507, not
  an afterthought.
- **The host grows a seam it did not have, and pays for it.**
  `Fountain.Application`, `Fountain.Release`, `FountainWeb.Router`,
  `FountainWeb.ApiSpec` and `Conversations.McpServers` each gain an extension
  dispatch. Five small indirections in exchange for one product integration
  leaving the core, and for the next one costing nothing.
- **The release matrix roughly doubles.** Two images per tag, two boot checks.
  The `-core` build is cheaper (no `buzzacp` stage, no downloaded binaries) but
  it is a second thing that can go red on a release, and the release-verification
  memory of this repo says an image that fails to build silently is the failure
  mode to design against.
- **`Fountain.Buzz` → `FountainBuzz` renames modules, not data.** Audit event
  names, `resource_type` strings, table and column names, config keys, env var
  names and API field names all stay. A rename that reached any of those would
  break decision 6.
- **`ee/` and the extension are independent axes.** Credits (`ee/`, Elastic
  2.0) gate hosted Buzz agents through `Billing.check_spend/1`, a host API; the
  extension (AGPL) calls it like any other caller. Neither directory learns
  about the other.
- **This is the template for the next one, and #1528 is the next one.**
  `fountain_support` moved the problem-report feature out with three of the nine
  callbacks and no tenth, which is the evidence decision 3 asked for: the seam
  fits a second feature without widening. Team comms, the Gmail tools and the
  caller-tool bridge sat in the same `fountain_served/2` list with the same
  shape; none of them moved in this campaign. The Gmail tools moved later, as
  `fountain_google` (#2152, amended 2026-09-14), on the same three-callback
  shape; team comms and the caller-tool bridge stay core's.
- **What we give up:** a `managoat_buzz` library that other people could use.
  Nothing about hosted Buzz agents is useful without Fountain's tenants,
  vaults, agents and conversations, so there was nothing there to give.

## Alternatives considered

- **Leave Buzz in the core.** Rejected: it is the only place in the server
  where one external product's integration owns a supervision tree, a table, a
  route namespace, OpenAPI schemas, two native binaries and a CI workflow. Every
  new Buzz feature widens that, and a self-hoster with no interest in Nostr
  ships and boots all of it.
- **A database-free `managoat_buzz` component library (ADR 0037's shape).**
  Rejected: it would extract the process and tool layer, which is the easy
  half, and leave `Fountain.Buzz`, `buzz_identities`, the controllers, the
  routes and the OpenAPI schemas exactly where they are. The core would keep
  every crossing this campaign exists to remove, and gain a package boundary in
  the middle of the harness.
- **An external sidecar or service.** Rejected for the first extraction, not
  forever. It gives the strongest boundary and takes on the most: its own
  datastore or a second path into Fountain's, its own delegation of tenant
  scoping and audit, network hops inside a turn, its own deployment, health,
  scaling and on-call. ADR 0020 already decided the harness lives inside the
  Fountain OTP app rather than a sidecar (gate 2, 2026-08-16), for reasons —
  vault decryption server-side, `Lifecycle` as the reaper backstop — that have
  not changed.
- **Runtime / hot plugin installation.** Deferred with no date. It would need
  package fetch and verification, code loading, migration execution and
  rollback, route and spec recomposition, and native asset placement in a
  running container — and the only user need it would serve is one nobody has
  asked for, since the people who install extensions here are the people who
  build the image. Decision 1 is the record; revisit only against a concrete
  demand.
- **Ship two products with two names** (a "Fountain" and a "Fountain Buzz
  Edition"). Rejected: one product, one version, one tag suffix. Two names
  would make every issue start with "which one are you running".

## Gates

Each gate is a sub-issue of [#1503](https://github.com/BinaryBourbon/fountain/issues/1503),
each leaves bundled behaviour green. Every gate below is built except the
repository split (#1550, closed as not planned on 2026-09-14), which is
deliberately deferred.

1. **#1504 — this ADR.** Accepted and indexed.
2. **#1505 — the seam.** `Fountain.Extension` with `id/0`, `enabled?/0`,
   `api_prefix/0`, `api_plug/0` and `conversation_mcp_servers/2`; the host
   dispatches for each; fixture extensions in `test/support` prove the
   contract without Buzz. **Built** ([#1515](https://github.com/BinaryBourbon/fountain/pull/1515)),
   which also dropped the `children/1` callback for the OTP application
   dependency (see decision 3) and made `api_scope/0` the two callbacks
   `api_prefix/0` + `api_plug/0`, so the host validates the prefix without
   unpacking a tuple.
3. **#1506 — composition. Built** ([#1517](https://github.com/BinaryBourbon/fountain/pull/1517)).
   `migrations/0` and `openapi_paths/0`: the migrator runs extension paths after
   the core's at all four entrances, and the spec merges extension paths after
   the router's with collision detection on both paths and component titles.
   `mix openapi.spec.json` is byte-identical for a distribution with no
   extension installed, verified against `main`.
4. **#1507 — the move. Built** ([#1523](https://github.com/BinaryBourbon/fountain/pull/1523)).
   `apps/fountain_buzz`, `Fountain.Buzz*` renamed `FountainBuzz.*`, its table,
   controllers, schemas, launch script, base prompt and tests with it;
   `Fountain.ExtensionGuardTest` asserting `apps/fountain/lib` names no
   extension module, declares no Buzz route and holds no Buzz asset. The
   published spec and `sdk/contract/contract.json` came out byte-identical,
   which is what "the wire did not move" means.
5. **#1508 — the Go split. Built.** `buzz-backend-fountain` and its `backend`
   package moved to `apps/fountain_buzz/cli`, a Go module of its own, so the
   compiler enforces the boundary the way it does on the Elixir side: Go's
   `internal/` rule is scoped to a module path, so the provider cannot reach
   into `cli/internal/...` even by accident. What it uses instead is the public
   client `cli/api` + `cli/credentials`, promoted out of `cli/internal` for
   exactly this. `fountain buzz` stayed in `cli/` (decision 6), and the issue
   was rescoped to that split.

   The gate also found that **the provider was built by nothing and attached to
   no release**, while this ADR and `docs/integrations/buzz.md` both described
   it as shipped — the "describes unbuilt behavior as existing" failure this
   repository has a rule against. It now cross-compiles for the same four
   platforms as the `fountain` binary and is attached to every release, so the
   sentence in decision 6 below is true rather than aspirational.

   `BUNDLE_EXTENSIONS=false` is the one switch (#1510): the release carries no
   `apps/fountain_*` application, discovered by glob rather than listed, and
   the image copies an empty native-asset stage.

6. **#1509 — the supply chain. Built.** `buzz-acp.version` and
   `buzz-acp.source` moved to `apps/fountain_buzz`, the publish and build
   workflows read them there, and the Docker stage became a pair selected by
   `BUNDLE_EXTENSIONS` — the bundled image downloads and checksum-verifies both
   binaries, the core image copies an empty directory and refuses to contain
   one. `FountainBuzz.Assets` owns where they install and refuses a binary
   whose version does not match the pin, so a partial upgrade is an inert
   extension and a log line rather than a harness crash-loop per identity.
7. **#1510 — graduation and distributions. Distributions built.** CI's
   `core-distribution` job builds a core release, boots it against an empty
   database and checks the spec it serves; `release.yml` publishes
   `vX.Y.Z-core` and `vX.Y-core` from the same tree and opens the published
   image to check it. Still open: the docs move, and
   `BinaryBourbon/fountain_buzz`. The docs move landed with the `docs/0`
   callback; the repository split is deferred by choice, not blocked — its
   precondition (a second extension exercising the seam) `apps/fountain_support`
   met in #1528.

Outside the gate list, because it is not a Buzz gate:
[#1528](https://github.com/BinaryBourbon/fountain/issues/1528) moved the
problem-report feature into `apps/fountain_support` — **built**. It is the
second consumer decision 4 named as a precondition for graduating
`Fountain.Extension`, and it added no callback.
