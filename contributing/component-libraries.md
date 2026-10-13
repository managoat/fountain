# Component libraries: the extraction and graduation recipes

**Further extraction is paused** (ADR 0037, addendum of 2026-09-14). Nine
database-free subsystems left the server as Apache-2.0 `Managoat.*` libraries
and all nine went to hex; every one of them costs two PRs per cross-seam
change. One came back: `managoat_substitution` never had a consumer outside
Fountain, so the `${VAR}` engine is `Fountain.Substitution` again (ADR 0037,
addendum of 2026-10-13). A tenth is worth that coordination only when a consumer outside
Fountain needs it, or when it needs a release schedule of its own. Until one
of those is true, a subsystem stays where it is, behind whatever module
boundary the compiler already enforces. The recipes below are kept for the
day that changes, and for a fix that has to land in a graduated library.

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
repository `managoat/managoat_<name>`. The umbrella holds no library app
today; `umbrella_layout_test.exs` and `scripts/test-libraries.sh` guard the
next one. Taking a new library release into Fountain is a pin bump PR here,
and that PR is the only place the new version is exercised against Fountain,
so do not skip its gates.

## Updating existing libraries

Prepare the library fix and Fountain integration together so the consumer's
requirements are known before publishing. Keep the library release compatible
with its current consumers where practical. Land and publish the library, then
finish Fountain's dependency update against that released artifact and run the
server checks and affected integration tests.

Related library releases needed by one Fountain change can share a single
Fountain PR. Routine updates do not use the graduation recipe or its one-library-
at-a-time sequencing: they change dependencies and callers, not repository
boundaries. Keep the release links in the PR so both sides are reviewable.

## Adding an umbrella library app

A new library starts as an app in this umbrella, `apps/managoat_<name>`,
and graduates once its surface stops moving. The model to copy is the last
extraction as merged, `git show 1b848031 -- apps/managoat_substitution`
(#1347, the smallest; the library has since been folded back into
`Fountain.Substitution`). A new one needs:

- `apps/managoat_<name>/mix.exs` with the three umbrella path lines
  (`build_path`, `deps_path`, `lockfile`) and deliberately **no**
  `config_path`: `config/runtime.exs` calls Fountain modules, so a library
  pointed at it cannot boot from its own directory. The library's tests must
  pass with no config at all (set what they need in `test/test_helper.exs`
  or per test). Plus `package` metadata with `licenses: ["Apache-2.0"]`, and
  its own `test_coverage` threshold.
- `LICENSE` (Apache-2.0, copy `cli/LICENSE`), `README.md`, `.formatter.exs`,
  `test/test_helper.exs`.
- A line in `apps/fountain/mix.exs`: `{:managoat_<name>, in_umbrella: true}`.
- A `COPY apps/managoat_<name>/mix.exs` line in the Dockerfile's deps layer,
  beside the existing one. Without it `mix deps.get` fails in the image
  build, which CI does not run.
- No reference to `Fountain.*` or `FountainWeb.*`, no
  `Application.get_env(:fountain, …)`, and no `[:fountain, …]` telemetry
  anywhere under its `lib/` or `test/`. The library takes what it needs as
  arguments or reads its own otp_app.
- If the library's `test/test_helper.exs` writes its own config (a test
  host, a stub name), Fountain's `apps/fountain/test/test_helper.exs` must
  set the value Fountain needs for that same key, with a comment. `mix test`
  at the umbrella root runs every app in one VM, so a library helper's
  `put_env` is still in effect when Fountain's suite starts (#1352 lost ten
  runner tests to this). CI never sees it, since the partitions and
  `scripts/test-libraries.sh` are separate VMs; `mix precommit --full` does.

`apps/fountain/test/fountain/umbrella_layout_test.exs` checks every one of
those and fails the suite on a miss. The root gates already reach the new
app: `mix format` through `subdirectories: ["apps/*"]`, credo through
`apps/*/lib/`, dialyzer and `mix test` because they run at the root. In CI
the library's tests run from `scripts/test-libraries.sh` in one partition
and their coverage export joins the merged gate, so a library with no tests
fails the run rather than passing unmeasured. Add a changelog fragment and
update the "Built so far" block in decisions/0037.

