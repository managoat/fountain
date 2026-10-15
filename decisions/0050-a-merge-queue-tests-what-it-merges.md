---
type: ADR
title: "A merge queue tests what it merges"
description: "Superseded 2026-10-15 by 0078: no merge queue; a PR merges by admin squash merge once CI is green. Was: Main takes ~26 merges a day and half land a tree no CI run ever tested; a GitHub merge queue builds the merge result before it merges. The up-to-date requirement comes off because the queue supersedes it; the review requirement stays, so a PR needs an approval before it can be queued at all."
tags: [ci, process, github]
status: deprecated
adr: "0050"
adr_status: "Superseded by 0078"
date: 2026-09-10
generated: { by: claude-opus/5, at: 2026-09-10T12:00:00-04:00 }
verified: { by: claude-opus/5, at: 2026-09-10T12:00:00-04:00 }
---

# 0050 — A merge queue tests what it merges

**Status:** Superseded by [0078](0078-one-maintainer-process.md) on
2026-10-15; see the addendum at the end. The text above the addendum is
history. Was: Accepted. Built: the `merge_group` CI plan, the tree-proof link
from a queue run to main, and `require-checks.py --merge-queue`. The ruleset
itself is external state, so the queue is live only once that command has been
applied.

## Context

Main took 775 merges in the 30 days to 2026-09-10 — about 26 a day, peaking at
55. A PR that was green an hour ago was green against a different main.

The repository already knew this. `already-tested` skips main's re-run only
when the pushed tree equals a tree some PR run actually tested, and it misses
roughly half the time: measured over 100 recent pushes to main, 53 skipped and
the rest ran the full suite because the branch was one or two commits behind at
merge. Those misses are not a defect in the probe. They are the honest report
that **half of what lands on main is a tree no CI run has ever seen.**

What that is *not* is a crisis of correctness: main failed 4 times in 300 push
runs (1.3%). The cost is elsewhere. Every miss is a full ~12 minute re-run on
main, it delays the deploy that is gated on main's CI, and it blocks the
build-in-PR-and-retag idea outright, because a PR-built image is reusable only
when the merged tree is the tested tree.

Two constraints shaped the design more than the volume did:

- **The organization is on the free plan: 20 concurrent GitHub-hosted jobs.**
  One full CI run was 19 of them when this was decided. A burst of ten
  agent-opened PRs on 2026-09-10 produced a run whose jobs waited 29 minutes
  before starting and then finished in 7. Runner concurrency, not test time, is
  what this repository runs out of. (After #1413 split the SDK job per language
  and added three runtime matrices, and prose checks were removed, a full mixed
  PR is 25 jobs and a merge group 26 — a single run now exceeds the ceiling
  on its own, which strengthens rather than changes the sizing below. `scripts/ci/require-checks.py` restates the
  count in its own comment, which can drift the same way this one did; count
  the legs in `ci.yml` if it matters.)
- **72% of open PRs are stacked** — 31 of 43 target another PR's branch rather
  than main. GitHub only queues a PR based on the protected branch.

## Decision

Merges go through a GitHub merge queue. `gh pr merge <N> --squash --auto`
queues a PR; the queue builds the exact tree the merge would produce and merges
only if that tree passes.

CI learns a third event. `gate.py`'s `PROBES` table is the authority: a
`pull_request` runs the `changes` classifier, a `push` runs the
`already-tested` probe, and a `merge_group` runs **both** — it classifies the
group like a PR, and it skips the group outright when the group's tree is one a
PR run already tested. A merge group publishes the `tested-tree` artifact, and
main's push finds it through the queue's
`gh-readonly-queue/<base>/pr-<number>-<sha>` branch name, which is the only
link back from a squashed commit to the run that tested it. A queued merge
therefore costs one full run, not two.

The queue builds one group at a time (`max_entries_to_build: 1`) and buys its
throughput by batching up to five PRs into that group instead, because
speculating two groups deep cannot run two groups on a 20-job ceiling — it
queues the second behind the first while starving every open PR.

