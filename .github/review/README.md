# Fountain Review Loop

Four independent reviewers examine the entire current PR, including any fixes:

| Reviewer | Runtime / model | Focus |
|---|---|---|
| `qa-team` | Codex / GPT-6 Astra | Correctness, regression tests, database behavior, concurrency and recovery |
| `security-audit` | Codex / GPT-6 Astra | Tenant isolation, secrets, injection and authorization boundaries |
| `product-api` | Claude / Opus | Documented product intent, naming, rollout and client compatibility |
| `xp-reviewer` | Claude / Opus | Simplicity, useful tests and maintainability |

The PostHog-inspired cycle is review → triage → permitted fix → checks and
independent verification → four fresh reviews. Review Loop posts inline finding
threads and keeps one summary for the run updated. It consolidates duplicate
findings, accepts low/info suggestions as nonblocking, and retains explanations.
It resolves service-owned threads when policy permits; human objections remain
blockers until a maintainer addresses them.

Clear medium-or-higher defects can receive an automatic fix within the
configured file and path bounds. The host enforces the configured file bound,
permitted paths, three-round limit, exact-revision checks and final approval.
Confidence is a reviewer judgment, not a separate numeric score enforced by
the host. This setup does not impersonate Paul or launch an interactive
pairing agent.

Review Loop separates the next actor from the severity of a finding. Confirmed
code defects receive a commit-specific GitHub `CHANGES_REQUESTED` review when
the automatic fixer cannot complete them. A coding agent can make those repairs
under its own repository authorization, including outside the bot's path or
file allowance. Low/info defects remain nonblocking when policy permits.

`needs:human-review` is reserved for an unsettled decision or explicit approval
requirement. Reviewers use `kind: product_decision`, `needsHuman: true`, and a
`humanDecision` containing the question, alternatives with consequences, and
recommendation. Apply requirements already settled by the approved base: a
repair restoring an accepted ADR is ordinary coding work; changing the ADR's
decision needs authority. The trusted `human_review_paths` still cover review
policy, workflows, migrations, licensing, deployment/release definitions, gate
controls and ADR changes. Automatic fixer permissions remain unchanged.

A PR with both repairs and a decision receives both signals. Provider failures,
missing evidence and uncertainty alone are incomplete execution, not a human
decision. The run API exposes `outcome`, `humanReviewRequired`, and reasons for
routing. Check App identity and current commit before reacting to review events.

An approval covers the entire evaluated PR and never merges it. A new revision,
failed check or human objection can invalidate an earlier approval. Repository
policy and all reviewer/setup instructions come from the trusted base revision.
A PR cannot authorize itself by editing these files.

Reviewer runtimes and models are pinned in `.github/review-loop.yml`. The fixer
uses the operator-selected default. Parallelism is bounded by host and Fountain capacity. The repository policy permits four
reviewers at once, 30 tasks, 50,000,000 reported tokens and 120 minutes per run.
Daily budgets are separate operator settings. Neither token nor task counts
are dollar-cost reporting.

## Verification and activation

`setup.sh` installs pinned, hash-checked toolchains on a fresh Ubuntu 24.04 or
26.04 worker before PR checkout, plus a disposable local PostgreSQL database
(the supported distro major, 16 or 18). GitHub CI separately verifies PostgreSQL 16.
Nineteen commands run the core partitions, sibling-app and single-VM umbrella
tests, precommit static checks, Dialyzer, prod release assembly,
contracts, the TypeScript SDK, CLIs and plugin tests. The six required workflow definitions
and their path filters were checked against Fountain main at
`539a300207728bebc5216af586e497ce07778f94`. GitHub CI additionally supplies
coverage, release boot, docs and distribution gates. No failed
gate is skipped or changed to get an approval.

An existing Go guest-handshake fixture race is tracked in
[#1641](https://github.com/managoat/fountain/issues/1641), reproduced in
2 of 100 focused local runs on the inspected main revision. Its gate remains
enabled. A confirmed failed check requests changes; missing execution is incomplete;
rerunning until it turns green is not evidence that the defect was fixed.

Deploy Review Loop outcome-routing support before using these reviewer contracts.
The expanded recipe needs a thirty-minute command allowance: its measured cold
Credo/Dialyzer stage took about 23 minutes and the full recipe about 48 minutes.
See [measured command budget](verification.md#measured-command-budget).

Merge this configuration through Fountain's normal reviewed PR process. Its
own changes require human review; no live run can use its policy before merge.
The dispatch workflow uses the public `managoat/review-loop-action` at an
immutable release commit, with no inline script. Configure repository variables
`REVIEW_LOOP_URL` to
`https://review-loop.demo.managoat.com` and `REVIEW_LOOP_ENABLED` to `true` after
the policy is trusted. The workflow admits opened, updated, reopened or
ready-for-review PRs from branches in this repository. Draft and fork PRs are
excluded. Existing PRs need a subsequent event or an explicit run from the app.

Repository access comes from the Managoat Review Loop GitHub App installation;
no Fountain login or inference secret belongs in repository Actions secrets.
To stop automatic admission, set `REVIEW_LOOP_ENABLED` to `false`; cancel active
runs separately in Review Loop. Maintainer commands and decisions are documented
in the service's [GitHub lifecycle guide](https://github.com/managoat/review-loop/blob/main/docs/GITHUB-LIFECYCLE.md).

## Reviewer workspace preparation

`reviewer-setup.sh` prepares the exact PR checkout using the verifier bootstrap
from `REVIEW_LOOP_BASE`, then installs locked Hex dependencies and migrates a
local test database. Review Loop loads this script from the approved base and
bounds setup to 15 minutes; the [cold preparation sample](verification.md#measured-reviewer-preparation) took 6m30s including a targeted test. A changed tracked file or failed setup stops review.

Run diagnostics through `rl-env`. Setup success is not a passing test result;
independent service verification still decides whether the revision passes.

Hex 2.5.1 passes only a proxy host/port to Erlang httpc, so it cannot directly
use Fountain's HTTPS proxy. The recipe starts a loopback-only socat relay and
wraps `rl-env` to use it. The remote connection validates the broker's certificate
chain and hostname; authentication stays in process environments. The relay and
database belong to this ephemeral worker and end when it is deleted.

Test the relay with `python3 scripts/test-reviewer-proxy.py` on Linux with Python 3,
OpenSSL, and socat installed. It executes the recipe's relay code using temporary
paths and local certificates, covering valid TLS, wrong hostnames, untrusted
issuers, changed endpoints, and credential placement. It needs no provider keys.

`python3 scripts/test-reviewer-setup-cwd.py` checks that bootstrap ignores PR-local
Python modules while repository dependency/database commands enter the checkout.
