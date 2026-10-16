# Contributing to Managoat

Use [CLAUDE.md](CLAUDE.md) for the repo map and core rules. For a change:

1. Run the relevant [local checks](#before-you-push).
2. Open a [PR](#pull-requests) whose title says what changed for a reader of
   the release notes, and merge it once CI is green.

Server implementation details are in [Server conventions](contributing/server.md).
Read the API, migration and library sections below when the change touches them.

## Ideas and accepted work

**A discussion records something we might pursue. An issue records a next action
we have accepted.** Start unaccepted feature ideas and deferred product directions
in [Discussions](https://github.com/managoat/managoat/discussions):

- **Ideas** is for problems, opportunities, and exploratory directions.
- **Proposals** is for a concrete approach awaiting a decision, including a
  designed feature we have chosen to defer.

Record the problem, supporting evidence, current decision, and what would make
us reconsider it. A proposal also records the approach, alternatives, and the
smallest useful next step. A discussion is not a delivery commitment.

Issues hold accepted fixes, scoped changes, bounded investigations and decisions,
and delivery work blocked by a named dependency. Keep reporting bugs as issues;
triage establishes their scope and disposition. An accepted issue needs a concrete
deliverable, completion criteria, and known dependencies. A date or assignee is
not required for accepted backlog work. Use the
[Managoat roadmap](https://github.com/orgs/managoat/projects/1) to sequence it.

When a maintainer accepts a next step from a discussion, create an issue for that
step and link the two records in both directions. Record architectural outcomes
in `decisions/` using the existing ADR process. Keep the discussion's broader
possibilities separate from the issue's accepted scope.

When moving an existing idea out of Issues, use GitHub's **Convert to discussion**
action to preserve its history. Read the latest decisions first: a parked label
or an exploratory title alone does not establish that work is unaccepted. If an
issue mixes an idea with a concrete bug or approved task, preserve that action
in its own linked issue before converting the broader record.

## Licensing

Managoat is licensed under the [Apache License 2.0](LICENSE), and so is what
you contribute: section 5 of the licence covers it. There is no contributor
agreement and nothing to sign. You keep the copyright in your work.

## Before you push

Run focused tests while iterating. Before pushing, choose the checks for the
parts you changed; mixed changes take the union of the relevant rows.

| Change | Local checks |
|---|---|
| Server Elixir code, tests, dependencies, or runtime/build configuration | `mix precommit`, plus the tests covering the changed behavior |
| Go CLI | In `cli/`: `go test -mod=readonly -count=1 ./...` and `go vet -mod=readonly ./...`; format changed Go files with `gofmt` |
| SDK implementation or packaging | That SDK's checks in [CI maintenance](scripts/ci/README.md#sdk-jobs); API changes also follow [Changing the API](#changing-the-api) |
| CI decision logic or workflow wiring | `python3 -m unittest discover -s scripts/ci -p 'test_*.py'`; use `actionlint` for changed workflows and run the changed script's own checks |
| Shell tooling | `shellcheck` and `bash -n` on changed Bash scripts, plus their focused regression tests |
| The managoat.com pages (`site/`) | In `site/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` and `mix site.build` ([site/README.md](site/README.md)). A change to `docs/` runs the site's link test too |
| Other tooling or integrations | The affected component's tests and lint commands from its README or CI job |
| Documentation | The focused commands in [contributing/docs.md](contributing/docs.md) |

Run `python3 scripts/conflict-markers.py` and `git diff --check` for every
change. A Go-only, SDK-only or tooling-only
change does not need the server's local Elixir gate. If a workflow or script
changes how the server compiles, boots or runs tests, also run the relevant
server stages or tests. CI remains the complete integration check for its
selected plan.

### The server's local gate

```bash
mix precommit
```

That runs `scripts/precommit.sh`: CI's Elixir static job, the sobelow scan and
a prod release assemble, each stage its own process, in this order. The test
suite is the last stage and is opt-in, `mix precommit --full` or
`mix precommit test`: CI runs the suite on full server plans, so a full
local run is useful when you want broader feedback before pushing,
such as a change to `test/support`, a factory, a migration or `config/`.

| Stage | Runs |
|---|---|
| `toolchain` | the shell's Elixir and OTP match `.tool-versions` (activate mise, or `mise exec -- mix precommit`) |
| `conflict-markers` | `python3 scripts/conflict-markers.py` |
| `compile` | `MIX_ENV=test mix compile --warnings-as-errors` |
| `deps` | `mix deps.unlock --check-unused` |
| `format` | `mix format --check-formatted` |
| `credo` | `mix credo --strict` |
| `dialyzer` | `MIX_ENV=dev mix dialyzer` |
| `sobelow` | `scripts/sobelow.sh` |
| `release` | `MIX_ENV=prod mix deps.get && mix release fountain_server --overwrite` |
| `test` | `mix test` from the umbrella root. Only with `--full` or by name |

**The exit status is the verdict.** The run stops at the first failing stage,
names it, and exits with that stage's status; the last line is always
`precommit: PASSED` or `precommit: FAILED at <stage>`. The one thing the
script cannot see past is a pipe: `mix precommit | tee log` reports `tee`'s
status unless the shell has `pipefail` on. `mix precommit --list` prints the
stages, and `mix precommit credo test` runs only those, in the canonical
order, after a fix; naming a stage always runs it, `--full` or not.

The release stage is the only one that builds `MIX_ENV=prod`. It is there
because everything else is blind to a prod-only dependency graph: the
OpenTelemetry family is `only: :prod`, and the hackney 4 bump that collided
with it left every other gate green on a tree whose release would not
assemble (#1472, #1477). It costs ~9s warm; a fresh checkout pays one full
prod compile first. It assembles only; CI boots the release, because booting
needs `SECRET_KEY_BASE` and a database.

CI additionally runs `hex.audit`, the Go CLI module, the release boot check,
OpenAPI validation, the SDK jobs and the docs gates;
[`scripts/ci/README.md`](scripts/ci/README.md) lists every job. If you
touched `docs/`, read
[`contributing/docs.md`](contributing/docs.md): the manual is built and
tested in `site/` (`cd site && mix test`), not by the server's suite.

### If a test went red and then green

Keep the failed run's assertion, file/line and run URL. Compare the commits,
workflow conditions, runner environment and external dependencies before
calling it a flake; a later green run alone does not establish the cause.
Record an unexplained failure with what is known.

For a confirmed flake, search existing issues first:

```bash
gh issue list --label type:flake --state all
```

Use the **Flaky test** issue template or file with `type:flake`, `area:testing`
and the affected area. Include the failing assertion, frequency with a
denominator and run URLs, and the suspected race if known. Check the file's
recent history so an already-fixed failure does not become a new issue.
Fix a flake caused by your change in that PR; file unrelated flakes separately.

## Finding dead code

```bash
scripts/dead-code.sh            # both reports
scripts/dead-code.sh elixir     # public functions no compiled module calls
scripts/dead-code.sh go         # unreachable functions in the Go CLI module
```

The Elixir report uses `mix_unused`; the Go report uses `deadcode`. The monthly
workflow keeps advisory artifacts. Findings do not block merges; an analyzer
failure marks the report incomplete.

Treat findings as candidates. The Elixir tracer misses dynamic calls (including
MFA callbacks), test-only seams, some protocol/callback
implementations and macro-generated functions. Search the function's bare name
across `apps/` and its tests before deleting it. A test-only caller may
be a useful observation seam or evidence of a missing production caller;
resolve which before removing the function and its tests.

## Component libraries

The `managoat_*` libraries are hex packages pinned in `apps/fountain/mix.exs`,
each in its own repository. A fix that crosses into one follows
[Updating existing libraries](contributing/component-libraries.md#updating-existing-libraries).
No new library is planned (ADR 0037).

## Changing the API

The server's OpenAPI document is the wire contract, and the TypeScript SDK and
the `managoat` CLI live in this repository against it. A schema change that
reaches the server but not its clients is the failure mode this section exists
to prevent, so the checks are arranged to
fail in the PR that makes the change rather than in somebody's application
months later.

If you touched `apps/fountain/lib/fountain_web/schemas.ex`, a controller's
`operation/2`, or the router, regenerate the SDK's wire types:

```bash
mise exec -- python3 scripts/sdk-contract/generate.py
git diff --stat sdk/typescript/src/generated
```

The script exports the server's OpenAPI document to `dist/openapi.json`
(ignored) and runs `openapi-typescript` over it into
`sdk/typescript/src/generated/openapi.ts`, which is committed. CI does the
same and fails on any diff, so commit the regenerated file with the server
change. An empty diff means the wire did not move; a non-empty one is the
wire change, and `npm --prefix sdk/typescript run typecheck` shows what
handwritten SDK code it breaks. The CLI has no generated types: check it by
hand when a field it reads moves.

### Shape-only conversation changes

Use the API-shaped launch path for new conversation fields: TypeScript
`runRequest` and `managoat conv create --file request.json` (or `--file -` for
stdin). Pass raw IDs and wire names. Local execution options stay outside the
request.
The existing convenience helpers remain supported and retain their explicit
argument lists; add an ergonomic argument only when it merits a convenience API.

An optional field with no new client behavior needs the server input/JSON-view
change, its focused server test, and regeneration. TypeScript receives
generated declarations; CLI JSON input forwards it.
A new behavior still needs independent expectations in the relevant tests.

### The schema has to match its own controller

The generated types and the SDK's wire scenarios are both derived from or
written against the schema, so neither notices when the document is wrong about what the action actually
renders. Three defects of that shape landed in a day (#1417, #1418, #1427), so
the suite now checks it directly and you will meet it without doing anything:

- **Every response any controller test renders** is validated against the
  schema its operation declares. The check is attached in `test_helper.exs` and
  costs nothing per test; 146 operations are covered by tests that already
  exist. A failure names the operation, the mismatch and the body.
- **`apps/fountain/test/fountain_web/schema_guardrail_test.exs`** adds what a
  rendered response cannot show: that no `required` list names a property its
  schema lacks, that no response is declared as an object with no properties,
  and — for the operations on its short list — that the action renders *every*
  property the schema declares, which an optional field never sent would
  otherwise hide.

If you hit it, the schema in `apps/fountain/lib/fountain_web/schemas.ex` is
usually the thing that is wrong, not the action. When it genuinely cannot be
fixed in that PR, add the `{operation, status}` pair to
`FountainWeb.SchemaGuardAllowlist` with a reason and an issue, and raise
`@ceiling` in the guardrail test in the same diff — that number moving is the
signal to a reviewer. The list may shrink freely; deleting a line is how a fix
finishes.

### Changing behaviour rather than shape

The generated types cover request and response *shape*. What a client does with
that shape — SSE framing, reconnect and cursor resume, which error class a
status becomes, terminal run states, the permission flow, pagination — is the
TypeScript SDK's wire scenarios in `sdk/typescript/test/scenarios/`, JSON files
of scripted bytes in and observations out.

Change one of those behaviours and the scenario is where you start, before the
client changes:

```bash
$EDITOR sdk/typescript/test/scenarios/<name>.json
cd sdk/typescript && node --test test/scenarios.test.ts
```

They also run in `npm test`. `sdk/typescript/test/scenarios/README.md` is the reference for the
scenario format and its vocabularies.

Do not bump an SDK's version because the contract moved. Merging a version bump
publishes that SDK, so a version moves when its own public surface changes.
Label a PR `release:skip-sdk` where the distinction needs saying out loud.

## SDK ownership and releases

TypeScript (`@managoat/sdk`, [sdk/typescript](sdk/typescript/README.md))
is the one SDK. [SDK maintenance](contributing/sdk-maintenance.md) owns version
bumps, release tags and credentials.

## Pull requests

Every change goes through a PR. Managoat has one maintainer, so there is no
required review and no merge queue (ADR 0078): once the PR's CI is green, the
maintainer squash-merges it as an admin.

```bash
gh pr checks <N>
gh pr merge <N> --squash --admin --delete-branch
```

Do not push directly to `main`; the [Release bump](#cutting-a-release)
workflow is the one thing that does. A PR green against an older `main` can
still break the newer one; `main`'s own CI runs the full suite on every
merge, and a red `main` is fixed forward before anything else merges. A
stack merges from the PR based on `main`; deleting its branch retargets the
next PR to `main`.

### Release notes

There is no changelog file to edit. The server's `CHANGELOG.md` was removed
on 2026-10-15 (its last copy is at
[v0.29.0](https://github.com/managoat/managoat/blob/v0.29.0/CHANGELOG.md));
each release's notes are on
[GitHub Releases](https://github.com/managoat/managoat/releases), generated
from the titles of the pull requests it contains. So a PR title is a release
note: say what changed for someone running Managoat, not how. When a change
needs an operator to act on upgrade (a migration that must follow a rollout,
a removed setting, a breaking API change), say so in the PR description.
Once the release is published, edit it (on its page, or with
`gh release edit vX.Y.Z --notes-file`) to put an **Upgrade notes** section
above the generated list.

If your change is architecturally significant, or constrains future work, write
an ADR using [`decisions/0001-template.md`](decisions/0001-template.md) and
refresh the index (`scripts/decisions-index.sh`) in the same PR.

## CI maintenance

[CI maintenance](scripts/ci/README.md) owns the CI jobs, coverage, timing
refresh and toolchain troubleshooting.

## Cutting a release

Run the **Release bump** workflow on `main` (Actions tab, or
`gh workflow run release-bump.yml -f bump=patch`; `minor` or `major` for a
larger step). It refuses unless CI passed on `main`'s tip and the live
adapter suite passes on it ([the live adapter gate](contributing/component-libraries.md#the-live-adapter-gate)), then bumps the
version in both `mix.exs` files and the five self-host image pins in one
commit, and pushes that commit to `main` with its `vX.Y.Z` tag. The tag runs
`release.yml`: the CLI binaries, the versioned image, a boot of the
documented quick start, the Homebrew tap and the GitHub Release with its
generated notes. Add any **Upgrade notes** to that release by hand
([Release notes](#release-notes)).

A release is also the maintainer's deploy. Merges to `main` do not reach
prod; when `release.yml` succeeds, `publish-manifests.yml` moves the
manifest artifact's `latest` to the release and Flux rolls it out
([ADR 0080](decisions/0080-prod-deploys-releases.md)). Check prod after a
release, not after a merge. Hotfixes, manifest-only changes that cannot wait,
and rollbacks are in
[scripts/ci/README.md](scripts/ci/README.md#deploys).
