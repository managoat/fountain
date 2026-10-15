# Component libraries

Nine database-free subsystems left the server as Apache-2.0 `Managoat.*`
libraries, and all nine went to hex (ADR 0037). Fountain depends on six of
them now. `managoat_substitution` never had a consumer outside Fountain, so the
`${VAR}` engine is `Fountain.Substitution` again (ADR 0037, addendum of
2026-10-13), and `managoat_mcp_auth` lost its one consumer when Connections
were removed. `managoat_runner` went with the self-hosted runner provider
(#2676). No further extraction is planned (addendum of 2026-10-13). This
page says what each library Fountain uses owns and how a change that crosses
into one lands.

| Library | Owns | Fountain keeps |
|---|---|---|
| `managoat_oauth` | the OAuth 2.0 code+PKCE and device-grant state machine, a `use` macro over `Managoat.OAuth.Host` | `Fountain.OAuth` is the instance; its host mints the API key |
| `managoat_acp` | the client-side ACP session (Peer), Protocol, Permissions, Blocks, Usage, Tracer, the ScriptedAgent | `Conversations.Blocks` |
| `managoat_sandbox` | the sandbox behaviour, the Sprites/E2B adapters (and a Daytona adapter Fountain no longer names), Retry, the Fake, the conformance case | `Fountain.SandboxProviders`, the "which providers are enabled" policy |
| `managoat_docs` | the compile-time embedded manual as a `use` macro, the markdown renderer, `GuardrailCase` | `docs/`, `nav.yml`, `Fountain.Help`, the `/docs` controller |
| `managoat_broker` | the native egress credential proxy behind `Managoat.Broker.Store` | the store over `broker_sessions`, the listener, the egress log |
| `managoat_runtimes` | how claude/codex/gemini get into a sandbox speaking ACP (it also carries an opencode adapter Fountain no longer names): the behaviour, the pinned adapter table, Layout, Instructions, Quirks, Model, Skills, the FakeRuntime | the model catalog, the bundled skill content, the ask timeout, `InferenceCredentials` |

Current version requirements live in `apps/fountain/mix.exs`; each library lives in the
repository `managoat/managoat_<name>`, from whose CI it publishes to hex.
Taking a new library release into Fountain is a pin bump PR here, and that PR
is the only place the new version is exercised against Fountain, so do not
skip its gates: `mix precommit --full`, and `docker build --target build .`,
since the Dockerfile's deps layer is the one consumer of the hex release that
CI does not build. A bump of `managoat_acp` or `managoat_runtimes` must also
pass the live adapter suite (below).

## The live adapter gate

What an ACP adapter does with a permission answer, which modes it offers and
whether it takes a session config option can change between versions with
every stubbed test still passing (#2670). The peer that drives it comes from
`managoat_acp`, and the adapter versions come from `managoat_runtimes`' pinned
table. Fountain's lock is the only place the two meet, so the suite lives
here: `apps/fountain/test/live/adapter_behaviour_live_test.exs`, tagged
`:live_adapter` and excluded from `mix test`.

**A PR that bumps either library, or takes a runtimes release that moves an
adapter pin, must pass it.** The `Live adapters` workflow runs it on a pull
request that changes `mix.lock`, `apps/fountain/mix.exs` or the suite, and on
dispatch. Name its result in the PR. To run it yourself, from `apps/fountain`,
with the test database migrated (the application boots):

```bash
E2B_API_KEY=... E2B_BASE_URL=... E2B_TEMPLATE=fountain \
ANTHROPIC_API_KEY=... OPENAI_API_KEY=... \
  mix test --only live_adapter test/live/adapter_behaviour_live_test.exs
```

`--only runtime:claude` or `--only runtime:codex` runs one runtime. Each
runtime gets one billed E2B sandbox, destroyed when its module finishes, and
the whole suite takes about a minute. For each of claude and codex it checks:

- **The session config restore.** A prompt-only option (`effort`,
  `reasoning_effort`) is set for one turn, and the next turn reports
  `{:config_restored, id, baseline}` with the option back at the adapter's
  default. A session resumed on a new connection comes back at the default.
- **The harness modes.** The mode options are exactly the ids
  `SessionConfig.harness_mode_ids/0` refuses, `offered/1` hides them, and the
  default mode is the one Fountain's turns run in.
- **Permission requests.** Whether a write inside the workspace, a write
  outside it and a read-only command ask. A rejected request does not run its
  tool and ends the turn with the adapter's stop reason (claude `end_turn`,
  codex `cancelled`); an approved one runs.

Each runtime's measured answers are the `expect/0` map at the bottom of the
file. When a bump changes one, the suite fails. Update the map in the same PR,
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

This cost is why no further subsystem is extracted. Should one ever need to
be, start it as a repository of its own by copying an existing `managoat_*`
repository's CI, release gate, publish workflow, `scripts/release.exs`,
`NOTICE` and `CHANGELOG.md`. The umbrella-first recipe and its guards
(`umbrella_layout_test.exs`, `scripts/test-libraries.sh`) were removed on
2026-10-13 (ADR 0037).
