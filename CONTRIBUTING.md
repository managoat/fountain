# Contributing to Fountain

Use [CLAUDE.md](CLAUDE.md) for the repo map and core rules. For a change:

1. Run the relevant [local checks](#before-you-push).
2. [Sign off commits](#sign-your-commits-dco) with `git commit -s`.
3. Open a [PR](#pull-requests), add a changelog fragment if behavior changes,
   and queue it after approval.

Server implementation details are in [Server conventions](contributing/server.md).
Read the API, migration and library sections below when the change touches them.

## Ideas and accepted work

**A discussion records something we might pursue. An issue records a next action
we have accepted.** Start unaccepted feature ideas and deferred product directions
in [Discussions](https://github.com/managoat/fountain/discussions):

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
[Fountain roadmap](https://github.com/orgs/managoat/projects/1) to sequence it.

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

Fountain is licensed under the [Apache License 2.0](LICENSE), and so is what
you contribute: section 5 of the licence covers it. There is no contributor
agreement and nothing to sign beyond the DCO below. You keep the copyright in
your work.

## Sign your commits (DCO)

Fountain uses the [Developer Certificate of Origin](https://developercertificate.org/).
It is a one-line assertion that you wrote the patch, or otherwise have the right
to submit it. Add it with `-s`:

```bash
git commit -s -m "fix(agents): ..."
```

That appends a `Signed-off-by:` trailer using your `user.name` and
`user.email`. Note that `git config format.signOff true` does **not** do this
for `git commit`; use `-s`, or install a `commit-msg` hook.

CI's `workflow-checks` job (`scripts/ci/dco.py`) refuses a PR with a commit
missing the trailer. Fix it with `git commit --amend -s` for the last commit,
or `git rebase --signoff <base>` for several. Dependabot's own commits on a PR
Dependabot opened are exempt; a commit you push onto that PR is not.

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
| Other tooling or integrations | The affected component's tests and lint commands from its README or CI job |
| Documentation | The focused commands in [contributing/docs.md](contributing/docs.md) |

Run `python3 scripts/conflict-markers.py`, `python3 scripts/changelog.py check`
and `git diff --check` for every change. A Go-only, SDK-only or tooling-only
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
| `test` | `mix test` from the umbrella root: core and every sibling app. Only with `--full` or by name |

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

CI additionally runs `hex.audit`, the Go modules, the release boot check,
OpenAPI validation, the SDK jobs and the docs gates;
[`scripts/ci/README.md`](scripts/ci/README.md) lists every job. If you
touched `docs/`, read
[`contributing/docs.md`](contributing/docs.md): the structural checks are in
the suite, and `bash scripts/test-docs.sh` runs just those.

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
scripts/dead-code.sh go         # unreachable functions in the two Go modules
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

## Adding an umbrella library app

Further extraction is paused until an independent consumer or release schedule
justifies it. See [Component libraries](contributing/component-libraries.md)
for ownership and the extraction recipe.

## Graduating a library

The [library guide](contributing/component-libraries.md#graduating-a-library)
contains the graduation procedure. Routine library fixes use
[Updating existing libraries](contributing/component-libraries.md#updating-existing-libraries).

## Changing the API

The server's OpenAPI document is the wire contract, and the TypeScript SDK and
the `fountain` CLI live in this repository against it. A schema change that
reaches the server but not its clients is the failure mode this section exists
to prevent, so the checks are arranged to
fail in the PR that makes the change rather than in somebody's application
months later.

If you touched `apps/fountain/lib/fountain_web/schemas.ex`, a controller's
`operation/2`, or the router, regenerate the contract and supported wire models:

```bash
mise exec -- python3 scripts/sdk-contract/generate.py
git diff --stat sdk/contract/contract.json sdk/typescript/src/generated
```

An empty generated diff means the wire did not move; still run the checks for
the changed server behavior. A non-empty diff lists the wire changes. Run the
SDK's contract check from the root:

```bash
npm --prefix sdk/typescript run verify-contract
```

The verifier reads `sdk/contract/contract.json` and
`sdk/contract/manifests/typescript.json`, and names the exact field, operation
or enum value that no longer lines up. Fix the client, then update its manifest
to describe what it now depends on. `sdk/contract/README.md` is the reference
for the manifest format and for what each check means.

Two things that are not optional:

- **A new endpoint needs a decision.** `scripts/sdk-contract/build.sh --check`
  fails when an operation is neither claimed by a manifest nor matched in
  `sdk/contract/omissions.json`. Either wire it into a client, or add it to the
  allowlist with one line saying why no client needs it.
- **Commit `sdk/contract/contract.json`.** It is committed so the SDK and CLI
  jobs, which have no Elixir toolchain, can check against it. `dist/openapi.json` is
  the rebuilt input and stays ignored.

### Shape-only conversation changes

Use the API-shaped launch path for new conversation fields: TypeScript
`runRequest` and `fountain conv create --file request.json` (or `--file -` for
stdin). Pass raw IDs and wire names. Local execution options stay outside the
request.
The existing convenience helpers remain supported and retain their explicit
argument lists; add an ergonomic argument only when it merits a convenience API.

An optional field with no new client behavior needs the server input/JSON-view
change, its focused server test, and regeneration. TypeScript receives
generated declarations; CLI JSON input forwards it. Do not add the field to
the SDK manifest or an unrelated conformance scenario.
Manifest claims still name dependencies of handwritten code: fields read by
run following, error handling, resolvers, or legacy convenience builders.
A new behavior still needs independent expectations in the relevant tests.

Check determinism/staleness with
`mise exec -- python3 scripts/sdk-contract/generate.py --check`.
After building TypeScript (`npm --prefix sdk/typescript run build`), run
`mise exec -- python3 scripts/sdk-contract/check-propagation.py` to inject an
optional field into a temporary model and record the real SDK/CLI requests.
This uses local fixture servers; it does not call a deployed Fountain or change
production schemas. See [the inventory and prerequisites](sdk/contract/README.md#conversation-field-workflow).

### The schema has to match its own controller

`sdk/contract` and `sdk/conformance` both compare a schema with another schema,
so neither notices when the document is wrong about what the action actually
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

The contract above covers request and response *shape*. What a client does with
that shape — SSE framing, reconnect and cursor resume, which error class a
status becomes, terminal run states, the permission flow, pagination — is the
shared conformance suite in `sdk/conformance/`, a set of JSON scenarios the
TypeScript SDK runs.

Change one of those behaviours and the scenario is where you start, before any
client changes:

```bash
$EDITOR sdk/conformance/scenarios/<name>.json
python3 sdk/conformance/lint.py
```

The lint checks the format, checks the support matrix, and checks every fixture
body against the schema the server declares for that operation, so a scenario
cannot go green against a response the real server would never send. Then run
the adapter:

```bash
cd sdk/typescript && npm run conformance
```

A client that cannot pass a scenario yet gets an entry in
`sdk/conformance/matrix.json` saying what it does instead and the issue
tracking it. `lint.py` refuses a skip with no issue number, so a gap is always
something somebody decided and filed. `sdk/conformance/README.md` is the
reference for the scenario format and the shared vocabularies.

Do not bump an SDK's version because the contract moved. Merging a version bump
publishes that SDK, so a version moves when its own public surface changes.
Label a PR `release:skip-sdk` where the distinction needs saying out loud.

## SDK ownership and releases

[SDKs.md](SDKs.md) is the checked package and support catalog.
[SDK maintenance](contributing/sdk-maintenance.md) owns version bumps, release
tags, credentials and the checklist for a new client.
After a package version or catalog change, run `python3 scripts/sdk-catalog.py --write`.

## Pull requests

Every change goes through a PR with an approving review and lands through the
merge queue:

```bash
gh pr view <N> --json reviewDecision
gh pr merge <N> --squash --auto
```

An unreviewed PR never enters the queue. Never manufacture an approval from a
second account. Do not push directly to `main` or use `--admin`; a genuine
emergency bypass must be explained in the PR. Queue the PR and move on rather
than waiting synchronously. A failed merge-group build ejects it for repair.

A PR does not need rebasing just to satisfy the queue. Stacks land from the
PR based on `main`, then its successor after GitHub retargets it. For queue
settings and troubleshooting, see [CI maintenance](scripts/ci/README.md#the-merge-queue).

### Changelog

A PR that changes something a user or operator can observe adds a fragment
file under [`changelog.d/`](changelog.d/README.md), whose README has the
format, and does not edit `CHANGELOG.md`. `python3 scripts/changelog.py check`
validates it. The release rolls every fragment into the dated section and
deletes them; CI refuses a PR that edits `CHANGELOG.md` directly, and the
`release:manual-changelog` label is the door for a typo fix in a shipped entry.

If your change is architecturally significant, or constrains future work, write
an ADR using [`decisions/0001-template.md`](decisions/0001-template.md) and
refresh the index (`scripts/decisions-index.sh`) in the same PR.

## CI maintenance

[CI maintenance](scripts/ci/README.md) owns required-check activation, queue
configuration, coverage, timing refresh and toolchain troubleshooting.