## Graduating a library

The reverse of the section above: an `apps/managoat_<name>` app leaves this
umbrella for a repository of its own, `managoat/managoat_<name>` (the same
string as the hex package), from which CI publishes it to hex, and
`apps/fountain` pins the hex release. All nine graduated through
`scripts/graduate-library.sh` and a `templates/managoat-library/` copied into
each new repository (#1345). Both are gone from this repository now that
extraction is paused; a tenth library starts from one of the nine. Copy
`managoat/managoat_docs`'s CI, release gate, publish workflow,
`scripts/release.exs`, `NOTICE` and `CHANGELOG.md`, and take the three
umbrella path lines out of its `mix.exs`.

**When.** A library graduates when it has stopped moving: its public surface
has not changed since extraction, or its last change was a release of its own
rather than a fix that a Fountain PR needed the same day. There is no open
issue that needs a change on both sides of the seam. Until then the umbrella
gives the compile-time boundary at no release cost; after, every cross-seam
change costs two PRs (below).

**Publishing.** The publish workflow authenticates with `HEX_API_KEY`, an
organization-level secret on `managoat` visible to every repository. A hex
package name is claimed by its first publish and can never be released, so
run `mix hex.build` and the library's gates before the repository's first
push to `main`. Protect `main` behind its `ci` and `release gate` checks.

**The Fountain-side PR.** One per library, opened
only after the hex release exists and only after the previous library's PR has
merged (two open at once conflict on `apps/fountain/mix.exs`, the Dockerfile
and the table above):

- delete `apps/managoat_<name>`;
- `{:managoat_<name>, in_umbrella: true}` becomes
  `{:managoat_<name>, "~> 0.1.0"}` in `apps/fountain/mix.exs`;
- drop its `COPY apps/managoat_<name>/mix.exs` line from the Dockerfile;
- `mix deps.get`, then `mix deps.unlock --unused`;
- the table above, the "Built so far" block in decisions/0037 (then
  `scripts/decisions-index.sh` and `okf validate decisions`), and a changelog
  fragment under `changelog.d/`;
- the gates: `mix precommit --full` (which runs `umbrella_layout_test.exs` and every
  remaining library's suite), `scripts/test-libraries.sh`, and
  **`docker build --target build .`**. The last one matters most: the
  Dockerfile's deps layer is the only consumer of the hex release that CI does
  not exercise, since CI never builds the image. After the merge, watch
  `build.yml` on `main` go green.

`umbrella_layout_test.exs` and `scripts/test-libraries.sh` walk whatever
`apps/managoat_*` directories remain, so they need no edit per library; with
zero apps the test skips its per-library assertions and the script exits 0
with a message. The `config :managoat_*` lines in `config/*.exs` stay: a hex
dependency reads its otp_app configuration the same way an umbrella app did.

**Ordering: a library that depends on another graduates after it.** Hex
refuses `in_umbrella` dependencies, so the dependency must be on hex first.
`managoat_runner` depends on `managoat_sandbox` and is the worked example:
sandbox graduates to hex; sandbox's Fountain-side PR deletes
`apps/managoat_sandbox` **and, in the same PR**, changes
`apps/managoat_runner/mix.exs` from `{:managoat_sandbox, in_umbrella: true}`
to `{:managoat_sandbox, "~> 0.1.0"}`, because an `in_umbrella` dependency on
an app that no longer exists cannot resolve, so the switch cannot be a PR of
its own after the deletion. The umbrella then resolves it from hex like
Fountain does, `mix hex.build` for runner succeeds inside the umbrella (that
PR's gate), the runner conformance suite still passes; then runner
graduates.

**The cost that starts on graduation day.** A change across the seam is two
PRs: a bump in the library (its gate insists), then a pin in Fountain. The
version requirements in `apps/fountain/mix.exs` and the committed lockfile
control which release Fountain uses. A merged-PR branch push runs no CI here, so the pin PR is the only
place the new version is exercised against Fountain; do not skip its gates.
Merges into a library repository are yours once its CI is green, because its
`main` is what publishes. This cost is the reason extraction is paused.
