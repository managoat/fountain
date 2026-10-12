# Fountain verification

The service uses the base policy and setup bytes, checks out the exact PR head
on a separate machine, and records command exit/output evidence. Setup installs
OTP 28.3, Elixir 1.19.2, Node 24.20.0, Go 1.26.0, Hex 2.5.1 and Rebar 3.25.1,
and starts the supported Ubuntu image's packaged PostgreSQL (16 or 18) on
loopback. GitHub CI also verifies PostgreSQL 16. Commands use rl-env so tool paths and
the disposable database settings survive between shells. No Fountain login,
GitHub write token or provider credential belongs in this machine.

Independent verification runs all six core test partitions sequentially
using the upstream runner's nonzero-test and coverage-export guards, then runs
every sibling app's suite and root umbrella tests in one VM. The root run catches
cross-app configuration leaks that separate CI partitions cannot. It covers the core `mix precommit` stages: compilation,
unused-dependency/lockfile checks, formatting, Credo, Dialyzer in dev, security
scanning, release assembly in prod, and tests. Commands fail fast, including grouped stages that keep the policy within
20 entries; any failed stage makes verification incomplete. Plain `mix deps.get` preserves dev/test dependencies
when preparing prod. It also checks the wire contract, conformance fixtures, the TypeScript
SDK, both Go modules and the Hermes plugin. Each command must
exit successfully; a failed stage is not excused by a later successful one.

The complete GitHub CI workflow additionally supplies the six-way partitioned
coverage gate, release boot, generated-type freshness, docs prose, core
distribution and Compose checks. The secret scan
always applies. Other required workflows follow the actual SDK, ADR and sandbox
image path filters in the base policy. Only success for the recorded PR, head
and base counts. The dispatch job only acknowledges admission.

A missing tool, absent workflow result, stale contract, setup failure, empty
test run or exhausted deadline leaves incomplete work. Do not skip tests, lower
coverage thresholds, rewrite verification scripts or add release-bypass labels
to obtain approval. Docs-only PRs still receive independent core verification
in this initial recipe; their conditional GitHub CI path is preserved.

## Measured command budget

At `d7b668a27dbeaeb3e32434b7800075ab6a849f2c`, all twenty commands passed on a
fresh isolated worker in about 48 minutes, with two BEAM schedulers. The
library/umbrella command took 8m49s and cold Credo/Dialyzer took 22m50s. The
worker was deleted afterward. An earlier ten-minute attempt timed out during
library/umbrella tests; that failure and its deletion remain recorded.

The policy therefore gives each command up to thirty minutes, within the
existing 120-minute run deadline. Pre-push and post-push independent verification
can together consume roughly 96 minutes before review and GitHub CI; extra fix
rounds are permitted only while the remaining budget allows. Do not skip gates
or raise a deadline merely to report success.

Deploy a Review Loop version supporting `verification.command_timeout_minutes`
before merging this policy. The measured standalone recipe is not evidence of
a production candidate check or PR approval at this configuration.

## Measured reviewer preparation

A cold, isolated Ubuntu worker on September 7, 2026 completed the reviewer
bootstrap, locked dependency installation, database migration, and the additional
environment-controller diagnostic in **6m30s**. The diagnostic returned **18 tests,
0 failures**, including the second-tenant setup-timeout denial case. The configured
15-minute setup bound provides over eight minutes of headroom over this sample;
it is not a worst-case guarantee. This excludes Credo, Dialyzer, full test suites,
and the independent verifier's broader recipe above.

The subsequent model review stalled; cancellation and physical worker deletion
succeeded. A second cold probe completed preparation, the same 18-test diagnostic,
and delivery of a correctly identified result artifact within **8m25s total**;
physical worker deletion also passed. That artifact deliberately marked full PR
coverage incomplete. These samples prove preparation and diagnostic delivery,
not full PR approval or enrolled-policy acceptance. The bootstrap now also runs
outside the PR checkout, with a local regression for PR module shadowing.
