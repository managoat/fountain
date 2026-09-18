# CI maintenance

`CI required` verifies the selected job plan. A skipped required job is a
failure, unless the classifier selected docs-only CI or the main probe proved
that a successful PR run checked the identical tree. The proof is the
`tested-tree` artifact, uploaded after the aggregate gate passes. Expired or
missing evidence triggers full CI.

Main commits validate independently, so a burst of merges cannot cancel an
older pending validation or wait behind an unrelated run. Superseded PR runs
still cancel. Image builds retain the built-ancestor diff, which includes all
image-affecting changes since the last built ancestor.

## The jobs

`.github/workflows/ci.yml` runs on every push to `main`, every PR and every
merge group. The gates are grouped into jobs that share nothing, so the job
name in a red build says which toolchain to look at:

| Job | What it runs |
|---|---|
| **workflow-checks** | `CI policy and alert tests`: conflict-marker detection (`scripts/conflict-markers.py`), the Python suite in `scripts/ci/` that gates CI's own decision logic, the SDK ownership/support catalog (`scripts/sdk-catalog.py`), the DCO sign-off gate (`scripts/ci/dco.py`, PRs only), the changelog guard and Prometheus alert-fixture evaluation (`scripts/test-alerts.py`). Policy checks run even for docs-only changes and reused trees; alert evaluation skips only explicit docs-only plans |
| **test** (×6) | The suite, as six partitions (`scripts/test-partition.sh`), plus a `coverage` job that merges their exports with `scripts/coverage-gate.exs` and enforces the 85% threshold |
| **elixir-static** | `mix deps.unlock --unused`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `scripts/hex-audit-gate.exs`, `scripts/sobelow.sh`, `MIX_ENV=dev mix dialyzer` |
| **release-and-contract** | `mix ecto.create && mix ecto.migrate`, the prod release boot check (probes `/health` and `/health/ready`, runs a release task beside the live server), `mix openapi.spec.json` + `jq empty`, and `scripts/sdk-contract/build.sh --check` |
| **changes** | Classifies the diff and emits the plan every other job reads: `docs_only` (which gates the server jobs), `manual_docs` (which selects the published-manual tests), `cli_docs` and `tree` (`scripts/ci/changes.py`). Fail-open: an unreadable diff or an unregistered path selects the full server plan. Runs on `pull_request`, `merge_group` and `workflow_dispatch`, never on `push`, where the outputs are empty so every `!=`-gated job runs |
| **already-tested** | `Skip the re-run when a PR already tested this exact tree`: `scripts/ci/already-tested.sh` compares the checkout tree with a successful run's `tested-tree` artifact. Runs only on `push` and `merge_group`. Missing or expired artifacts and API failures leave `skip=false` |
| **elixir-sdk** (×2) | The Elixir SDK on its declared minimum (1.15.8 / OTP 26.2.5.21) and the pinned current pair, plus conformance fixtures |
| **python-sdk** (×2) | The Python SDK on 3.9 and 3.13, conformance fixtures, and a built wheel installed into a fresh venv outside the source tree |
| **typescript-sdk** (×2) | The TypeScript SDK on the minimum Node in `engines.node` (20.19.0) and on 24, conformance fixtures, and the packed tarball installed into a throwaway consumer project |
| **swift-sdk** (×2) | The Swift SDK on ubuntu-24.04 (upstream Swift 6.1.3) and macos-15 (Apple Swift 6.1.2 from the installed Xcode 16.4), with its own conformance step. Both satisfy the package's Swift 6.1 minimum. Update the Xcode pin when the runner image retires it. It runs no `sdk/conformance/lint.py` |
| **cli-plugins** | Both Go modules (`cli/` and `apps/fountain_buzz/cli`) with vet and gofmt, the Hermes plugin, and the deployed-instance runner tests under `deployed/test/` |
| **core-distribution** | Builds with `BUNDLE_EXTENSIONS=false`, boots and migrates a fresh database, probes health, and checks that extension applications and API paths are absent; then rebuilds with extensions to check their inclusion. Skips docs-only changes and reused trees |
| **compose-fresh-clone** | `docker compose config --quiet` without `.env`, `SECRET_KEY_BASE` or `MASTER_SECRETS_KEY`, so the documented database-only startup can load the Compose file |
| **compose-pinned-image-boot** | `scripts/compose-boot-check.sh` exercises the Compose quick start against its pinned release image. An unpublished pin that matches the version in `mix.exs` defers the boot check to `release.yml`; any other missing pin fails |
| **docs** | Compiles the embedded manual, runs `scripts/test-docs.sh` (core and extension documentation suites), and runs CLI documentation parity when `cli_docs` is true. Selected only when `docs_only` and `manual_docs` are true and the tree is not reused; skipped on `push` |
| **gate** | `CI required`: validates every expected job result and records a successful PR checkout tree |

