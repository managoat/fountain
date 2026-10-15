# Component libraries

Nine database-free subsystems left the server as Apache-2.0 `Managoat.*`
libraries, and all nine went to hex (ADR 0037). Fountain depends on one of
them now: `managoat_broker`. `managoat_docs` lost its one consumer when the
manual became a static build in `site/` (ADR 0081), which carries the parts
of it the build uses as `Site.Manual` and `Site.Markdown`; it is archived and its hex
releases retired. `managoat_acp`,
`managoat_sandbox`, `managoat_runtimes` and `managoat_oauth` were folded back
into the server on 2026-10-15 (ADR 0037, addendum of that date), and
`managoat_substitution` is `Fountain.Substitution` again (addendum of
2026-10-13). `managoat_mcp_auth` lost its one consumer when Connections were
removed; its repository is archived and its hex releases are retired (#2746),
and `managoat_runner` went with the self-hosted runner provider
(#2676) and is likewise archived and retired. No further extraction is planned (addendum of 2026-10-13). This
page says what the library Fountain uses owns, where the folded code lives,
and how a change to either lands.

| Library | Owns | Fountain keeps |
|---|---|---|
| `managoat_broker` | the native egress credential proxy behind `Managoat.Broker.Store` | the store over `broker_sessions`, the listener, the egress log |

Current version requirements live in `apps/fountain/mix.exs`; each library lives in the
repository `managoat/managoat_<name>`, from whose CI it publishes to hex.
Taking a new library release into Fountain is a pin bump PR here, and that PR
is the only place the new version is exercised against Fountain, so do not
skip its gates: `mix precommit --full`, and `docker build --target build .`,
since the Dockerfile's deps layer is the one consumer of the hex release that
CI does not build.

## The folded code

The four folded libraries keep their `Managoat.*` module names and live in
the server app; a change to them is an ordinary Fountain PR.

| Code | Where | What it is |
|---|---|---|
| `Managoat.ACP.*` | `apps/fountain/lib/managoat/acp/` | the client-side ACP session (Peer), Protocol, Permissions, Blocks, Usage, Tracer |
| `Managoat.Sandbox.*` | `apps/fountain/lib/managoat/sandbox/` | the sandbox behaviour and facade, the Sprites and E2B adapters, Retry, `Config` |
| `Managoat.OAuth.*` | `apps/fountain/lib/managoat/oauth/` | the OAuth 2.0 code+PKCE and device-grant state machine and its two schemas, called only through `Fountain.OAuth`, which owns the client registry and request validation; `Fountain.OAuth.Host` mints the API key and audits |
| `Managoat.Runtimes.*` | `apps/fountain/lib/managoat/runtimes/`, `apps/fountain/priv/runtimes/` | how claude/codex/gemini get into a sandbox speaking ACP: the behaviour, the pinned adapter table and its install manifests, Layout, Instructions, Quirks, Model, Skills, gemini's session-store script |

Their tests are under `apps/fountain/test/managoat/`. The test-only modules
(`Managoat.Sandbox.Fake`, `Managoat.Sandbox.ConformanceCase`,
`Managoat.Runtimes.Testing.FakeRuntime`, `Managoat.ACP.Testing.ScriptedAgent`)
are in `apps/fountain/test/support/managoat/`. The sandbox adapters read their
settings from `:fountain`, keyed by adapter module
(`config :fountain, Managoat.Sandbox.E2B, ...`; `config/runtime.exs` sets
them from the environment). Moving an ACP adapter pin in
`Managoat.Runtimes.ACP` needs its manifest regenerated with
`elixir scripts/acp-lock.exs <package> <version>`, and must pass the live
adapter suite (below).

The adapters' own live suites, `apps/fountain/test/live/sandbox_e2b_live_test.exs`
and `sandbox_sprites_live_test.exs`, are tagged `:live` and excluded from
`mix test`. They create billed sandboxes against real provider accounts; run
one with `mix test --only live <file>` and the credentials it names, or
dispatch the `Live providers` workflow.

## The live adapter gate

What an ACP adapter does with a permission answer, which modes it offers and
whether it takes a session config option can change between versions with
every stubbed test still passing (#2670). The peer that drives it is
`Managoat.ACP.Peer`, and the adapter versions come from the pinned table in
`Managoat.Runtimes.ACP`. The suite is `apps/fountain/test/live/adapter_behaviour_live_test.exs`, tagged
`:live_adapter` and excluded from `mix test`.

**A PR that changes `apps/fountain/lib/managoat/acp/` or
`apps/fountain/lib/managoat/runtimes/`, or moves an adapter pin, must pass
it.** The `Live adapters` workflow runs it on a pull request that changes
that code, the runtimes' `priv/` files, `mix.lock`, `apps/fountain/mix.exs`
or the suite, and on dispatch. Name its result in the PR. To run it yourself, from `apps/fountain`,
with the test database migrated (the application boots):

```bash
E2B_API_KEY=... E2B_BASE_URL=... E2B_TEMPLATE=fountain \
ANTHROPIC_API_KEY=... OPENAI_API_KEY=... \
  mix test --only live_adapter test/live/adapter_behaviour_live_test.exs
```

`--only runtime:claude` or `--only runtime:codex` runs one runtime. Each
runtime gets one billed E2B sandbox, destroyed when its module finishes, and
the whole suite takes about a minute. For each of claude and codex it checks:

- **Session config options.** An option (`effort`, `reasoning_effort`)
  requested on every turn, as Fountain requests an agent's options, is set
  on the first turn and holds on the next. A session resumed on a new
  connection comes back at the adapter's default.
- **The harness modes.** The mode options are exactly the ids
  `SessionConfig.harness_mode_ids/0` refuses, `offered/1` hides them, and the
  default mode is the one Fountain's turns run in.
- **Permission requests.** Whether a write inside the workspace, a write
  outside it and a read-only command ask. A rejected request does not run its
  tool and ends the turn with the adapter's stop reason (claude `end_turn`,
  codex `cancelled`); an approved one runs.

Each runtime's measured answers are the `expect/0` map at the bottom of the
file. When a change moves one, the suite fails. Update the map in the same PR,
and update what cites the behaviour: ADR 0014's 2026-10-15 addendum, ADR
0062, `docs/concepts/permissions.md` and the runtime's catalog page.

## Updating existing libraries

Prepare the library fix and Fountain integration together so the consumer's
requirements are known before publishing. Keep the library release compatible
with its current consumers where practical. Land and publish the library, then
finish Fountain's dependency update against that released artifact and run the
server checks and affected integration tests.

Related library releases needed by one Fountain change can share a single
Fountain PR. Keep the release links in the PR so both sides are reviewable.

## The cost of a library

A change across the seam is two PRs: a bump in the library (its gate
insists), then a pin in Fountain. The version requirements in
`apps/fountain/mix.exs` and the committed lockfile control which release
Fountain uses. A merged-PR branch push runs no CI here, so the pin PR is the
only place the new version is exercised against Fountain; do not skip its
gates. Merges into a library repository are yours once its CI is green,
because its `main` is what publishes.

This cost is why no further subsystem is extracted, and why acp, sandbox
and runtimes, whose pins moved most weeks, came back. Should one ever need to
be, start it as a repository of its own by copying
[managoat_broker](https://github.com/managoat/managoat_broker)'s CI, release
gate, publish workflow, release script (`scripts/release.exs` in that
repository), `NOTICE` and `CHANGELOG.md`. There is no in-umbrella recipe:
the umbrella-first extraction path and its guards were removed on 2026-10-13
(ADR 0037).
