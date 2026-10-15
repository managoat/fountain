# CI maintenance

`CI required` verifies the selected job plan. A skipped required job is a
failure, unless the classifier selected docs-only CI on a pull request. A push
to `main` always runs the complete plan.

Main commits validate independently, so a burst of merges cannot cancel an
older pending validation or wait behind an unrelated run. Superseded PR runs
still cancel. Image builds retain the built-ancestor diff, which includes all
image-affecting changes since the last built ancestor.

## The jobs

`.github/workflows/ci.yml` runs on every push to `main`, every PR and a manual
dispatch. The gates are grouped into jobs that share nothing, so the job
name in a red build says which toolchain to look at:

| Job | What it runs |
|---|---|
| **workflow-checks** | `CI policy and alert tests`: conflict-marker detection (`scripts/conflict-markers.py`), the Python suite in `scripts/ci/` that gates CI's own decision logic, and Prometheus alert-fixture evaluation (`scripts/test-alerts.py`). Policy checks run even for docs-only changes; alert evaluation skips only explicit docs-only plans |
| **test** (×6) | The suite, as six partitions (`scripts/test-partition.sh`), plus a `coverage` job that merges their exports with `scripts/coverage-gate.exs` and enforces the 85% threshold |
| **elixir-static** | `mix deps.unlock --unused`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `scripts/hex-audit-gate.exs`, `scripts/sobelow.sh`, `MIX_ENV=dev mix dialyzer` |
| **release-and-contract** | `mix ecto.create && mix ecto.migrate`, the prod release boot check (probes `/health` and `/health/ready`, runs a release task beside the live server), `mix openapi.spec.json` + `jq empty`, and `scripts/sdk-contract/generate.py --check`, which exports the OpenAPI document, regenerates the TypeScript SDK's `openapi.ts` from it and fails on a diff |
| **changes** | Classifies the diff and emits the plan every other job reads: `docs_only` (which gates the server jobs), `manual_docs` (which selects the published-manual tests), and `cli_docs` (`scripts/ci/changes.py`). Fail-open: an unreadable diff or an unregistered path selects the full server plan. Runs on `pull_request` and `workflow_dispatch`, never on `push`, where the outputs are empty so every `!=`-gated job runs |
| **typescript-sdk** (×2) | The TypeScript SDK on the minimum Node in `engines.node` (20.19.0) and on 24, and the packed tarball installed into a throwaway consumer project |
| **cli-plugins** | The Go module (`cli/`) with tests, vet and gofmt |
| **compose-fresh-clone** | `docker compose config --quiet` without `.env`, `SECRET_KEY_BASE` or `MASTER_SECRETS_KEY`, so the documented database-only startup can load the Compose file |
| **compose-pinned-image-boot** | `scripts/compose-boot-check.sh` exercises the Compose quick start against its pinned release image. An unpublished pin that matches the version in `mix.exs` defers the boot check to `release.yml`; any other missing pin fails |
| **docs** | Compiles the embedded manual, runs `scripts/test-docs.sh` (the manual's suites), and runs CLI documentation parity when `cli_docs` is true. Selected only when `docs_only` and `manual_docs` are true; skipped on `push` |
| **gate** | `CI required`: validates every expected job result for the event's plan (`scripts/ci/gate.py`) |

`mix hex.audit` is not one of these: `scripts/hex-audit-gate.exs` fails the
build on a security advisory unless it is acknowledged in `mix.exs`, and only
retirements stay non-blocking.

Outside `ci.yml`, `dead-code.yml` publishes a monthly advisory report of
public Elixir functions nothing calls and unreachable Go functions
(`scripts/dead-code.sh` locally; CONTRIBUTING.md, "Finding dead code", says
how to read it). It gates nothing.

Measure the slowest partition plus coverage and runner queue delays before
adding runners. Dialyzer can dominate cold runs; the release has its own
compiled-build cache.

`mix precommit` (`scripts/precommit.sh`) is the local subset: the static
job, sobelow and a release assemble, with the suite behind `--full`.
CONTRIBUTING.md, "Before you push", lists its stages.

## Database setup stalls

The partition jobs load `mix-diagnostics.exs` before running database setup.
After each minute, it prints the VM's OS PID, Mix stack traces, lock holders
and an OS process tree. This captures a stalled compiler before the job's
existing timeout cancels it (#1997). It does not retry commands, disable
locking or change timeouts. A setup that finishes within a minute adds no
diagnostic output.

Process messages, dictionary values, environment variables and command
arguments are omitted. Compare the PID in Mix's lock-wait message with the
reported VM PID and process tree to distinguish a second VM from a wait
inside the same VM. Reproduce locally with the same build cache and command:

```sh
MIX_DIAGNOSTICS=1 MIX_ENV=test elixir -r scripts/ci/mix-diagnostics.exs -S mix ecto.migrate --quiet
```

## Events and the plan

`gate.py`'s `PROBES` table is the authority on what each event owes, and
`test_every_event_the_workflow_triggers_on_is_a_plan` in `test_gate.py` keeps
the workflow's triggers and that table in step:

| Event | Probes that run | What the plan means |
|---|---|---|
| `pull_request` | `changes` | Classify the diff; docs-only skips the Elixir suite |
| `push` | none | `main` runs the complete plan on every merge |
| `workflow_dispatch` | `changes` | Run the complete plan, without diff-based skips |

There is no merge queue (ADR 0078, which supersedes 0050). A PR merges by an
admin squash merge once its CI is green
([CONTRIBUTING.md](../../CONTRIBUTING.md#pull-requests)), so `main`'s own run
is the first test of the merged tree. `build.yml` builds an image only for a
`main` commit whose CI succeeded, and `publish-manifests.yml` deploys only a
built image, so a red `main` deploys nothing.

The repository ruleset is external state that nothing here checks. Its
required status checks, if any, are `CI required` and `Detect secrets` from
GitHub Actions.

## Cutting a release

`release-bump.yml` cuts a release in one run on `main`
([CONTRIBUTING.md](../../CONTRIBUTING.md#cutting-a-release)). It pushes the
bump commit and its tag with `RELEASE_BUMP_TOKEN`, a maintainer's personal
access token whose owner is on the ruleset's bypass list; a push with
`GITHUB_TOKEN` would be refused by the ruleset and would start no workflows.
The tag push starts `release.yml`.

## SDK jobs

The TypeScript SDK runs in `typescript-sdk`. The Go CLI checks run in
`cli-plugins`. `release-and-contract` checks that the SDK's generated
`openapi.ts` matches the server's OpenAPI document; that regenerate-and-diff
is the only contract check. The Python, Elixir and Swift SDKs and their jobs
were removed on 2026-10-12, and the cross-client contract layer
(`sdk/contract`) on 2026-10-15 (ADR 0059).
The TypeScript job owns
installation, type checks, tests (wire scenarios included), builds, browser
and bundling on Node 20.19.0 and 24. The minimum runtime runs compiled
JavaScript from the same test sources in a temporary fixture tree. Node 24
retains native TypeScript tests. Both legs build the SDK and browser bundle.
They also pack and install the npm artifact in a temporary consumer project.
That project typechecks against the published declarations and exercises the
Node and browser entry points with a fake fetch implementation. It also bundles
that consumer for a browser, checking the package export conditions.
**The SDK job runs on every plan.** Pull requests, manual dispatches and
main pushes all run it, docs-only plans included. There is no SDK path
classification: each leg is a
fraction of a minute, and routing cost more to keep right than it saved.
`CI required` requires it directly; a failed, cancelled or unexpectedly skipped leg
fails the gate.

Register a new job in `gate.py`'s `FULL_JOBS` and the workflow gate's
`needs` list together. For an SDK job, also add it to `SDK_JOBS`, which is
what keeps it required on a docs-only plan. Run `test_gate.py` to verify
their agreement and every supported event plan.

## Documentation path classification

`changes.py` reads one NUL-delimited diff with rename detection disabled, then
selects documentation checks from those paths. The contributor-only
allowlist includes ADR Markdown. Non-Markdown decision
evidence, executable files and new app directories select the full server
plan. A move out of code retains the old code path in
the diff. Missing bases, failed/empty diffs and malformed paths select full CI.

`docs_only=true` skips the server suite. `manual_docs=true` additionally requires
the `docs` job on that short path; contributor-only text needs no Elixir job.
The gate validates these booleans, and `cli_docs=true` requires manual
checks. An SDK's README is documentation for this purpose; its SDK job runs
either way.

See [the manual contribution guide](../../contributing/docs.md#checks-for-documentation-changes)
for the path table and matching local commands.

## Coverage

Coverage uses Elixir's built-in cover, not ExCoveralls: ExCoveralls cannot
merge results across machines, and the suite runs as six partitions on six
of them (#620, #894). Settings live in `coverage.exs` at the repo root, read
by both `mix.exs` files: `summary: [threshold: 85]` and `:ignore_modules`,
which matches **module names**, not source paths (a bare atom for one
module, a regex against `inspect(module)` for a former directory entry).
Locally, `mix test --cover` reports and gates in one step.

CI enforces the threshold with `scripts/coverage-gate.exs`, not
`mix test.coverage`: ~90% of that task's time renders an HTML report the job
never opens. The script reads the same `coverage.exs` and was verified to
produce the identical total (85.46% on the same six exports). Run
`mix test.coverage` locally for the per-module table or the HTML, and
re-verify the two agree when bumping Elixir, since the script depends on
`:cover` semantics the pin currently freezes.

## Refresh partition timings

Each partition records all module timings with eight concurrent cases, matching
the allocator's cost model. A passive formatter observes test events; do not
add `--slowest-modules` to routine CI, because it forces serial trace mode and
infinite test timeouts. Download the six `coverdata-*` artifacts from one
successful full PR run into a new directory, then regenerate from their logs:

```sh
gh run download RUN_ID --pattern 'coverdata-*' --dir /tmp/fountain-ci-timings
cat /tmp/fountain-ci-timings/coverdata-*/*.timings.log \
  | elixir scripts/regen-test-timings.exs
PARTITION_DEBUG=1 elixir scripts/partition-files.exs 1 6
```

Use one run's logs, not multiple runs, because durations for modules in the
same file are summed. The artifact retention is one day. Unknown test files
still get a median estimate and run; refreshing the table improves balance.

## Manual public-link check

`python3 scripts/ci/check_external_links.py` checks public GitHub documentation
links on demand. It is not part of merge CI. The manual's compilation, internal
links, anchors, snippets, nav and CLI docs parity remain blocking checks in the
Elixir and Go suites. See [the manual contribution guide](../../contributing/docs.md).

## Check the CI policy locally

```sh
python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
actionlint -shellcheck= .github/workflows/ci.yml
shellcheck scripts/ci/*.sh
elixir scripts/ci/timing-formatter-test.exs
```

## Sandbox providers

Merge CI runs no sandbox provider; three checks outside it do.

- `sandbox-images.yml` builds the reference recipe `images/e2b/` on the
  runner and smokes it, on pull requests and pushes that touch it. Its `e2b`
  job smokes production's template, loam's `fountain`, weekly, on those
  pushes and on dispatch: it starts a sandbox, runs `smoke.sh` (claude, codex
  and gemini print their versions) and destroys it. It builds nothing; loam
  builds that template from its own repository. Until 2026-10-15 the job
  rebuilt a hosted e2b.app template that production did not use.
- The E2B jobs here and in managoat_sandbox share one setup: repository
  secret `E2B_API_KEY`, a key of loam's `fountain-ci` project (Infisical
  `fountain`/prod, `/ci/E2B_LOAM_CI_API_KEY`), and repository variables
  `E2B_BASE_URL=https://api.e2b.loam.inevitable.fyi` and
  `E2B_TEMPLATE=fountain`. A key of its own keeps CI's sandboxes out of
  production's loam project; loam's templates are visible to every project.
- The adapters' live suites, `test/live/` in
  [managoat_sandbox](https://github.com/managoat/managoat_sandbox), run daily
  in its `live.yml`:
  - E2B uses production's endpoint and template (the setup above). It covers
    pause and resume, attach replay, files and egress.
  - Sprites uses `SPRITES_TOKEN`, an organization token for production's org
    (Sprites tokens cannot be scoped to a name prefix). It
    covers a fresh sprite's first exec, cold wakes, the public URL,
    checkpoints and egress.

  Neither can be checked by the stubbed tests.
- `live-adapters.yml` runs Fountain's live adapter suite
  (`apps/fountain/test/live/`) on a pull request that changes `mix.lock`,
  `apps/fountain/mix.exs` or the suite, and on dispatch. It drives the pinned
  claude and codex adapters with the pinned peer in an E2B sandbox; a pin bump
  of `managoat_acp` or `managoat_runtimes` must pass it
  ([component libraries](../../contributing/component-libraries.md#the-live-adapter-gate)).
  It needs secrets `E2B_API_KEY`, `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`,
  and the E2B variables above. A fork's pull request is skipped.

## Portable alert rules

The `Alert rules` workflow runs `scripts/test-alerts.py` with Prometheus
`promtool` and PyYAML. It extracts the actual PrometheusRule spec and checks syntax,
replica aggregation, failure thresholds, counter resets, absent series, low
traffic, and first-output alert hold time. Run the same command locally
after changing `deploy/k8s/prometheusrule.yaml`.

## Pinned Mix lock backport

Core CI jobs on Elixir 1.19.2 install the exact upstream
[Mix lock fix #15765](https://github.com/elixir-lang/elixir/pull/15765)
before invoking Mix. The patch is Apache 2.0 (see
[mix-lock-15765.patch.license](mix-lock-15765.patch.license)).

Pinned Mix leaves its first `port_P` file hard-linked to `lock_0` after
unlocking. If the OS reassigns that port to the next listener, recreating
`port_P` overwrites `lock_0` with the current process's port. Mix then probes
its own listener and waits for itself indefinitely. The regression reproduces
this with real TCP sockets by asking the allocator to reuse its first port.
The backport also handles reassignment after an owner crashes and retains
mutual exclusion between separate OS processes.

This is a concrete mechanism consistent with #1997's wait on PID 2770 after
compiling the core app. The historical log did not capture lock files or
stacks, so it cannot establish that exact interleaving. Keep the diagnostic
reporter to distinguish any future stall.

`scripts/ci/mix-lock-backport.sh` verifies Elixir 1.19.2 and the original
source SHA256, applies the unchanged upstream patch to a temporary copy,
verifies the resulting SHA256, and compiles an isolated ebin. It edits no
installed toolchain and fetches nothing. `--install` exports `ERL_AFLAGS`
through `GITHUB_ENV`, preserving existing flags. An Erlang `-eval` explicitly
loads the patched module before Elixir starts: adding `-pa` alone is
insufficient because Elixir later prepends its own Mix path. A module-origin
check and the cross-VM regression verify that the fix reaches child VMs.
The preload also runs under embedded release boot, which disables autoloading
and cannot start a custom `-s` bootstrap module from an added code path.

For isolated local verification, wrap a command with the same script:

```sh
scripts/ci/mix-lock-backport.sh elixir scripts/ci/mix-lock-backport-test.exs
scripts/ci/mix-lock-backport.sh mix ecto.create --quiet
```

Use a dedicated build tree with no concurrent unpatched Mix process. Upstream
changed the lock namespace to `mix_lock_v2_user`, so patched and unpatched VMs
do not coordinate on a shared build directory. The local wrapper removes its
temporary ebin when the command exits; it is intended for finite verification
commands. CI's installation persists for the whole job, including nested Mix
commands and release checks. The TypeScript SDK job runs no Mix and needs none
of this.

**Retirement:** remove the wrapper, patch and CI installation steps when the
pinned Elixir release contains #15765 and these regressions pass against its
native module. As checked on 2026-09-13, neither 1.19.6 nor 1.20.4 contains the
fix; a patch-version bump alone does not address this race. Version and source
fingerprint guards intentionally fail when the toolchain changes, requiring
that review rather than silently patching a different implementation.
