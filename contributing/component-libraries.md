# Component libraries

Nine database-free subsystems left the server as Apache-2.0 `Managoat.*`
libraries, and all nine went to hex (ADR 0037). One came back:
`managoat_substitution` never had a consumer outside Fountain, so the `${VAR}`
engine is `Fountain.Substitution` again (ADR 0037, addendum of 2026-10-13).
No further extraction is planned (addendum of 2026-10-13). This page says what
each library owns and how a change that crosses into one lands.

| Library | Owns | Fountain keeps |
|---|---|---|
| `managoat_mcp_auth` | the client side of MCP authorization: RFC 9728/8414/7591 discovery and registration, the SSRF guard, and `Managoat.McpAuth.Client`, an OAuth 2.0 code flow | nothing: Connections, its one consumer, were removed, and Fountain no longer depends on it |
| `managoat_oauth` | the OAuth 2.0 code+PKCE and device-grant state machine, a `use` macro over `Managoat.OAuth.Host` | `Fountain.OAuth` is the instance; its host mints the API key |
| `managoat_acp` | the client-side ACP session (Peer), Protocol, Permissions, Blocks, Usage, Tracer, the ScriptedAgent | `Conversations.Blocks` |
| `managoat_sandbox` | the sandbox behaviour, the Sprites/E2B adapters (and a Daytona adapter Fountain no longer names), Retry, the Fake, the conformance case | `Fountain.SandboxProviders`, the "which providers are enabled" policy |
| `managoat_docs` | the compile-time embedded manual as a `use` macro, the markdown renderer, `GuardrailCase` | `docs/`, `nav.yml`, `Fountain.Help`, the `/docs` controller |
| `managoat_broker` | the native egress credential proxy behind `Managoat.Broker.Store` | the store over `broker_sessions`, the listener, the egress log |
| `managoat_runner` | the self-hosted runner wire protocol, the sandbox adapter over it, the FakeDaemon, behind `Managoat.Runner.Host` | `Fountain.Runners.Host` over Horde; the runners table, placement, presence |
| `managoat_runtimes` | how claude/codex/gemini get into a sandbox speaking ACP (it also carries an opencode adapter Fountain no longer names): the behaviour, the pinned adapter table, Layout, Instructions, Quirks, Model, Skills, the FakeRuntime | the model catalog, the bundled skill content, the ask timeout, `InferenceCredentials` |

Current version requirements live in `apps/fountain/mix.exs`; each library lives in the
repository `managoat/managoat_<name>`, from whose CI it publishes to hex.
Taking a new library release into Fountain is a pin bump PR here, and that PR
is the only place the new version is exercised against Fountain, so do not
skip its gates: `mix precommit --full`, and `docker build --target build .`,
since the Dockerfile's deps layer is the one consumer of the hex release that
CI does not build.

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