`mix hex.audit` is not one of these: `scripts/hex-audit-gate.exs` fails the
build on a security advisory unless it is acknowledged in `mix.exs`, and only
retirements stay non-blocking. `config/hex_advisories.exs` additionally
acknowledges the incorrect Decimal CVE-2026-32686 finding for the reviewed
3.1.1 artifact only, matching both checksums; remove it when the EEF feed is
corrected (`decisions/evidence/decimal-advisory.json`,
`python3 scripts/verify-decimal-audit.py`).

Outside `ci.yml`, `dead-code.yml` publishes a monthly advisory report of
public Elixir functions nothing calls and unreachable Go functions
(`scripts/dead-code.sh` locally; CONTRIBUTING.md, "Finding dead code", says
how to read it). It gates nothing.

Measure the slowest partition plus coverage and runner queue delays before
adding runners. Dialyzer can dominate cold runs; the core release has its own
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

## Activate required checks after merging

The repository ruleset is external state, so opening this PR does not change
merge permissions. Once the workflow is on main and its checks have passed:

```sh
# Inspect the complete update, preserving the existing rules and bypass list.
python3 scripts/ci/require-checks.py > /tmp/fountain-required-checks.json
cat /tmp/fountain-required-checks.json
# Apply only after review. This refuses until both checks pass on main.
python3 scripts/ci/require-checks.py --apply
```

This requires `CI required` and `Detect secrets` from GitHub Actions. It
preserves an existing status rule's strictness if one already exists. Run the
preview again after applying to verify the stored policy.

## The merge queue

`--merge-queue` adds the queue rule and turns the up-to-date requirement off,
because the queue supersedes it: instead of asking a PR to prove it was rebased
recently, the queue builds the exact tree the merge will produce and merges
only if that passes.

It deliberately does **not** touch the review requirement. A PR still needs its
approving review before GitHub will enqueue it at all — an unreviewed PR does
not fail, it simply never enters the queue, which is worth knowing before
debugging a `--auto` that appears to do nothing.

```sh
python3 scripts/ci/require-checks.py --merge-queue    # preview
python3 scripts/ci/require-checks.py --merge-queue --apply
```

`--apply` refuses unless `ci.yml` and `secrets-scan.yml` **on main** carry a
`merge_group:` trigger. That order is the one failure that has no visible
cause: a queue whose required checks never start does not fail a PR, it waits
out `check_response_timeout_minutes` and ejects it, with no red job anywhere to
explain why. `test_every_event_the_workflow_triggers_on_is_a_plan` in
`test_gate.py` keeps the workflow and `gate.py` from drifting apart later.

Four CI events now exist, and `gate.py`'s `PROBES` table is the authority on
what each one owes:

| Event | Probes that run | What the plan means |
|---|---|---|
| `pull_request` | `changes` | Classify the diff; docs-only skips the Elixir suite |
| `merge_group` | `changes` + `already-tested` | Classify the group, and skip it outright when its tree is one a PR run already tested |
| `push` | `already-tested` | Main reuses the queue run (or a PR run) that tested this tree |
| `workflow_dispatch` | `changes` | Run the complete plan, without diff-based skips or tree reuse |

The queue run and main's push both look for the `tested-tree` artifact, so a
queued merge normally costs one full run, not two: the queue runs the suite,
and main's push finds the queue's artifact and finishes in seconds. Main finds
it through the queue's `gh-readonly-queue/<base>/pr-<number>-<sha>` branch
name, which is the only link back from a squashed commit to the run that
tested it.

### Landing a change

