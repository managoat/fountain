# Fountain Project Policy

## Scope and identity

- Repository: `managoat/fountain`
- Organization-owned Project: `managoat` Project `1`
- Project URL: `https://github.com/orgs/managoat/projects/1`
- The Project is private. Repository collaborators should normally have Write access unless the caller specifies a narrower policy.
- A superseded copy of the same board survives at `https://github.com/users/BinaryBourbon/projects/1` from before the move to the `managoat` organization. It is still private, still holds its items, and its auto-add still captures new `managoat/fountain` issues, so the two boards drift. Read it if you need history. Do not mutate it, and do not treat its contents as current.
- Several GitHub identities can reach both boards, and the `project` scope is not on every token. Verify the active identity and the target owner at the point of mutation.

Treat this as an expected configuration, not proof of current state. Query GitHub every time.

## Field semantics

### Status

- **Triage:** captured but not yet made execution-ready.
- **Ready:** sufficiently defined and unblocked; someone could start it.
- **In progress:** actively being worked, with an assignee.
- **In review:** implementation is awaiting review or merge.
- **Blocked:** cannot advance until a named decision, dependency, or external event occurs.
- **Done:** closed or merged.

Do not use Status as a statement of strategic importance.

### Horizon

- **Now:** a current commitment. Keep this deliberately small.
- **Next:** a credible candidate for the next few weeks, subject to capacity.
- **Later:** useful but not scheduled.
- **Parked:** deliberately not being pursued; retain only when the record still has value.

Do not use Horizon as a workflow state. A blocked issue can still be Now; a Ready issue can still be Later.

### Priority labels

- **P0:** production emergency, active security exposure, data loss, or an immediate existential release blocker.
- **P1:** critical reliability or committed release work with near-term impact.
- **P2:** important planned work.
- **P3:** opportunistic, low urgency, or contributor-friendly work.

Priority is relative impact and urgency, not implementation order by itself. Do not infer P0/P1 from age, comment volume, or a maintainer's enthusiasm.

### Other fields

- **Workstream:** use one primary owning domain: Broker, Production safety, Conversation reliability, Render, API/SDK, Architecture, or Distribution.
- **Iteration:** assign executable Now/Next work when capacity makes the plan credible. Keep at least four future weekly iterations available.
- **Size:** estimate Now/Next executable issues as S/M/L/XL. Do not estimate the entire Later/Parked backlog.
- **Target date:** reserve for genuine external or release commitments, not aspirational scheduling.

## Labels

Prefer labels for durable issue meaning and cross-repository search; prefer Project fields for execution state.

Retain these label families unless the caller deliberately changes the taxonomy:

- priorities: `P0`, `P1`, `P2`, `P3`;
- durable ownership: `area:*`;
- issue nature: `type:*`; language/ecosystem: `lang:*`;
- contribution: `good first issue`, `help wanted`;
- coordination: `type:tracker`, `needs:*`, `stack:*`; scope: `scope:*`;
- disposition: `status:deferred`, `resolution:duplicate`; preserve any other terminal semantics.

Campaign labels such as `campaign:render-2026-09` may be useful while a bounded program is active. Retire them only after the campaign is complete, all open uses have a durable replacement, and no automation depends on them.

Project fields remain authoritative for Status, Horizon, Size and Iteration. `status:deferred` is an explicitly requested repository-search label; keep it consistent with recorded deferral decisions. See `standards/github-labels.md` and `.github/labels.json` for the current label families, colors and definitions.

## Expected views and automation

Expected views include Backlog, Now, Next, Programs, Risks, Inbox, and Roadmap. Their exact filters may evolve, but each should answer a distinct maintainer question.

Expected automations include:

- add matching open repository issues;
- set newly added items to Triage;
- mark closed items Done;
- return reopened items to Triage;
- move issues with linked pull requests to In review;
- archive sufficiently old completed items.

Automation is support, not evidence. Test or inspect it after configuration changes and reconcile items created before a workflow was enabled.

## Freshness checks

Use these signals to guide the conversation, not as blind mutation rules:

- Inbox/Triage contains items older than the team's chosen response window.
- Now exceeds actual contributor capacity or contains unowned work.
- In progress has no assignee, recent activity, or credible next action.
- In review has no open linked PR, or the PR merged without the issue closing.
- Blocked lacks a named dependency/decision or has not been revisited for two weeks.
- Next has no plausible iteration or more work than the next few weeks can absorb.
- Current/next iterations are missing or contain unfinished work that rolled silently.
- P0/P1 issues lack owners or a next action.
- Closed items are not Done, or old Done items remain unarchived.
- Campaign labels outlive their programs; redundant labels reappear.
- Project access drifts from repository collaborator access.

## Sustainable cadence

- **Twice weekly, about 10 minutes:** empty or explain Triage; update active, blocked, and review states.
- **Weekly, about 20 minutes:** reconcile current iteration, protect a small Now set, promote only to available capacity, and close completed tracker loops.
- **Monthly, about 30 minutes:** revisit Later/Parked, extend iterations, inspect label entropy and workflow health, review old blockers, and verify access.
- **After a release or program completes:** close or re-horizon the tracker and children, then propose retiring any temporary campaign labels.

The goal is not a perfectly classified backlog. The goal is a Project whose top few decisions and next actions are true.
