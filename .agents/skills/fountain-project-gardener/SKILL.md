---
name: fountain-project-gardener
description: Audit, triage, prune, and refresh the managoat/fountain GitHub Project, its issues, labels, iterations, views, workflows, and access. Use when someone asks what work remains, what is stale, how to prioritize the backlog, or to organize or clean up Project #1.
---

# Managoat Project Gardener

Keep the Managoat GitHub Project trustworthy enough that a contributor can tell what matters now, what comes next, and why work is blocked.

This skill may inspect, recommend, or apply changes. Infer the requested mode from the caller's words. An audit or question is read-only. A request to clean, organize, prune, refresh, or update authorizes ordinary in-scope project maintenance, but not irreversible cleanup or changes to product priorities that the caller has not supplied.

## Establish ground truth

Read [references/project-policy.md](references/project-policy.md) before acting.

Prefer `gh` and GitHub APIs for semantic operations. Use a signed-in browser only for Project settings that the CLI/API cannot safely handle. Before any mutation, verify both the active GitHub identity and the target owner; a browser session and `gh` may be signed into different accounts.

Inspect the live repository and Project before relying on the reference baseline. At minimum, examine:

- open issues and pull requests, including linked and soon-to-merge PRs;
- Project item counts by Status, Horizon, Iteration, Workstream, Size, and repository state;
- items in Triage, Blocked, Now, and the current/next iteration;
- closed items not marked Done and old completed items not archived;
- priority and area label usage, empty or overlapping labels, and labels used only on closed work;
- iteration coverage, views, automation workflows, and collaborator access.

Report query failures and incomplete visibility. Do not treat missing API fields or a partial page of results as zero.

## Interrogate for judgment, not facts GitHub can answer

Inspect first, then ask concise questions in batches of at most three. Skip questions already answered by the caller or repository state. Continue asking only while an answer would materially change prioritization or cleanup.

The highest-value questions are:

1. What outcome or release must not slip, and is there a real date?
2. Who has capacity in the next one to four weeks, and what work is already effectively committed or under review?
3. How aggressive should pruning be: organize only, archive superseded work, or propose closing obsolete work and deleting redundant labels?

When relevant, ask which dependency or decision can unblock an item, whether a tracker still represents an active program, or whether contributor-friendly issues should be preserved even when they are not near-term.

State useful defaults instead of blocking on optional answers:

- Preserve existing Now/Next choices if no new objective is supplied.
- Do not promote work when capacity is unknown.
- Use conservative cleanup when pruning posture is unspecified.
- Treat pending reviewed PRs as near-complete work and avoid reshuffling their linked issues.

## Produce a decision-ready gardening pass

Separate findings into:

- **One-time cleanup:** imported or historical drift that should be reconciled once.
- **Recurring maintenance:** small actions required weekly or monthly.
- **Priority decisions:** choices that need product or maintainer judgment.
- **Automation gaps:** repetitive state transitions GitHub can own.

For each proposed change, give the reason and the exact affected items or labels. Order work by risk and leverage:

1. Production, security, data-loss, and release-blocking work.
2. Active work and reviewed PRs that can be completed or unblocked cheaply.
3. Decisions or external dependencies blocking multiple downstream issues.
4. Near-term reliability and committed roadmap work.
5. Backlog hygiene, documentation, and opportunistic improvements.

Prefer closing loops over increasing work in progress. Trackers describe programs; executable child issues carry iteration, size, and day-to-day status.

## Apply changes safely

Ordinary reversible organization includes assigning Project fields, adding appropriate existing labels, moving unblocked work between Triage/Ready/In progress/In review/Blocked, adding future iterations, and correcting clear automation drift.

Require the caller to confirm an exact proposed set before any of these actions:

- close or delete issues;
- delete or rename labels, fields, views, workflows, iterations, or projects;
- remove collaborators or reduce access;
- change P0/P1 priority, Horizon Now, ownership, or a committed target date based on inference;
- archive a large batch whose contents the caller has not reviewed.

Never delete a label merely because it is old or unused. First verify that it has no unique policy meaning, migrate every open use to the intended replacement, check automation and documentation references, and show the deletion list. Never remove an issue from the Project merely to make counts look clean.

After mutations, query the live state again. Summarize what changed, what remains intentionally untouched, any questions still requiring a maintainer, and the next date or condition that should trigger another gardening pass.