The contributor procedure is in
[CONTRIBUTING.md](../../CONTRIBUTING.md#pull-requests).

Each queued PR gets a merge-group build; one builds at a time under the current
runner budget. Merge wait settings delay merging after a build; they do not
combine builds. An unreviewed PR does not enter the queue, and a failed group
is ejected. Main reuses successful tested-tree evidence as described above.

### Sizing

`MERGE_QUEUE` in `require-checks.py` explains the queue settings. A full mixed
PR runs 24 jobs; a full merge group runs 25 because both probes run. The
documented limit is 20 concurrent runners. The queue builds one group at a
time. Its merge settings do not batch builds. Revisit
`max_entries_to_build` when the concurrency limit changes.

## SDK jobs

The Elixir, Python and TypeScript SDKs run in `elixir-sdk`, `python-sdk` and
`typescript-sdk`. The Go CLI, Hermes plugin and deployed-runner checks run in
`cli-plugins`. The Swift job (`swift-sdk`) runs on Linux and
macOS. Each reads the committed contract; `release-and-contract` checks its
generation.
The Elixir job owns its toolchain, cache, formatting, compilation, tests, docs,
package dry run, contract and conformance checks. It tests Elixir 1.15.8
with OTP 26.2.5.21 and Elixir 1.19.2 with OTP 28.3. Formatting uses 1.19.2
because formatter output differs between versions; all remaining checks run
on both pairs. The Python job owns its
tests, compilation, contract and conformance checks on Python 3.9 and 3.13.
Both legs also build an sdist and wheel, install the wheel in a fresh virtual
environment and run the SDK regression suite against that installed package.
This replaces the full source-tree test run; separate contract and conformance
steps retain their focused diagnostics.
The verifier checks the type marker, package version and every SDK import path.
These cover the package minimum and newest declared runtime. Both legs must
pass; a failure does not cancel the other leg. The TypeScript job owns
installation, type checks, tests, builds, browser bundling, contract and
conformance checks on Node 20.19.0 and 24. The minimum runtime runs compiled
JavaScript from the same test sources in a temporary fixture tree. Node 24
retains native TypeScript tests. Both legs build the SDK and browser bundle.
They also pack and install the npm artifact in a temporary consumer project.
That project typechecks against the published declarations and exercises the
Node and browser entry points with a fake fetch implementation. It also bundles
that consumer for a browser, checking the package export conditions.
These three extracted jobs lint fixtures before their
tests. Swift retains its separate conformance test step.
**The four SDK jobs run on every plan.** Pull requests, merge groups, manual
dispatches and main pushes all run them, docs-only plans included; the one
thing that skips an SDK leg is verified tested-tree reuse, exactly as it
skips the server jobs. There is no per-language path classification: each
leg is a fraction of a minute, and the routing that used to skip an
unselected language cost more to keep right than it saved. `CI required`
requires all four directly; a failed, cancelled or unexpectedly skipped leg
fails the gate.

Register a new job in `gate.py`'s `FULL_JOBS` and the workflow gate's
`needs` list together. For an SDK job, also add it to `SDK_JOBS`, which is
what keeps it required on a docs-only plan. Run `test_gate.py` to verify
their agreement and every supported event plan.

## Documentation path classification

`changes.py` reads one NUL-delimited diff with rename detection disabled, then
selects documentation checks from those paths. The contributor-only
allowlist includes ADR and changelog-fragment Markdown. Non-Markdown decision
evidence, executable files and new extension directories select the full server
plan. A move out of code retains the old code path in
the diff. Missing bases, failed/empty diffs and malformed paths select full CI.

`docs_only=true` skips the server suite. `manual_docs=true` additionally requires
the `docs` job on that short path; contributor-only text needs no Elixir job.
The gate validates these booleans, and `cli_docs=true` requires manual
checks. An SDK's README is documentation for this purpose; its SDK job runs
either way. The documentation job honors verified tree reuse on the merge
queue, just like the server jobs.

See [the manual contribution guide](../../contributing/docs.md#checks-for-documentation-changes)
for the path table and matching local commands. Register an extension's docs
in `MANUAL_EXTENSIONS` and `scripts/test-docs.sh` together; the routing tests
check that the selected manuals have runnable documentation suites.

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
The allocator reserves 30 seconds on partition 1 for the sibling suites,
measured at 26-34 seconds on September 5, 2026. Update that reserve when the
`Run the sibling apps' tests with coverage` step changes materially.

The core release uses a separate cache of compiled production modules. The
assembled release is rebuilt each time, including the check that toggles from
the core distribution to the bundled distribution.

## Manual public-link check

`python3 scripts/ci/check_external_links.py` checks public GitHub documentation
links on demand. It is not part of merge CI. The manual's compilation, internal
links, anchors, snippets, nav and CLI docs parity remain blocking checks in the
Elixir and Go suites. See [the manual contribution guide](../../contributing/docs.md).

## Check the CI policy locally

```sh
python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
python3 scripts/changelog.py check
actionlint -shellcheck= .github/workflows/ci.yml
shellcheck scripts/ci/*.sh
elixir scripts/ci/timing-formatter-test.exs
```

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
commands and release checks. The separate SDK matrix retains its toolchains.

**Retirement:** remove the wrapper, patch and CI installation steps when the
pinned Elixir release contains #15765 and these regressions pass against its
native module. As checked on 2026-09-13, neither 1.19.6 nor 1.20.4 contains the
fix; a patch-version bump alone does not address this race. Version and source
fingerprint guards intentionally fail when the toolchain changes, requiring
that review rather than silently patching a different implementation.
