# Contributing to Fountain

Use [CLAUDE.md](CLAUDE.md) for the repo map and core rules. For a change:

1. Run the relevant [local checks](#before-you-push).
2. [Sign off commits](#sign-your-commits-dco) with `git commit -s`.
3. Open a [PR](#pull-requests), add a changelog fragment if behavior changes,
   and queue it after approval.

Server implementation details are in [Server conventions](contributing/server.md).
Read the API, migration and library sections below when the change touches them.

## Licensing of contributions

Fountain is not licensed as a single unit. **The license that applies to your
contribution is the license of the directory you are editing**, and each one
carries its own LICENSE file:

| Directory | License |
|---|---|
| `apps/fountain`, `config`, `priv` | GNU AGPL v3.0 or later |
| `ee/` | Elastic License 2.0 |
| `cli/`, `sdk/` (every client) | Apache License 2.0 |

**You contribute under the Apache License 2.0, whichever directory you are
editing.** Fountain then distributes your work under the license governing that
directory, from the table above. There is no separate document to sign and no
CLA bot. Opening a pull request is the grant.

You keep the copyright in your work. This is a license, not an assignment, and
Apache-2.0 does not restrict you, so you keep the full right to reuse your own
contribution anywhere else, including in proprietary code of your own.

The asymmetry, stated plainly so nobody is surprised later: Apache-2.0 permits
relicensing, so Fountain's maintainer can distribute your contribution under
the AGPL, under the Elastic License, or under a commercial license sold to a
company whose policy forbids the AGPL. You cannot do the same with anyone
else's contribution. That is the same asymmetry a CLA creates, with less
ceremony, and it exists for one reason: without it, the option to sell a
commercial exception closes permanently the first time an outside pull request
is merged. If that trade is not one you want to make, say so on the pull
request. It is a reasonable thing to object to.

For `cli/` and `sdk/` this changes nothing at all, since inbound and outbound
are both Apache-2.0 there.

## Sign your commits (DCO)

Fountain uses the [Developer Certificate of Origin](https://developercertificate.org/).
It is a one-line assertion that you wrote the patch, or otherwise have the right
to submit it. Your sign-off also records your agreement to the inbound terms
above. Add it with `-s`:

```bash
git commit -s -m "fix(agents): ..."
```

That appends a `Signed-off-by:` trailer using your `user.name` and
`user.email`. Note that `git config format.signOff true` does **not** do this
for `git commit`; use `-s`, or install a `commit-msg` hook.

CI's `workflow-checks` job (`scripts/ci/dco.py`) refuses a PR with a commit
missing the trailer. Fix it with `git commit --amend -s` for the last commit,
or `git rebase --signoff <base>` for several.

## Before you push

Run focused tests while iterating. Before pushing, choose the checks for the
parts you changed; mixed changes take the union of the relevant rows.

| Change | Local checks |
|---|---|
| Server or extension Elixir code, tests, dependencies, or runtime/build configuration | `mix precommit`, plus the tests covering the changed behavior |
| Go CLI or Buzz CLI | In each affected module: `go test -mod=readonly -count=1 ./...` and `go vet -mod=readonly ./...`; format changed Go files with `gofmt`. Shared dependency changes need [both modules](#go-dependency-updates-span-two-modules) |
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
| `sobelow` | `scripts/sobelow.sh`, core with `ee/lib` overlaid |
| `release` | `MIX_ENV=prod mix deps.get && mix release fountain_server --overwrite` |
| `test` | `mix test` from the umbrella root: core, `ee/test` and every sibling app. Only with `--full` or by name |

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
touched `docs/` or an extension's manual, read
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
MFA callbacks), extension callers, test-only seams, some protocol/callback
implementations and macro-generated functions. Search the function's bare name
across `apps/`, `ee/` and their tests before deleting it. A test-only caller may
be a useful observation seam or evidence of a missing production caller;
resolve which before removing the function and its tests.

## Go dependency updates span two modules

Buzz's Go module replaces `github.com/managoat/fountain/cli` with the local
`cli/` directory. A dependency bump there can require changes to Buzz's
`go.mod` and `go.sum` even when no Buzz source changes.

Dependabot monitors both directories in one Go update job and groups version
updates by dependency name across them. This includes major updates.
[GitHub's grouping rules](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference#groups)
exclude security updates and can split incompatible version constraints into
separate PRs. Whenever a shared dependency changes, tidy both modules on the
same PR branch and commit every resulting module-file change together:

```bash
go -C cli mod tidy
go -C apps/fountain_buzz/cli mod tidy
go -C cli test -mod=readonly -count=1 ./...
go -C cli vet -mod=readonly ./...
go -C apps/fountain_buzz/cli test -mod=readonly -count=1 ./...
go -C apps/fountain_buzz/cli vet -mod=readonly ./...
```

Run tidy again after committing those files; it should leave no diff in either
module. CI retains separate test and vet steps for both modules. A green core
CLI check alone does not cover Buzz.

## Extension migrations share one `schema_migrations`

A first-party extension (ADR 0043) contributes migration directories through
`Fountain.Extension`'s `migrations/0`, and `Fountain.Migrations` appends them
after the core's at every entrance: the boot migrator, `Fountain.Release`, and
`mix ecto.migrate` / `ecto.rollback` / `ecto.setup` (aliased in both
`mix.exs` files so the root and the app agree). Two rules come with that.

**Version numbers are global.** Extension migrations are recorded in
Fountain's own `schema_migrations` table, not one of their own, so a version an
extension picks must not collide with the core's or another extension's. Ecto
refuses to run a path set containing a duplicate version, which makes a
collision a loud failed migrate rather than a quietly skipped migration. Keep
generating timestamps; never hand-pick an integer.

**Moving a migration between paths is not a re-run.** A version already in
`schema_migrations` stays applied when its file moves from `priv/repo/migrations`
into an extension's directory, because Ecto matches on the version and never on
the path. That is what lets an extraction move a table without touching a live
database, and
`apps/fountain/test/fountain/extension_composition_test.exs` pins it.

Migrating from the umbrella root goes through `apps/fountain` on purpose:
`mix ecto.migrate` is a recursive task, and Mix invokes it inside each child
project *without* resolving that child's aliases, so the root would otherwise
report "Migrations already up" and leave an installed extension's tables
missing. The root aliases shell into the app the way `ecto.reset` already did.

## Adding an umbrella library app

Further extraction is paused until an independent consumer or release schedule
justifies it. See [Component libraries](contributing/component-libraries.md)
for ownership and the extraction recipe.

## Graduating a library

The [library guide](contributing/component-libraries.md#graduating-a-library)
contains the graduation procedure. Routine library fixes use
[Updating existing libraries](contributing/component-libraries.md#updating-existing-libraries).

## Changing the API

The server's OpenAPI document is the wire contract, and four clients live in
this repository against it. A schema change that reaches only one of them is
the failure mode this section exists to prevent, so the checks are arranged to
fail in the PR that makes the change rather than in somebody's application
months later.

If you touched `apps/fountain/lib/fountain_web/schemas.ex`, a controller's
`operation/2`, or the router, regenerate the contract and supported wire models:

```bash
mise exec -- python3 scripts/sdk-contract/generate.py
git diff --stat sdk/contract/contract.json sdk/typescript/src/generated sdk/swift/Sources/FountainKit/Models/ConversationWire.generated.swift
```

An empty generated diff means the wire did not move; still run the checks for
the changed server behavior. A non-empty diff lists the wire changes. Run the
affected client checks (each command below is independent, from the root):

```bash
npm --prefix sdk/typescript run verify-contract
(cd sdk/python && python3 scripts/verify_contract.py)
(cd sdk/elixir && mise exec -- mix test test/contract_test.exs)
swift test --filter ContractTests
```

Each verifier reads `sdk/contract/contract.json` and its own manifest under
`sdk/contract/manifests/`, and names itself and the exact field, operation or
enum value that no longer lines up. Fix the client, then update its manifest
to describe what it now depends on. `sdk/contract/README.md` is the reference
for the manifest format and for what each of the five checks means.

Two things that are not optional:

- **A new endpoint needs a decision.** `scripts/sdk-contract/build.sh --check`
  fails when an operation is neither claimed by a manifest nor matched in
  `sdk/contract/omissions.json`. Either wire it into a client, or add it to the
  allowlist with one line saying why no client needs it.
- **Commit `sdk/contract/contract.json`.** It is committed so the Swift job,
  which has no Elixir toolchain, can check against it. `dist/openapi.json` is
  the rebuilt input and stays ignored.

### Shape-only conversation changes

Use the API-shaped launch path for new conversation fields: TypeScript
`runRequest`, Python/Elixir `run_request`, Swift `runRequest`, and
`fountain conv create --file request.json` (or `--file -` for stdin).
Pass raw IDs and wire names in map clients; FountainKit uses the generated
`ConversationCreateRequest`. Local execution options stay outside the request.
The existing convenience helpers remain supported and retain their explicit
argument lists; add an ergonomic argument only when it merits a convenience API.

An optional field with no new client behavior needs the server input/JSON-view
change, its focused server test, and regeneration. TypeScript and FountainKit
receive generated declarations; map clients and CLI JSON input forward it.
Do not add the field to every SDK manifest or unrelated conformance scenario.
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
shared conformance suite in `sdk/conformance/`, run by all four clients from
one set of JSON scenarios.

Change one of those behaviours and the scenario is where you start, before any
client changes:

```bash
$EDITOR sdk/conformance/scenarios/<name>.json
python3 sdk/conformance/lint.py
```

The lint checks the format, checks the support matrix, and checks every fixture
body against the schema the server declares for that operation, so a scenario
cannot go green against a response the real server would never send. Then run
the four adapters:

```bash
cd sdk/typescript && npm run conformance
cd sdk/python     && python3 -m unittest discover -s tests -p test_conformance.py
cd sdk/elixir     && mix test test/conformance_test.exs
swift test --filter ConformanceTests        # from the repository root
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
tags, credentials, Swift revision pins and the checklist for a new client.
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