**One rule comes off: the up-to-date requirement.** It was an approximation of
"tested against what it will merge into", and the queue tests that directly.
Keeping both only forces rebases to prove what the queue is about to prove
properly.

**The review requirement stays at one approval**, and this was reconsidered
deliberately. Dropping it to zero is tempting because the arithmetic favours
it: a solo-authored PR cannot satisfy it, so merges here became
`gh pr merge --admin`, and an admin merge skips the queue — which makes the
queue look inert. But the two gates answer different questions. The queue
answers *does this tree build*. Review answers *did anyone read it*, and on a
repository where most PRs are written by agents that is the question worth
keeping. Turning on a machine that checks the first is not a reason to stop
asking the second.

The cost is real and is accepted: an approval has to come from somewhere before
a PR can be queued at all, because GitHub will not enqueue a PR whose merge
requirements are unmet. An unreviewed PR does not fail — it simply never
enters. On this repository that means a human approving from the second
account, and `--admin` remains available for a genuine emergency, where it
still skips the queue and still says so in the PR.

## Consequences

Main stops accepting untested trees, `already-tested` hit rate goes to
essentially 100%, and build-in-PR-and-retag becomes possible for the first
time (its own prerequisite, `BUILD_SHA` baked into the image, is unchanged and
still has to be injected at deploy time).

Merging stops being instant. Every queued PR gets its own `merge_group`
build and one builds at a time, which is the job-ceiling cost, so a queued PR
waits for the entries ahead of it and merges when its own build passes. (The
queue first shipped with merge limits of two entries and a five-minute wait,
on the belief that they batched builds. GitHub's merge limits only delay a
merge after a build passes and never combine builds, so the wait held a green
entry for up to five minutes and saved nothing; it was removed in September
2026.) Nothing should wait on a queued PR synchronously.

A queued PR can be ejected. That is the mechanism working: the failure is the
change against a main it had never been tested with. It stays open with the
failure attached.

**Stacks do not change.** A stack still lands one stage at a time, because only
the tip targets main. What changes is that GitHub performs the retarget when
the parent merges, which removes the trap where a stale base merged cleanly
into a branch that no longer existed.

CI spend rises. A merge that today skips main entirely now pays for a queue
run. Batching is what keeps that from being a straight doubling, and the
docs-only classifier still runs in the queue, which matters for the 11% of
merges (85 of 775) that touch nothing but markdown.

The bypass remains. Organization admins can still merge past the queue, so the
guarantee is a matter of discipline rather than enforcement; CLAUDE.md says so
in *Things NOT to do*.

## Alternatives considered

- **Rebase before merging, no queue** — the cheap version of the same lever,
  and it was the standing advice before this. It depends on remembering, it
  does not survive a burst of agent-opened PRs, and it cannot batch.
- **Drop the review requirement to zero** — considered and rejected. It buys
  the tidier story (every PR reaches the queue, no `--admin` anywhere) by
  deleting the only gate that asks whether a human read the change, which is
  the wrong one to delete on a repository this agent-heavy. Requiring an
  approval means some PRs wait on one; that is the intended behavior, not a
  defect to engineer around.
- **A smaller PR run, full suite only in the queue** — the mature pattern, and
  the right answer if CI spend becomes the binding constraint. It trades away
  PR feedback quality, which is the thing agents working here depend on most.
- **More runners** — addresses the 20-job ceiling but not the untested-tree
  problem, which is the actual finding.

## Addendum — 2026-10-15: superseded by 0078

Fountain has one maintainer, and the review requirement this decision kept
could not be met by the only person merging, so every merge was an admin
merge that skipped the queue. [0078](0078-one-maintainer-process.md) removes
the queue: the `merge_group` triggers, the `already-tested` probe and its
`tested-tree` artifact, and `scripts/ci/require-checks.py` are gone. A PR
merges by an admin squash merge once its CI is green, and every push to
`main` runs the complete plan.
