---
type: ADR
title: "Where auditing happens, and who the actor is"
description: "Mutations audit inside the context function with an explicit actor, so every surface is covered by construction. Documents behavior built by the #540 campaign."
tags: [audit, security]
status: stable
adr: "0013"
adr_status: "Accepted"
date: 2026-08-07
generated: { by: human:jhgaylor, at: 2026-08-07T15:03:06-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-07T15:03:06-04:00 }
---

# 0013 — Where auditing happens, and who the actor is

**Status:** Accepted (documents behavior built by the #540 campaign and the
convergence in the PR that adds this ADR; nothing described here is unbuilt)

## Context

Before #540, auditing depended on which door a mutation came through. A plug
on the `:api` pipeline recorded every API write; the browser surface recorded
whatever its LiveView remembered to; seven contexts recorded nothing at all.
Creating a **secret** through the UI left no trace, while the same write
through the API left one — the wrong way round for a product whose job is
holding tenant secrets (#543).

The campaign fixed that, and in doing so settled a rule, an actor vocabulary
and a set of exclusions that now bind roughly thirty context functions and a
guardrail test. Those live in `CLAUDE.md`, the `Fountain.Audit` moduledoc and
`audit_guardrail_test.exs`. All accurate, all enforced — and none of it
arguable-with. A future change that wants to audit at the caller, or to invent
a new actor string, has nothing to push against. Per this repo's own rule, an
ADR is how a decision constrains rather than merely describes.

## Decision

### 1. Mutations audit inside the context function, not at the caller

A function that changes tenant-owned state records its own event. The UI, the
API, background workers, the onboarding wizard, manifest apply and any future
surface are covered by construction rather than by each caller remembering.

Callers supply only what a context cannot know about its caller — `:actor` and
`:request_ip`, from `FountainWeb.Audited.attribution/2` on a web surface or a
`"system:<worker>"` string from a background one.

```elixir
def create_agent(attrs, opts \\ []) do
  %Agent{} |> Agent.changeset(attrs) |> Repo.insert() |> audited("agent.created", opts)
end

Agents.create_agent(attrs, Audited.attribution(conn))   # or (socket)
Agents.create_agent(attrs, actor: "system:my_worker")   # background caller
```

Three constraints fell out of building it, each of which cost real debugging:

- **Never record inside a transaction.** `Audit.record/1` is best-effort *by
  rescuing*, and a rescue does not undo an aborted transaction: a failed audit
  insert inside one poisons the enclosing transaction, so a lost audit row
  would take the mutation with it. Record outside. This bit
  `Agents.upload_avatar/4`, `Agents.delete_avatar/2` and
  `Accounts.register_user/2`.
- **Never record values.** Update events name the fields that moved
  (`Audit.changed_fields/1`); secret, credential and prompt events record
  keys, sizes and providers. The trail is not a second copy of tenant data —
  if it were, it would be the most sensitive table in the database and the one
  with the loosest read path.
- **Only record what happened.** A rejected changeset, a no-op sync, a
  re-assertion of a status the account already had: none of these record. A
  trail that logs attempts as changes is worse than no trail, because it
  cannot be read literally.

`apps/fountain/test/fountain/audit_guardrail_test.exs` enforces the rule: add a
context mutation and the guardrail fails until it audits, or until the function
is added to the documented exclusion list with a reason.

### 2. The actor vocabulary is closed

| Actor | Meaning |
|---|---|
| `self` | the account acted on its own behalf; the context default when no caller says otherwise |
| `ui` | a browser session |
| `api` | a bearer token |
| `sprite` | a per-conversation callback token — an agent acting *as* the tenant |
| `admin` | an operator acting on another account |
| `admin:<operator_id>` | the same, where the row must name the operator itself (see below) |
| `system:<worker>` | an unattended path, named after the worker |

`sprite` is separated from `api` deliberately: "the agent did this" and "the
account owner did this" are materially different claims, and the scopes added
for the sandbox privilege-escalation fix make them distinguishable.

`system:<worker>` names are snake_case and match the module doing the work:
`conversation_server`, `sandbox_reaper`, `retention_pruner`, `release_task`,
`provisioning`, `account_export`, `unverified_pruner`, `verify_lifecycle`,
`team_scheduler`, `webhook_delivery`, `onboarding`, and
in `ee/` the billing sources `webhook`, `stripe`, `local`, `trial_sweeper`.

`webhook_delivery` was added by [0024](0024-outbound-webhooks.md): the delivery
worker disables an endpoint after sustained failure, which is a mutation of
tenant state with no human behind it.

`onboarding` was added by [0038](0038-onboarding-first-reply.md) and #1389:
verification plants a starter agent in the account, which is an `agent.created`
in a tenant's trail that the tenant did not ask for. It is the one member of
the vocabulary named after a moment rather than a worker module, because the
work is done inline on the verification transition rather than by a background
worker of its own. `self` would have been the wrong answer for the same reason
`system` is wrong on the unauthenticated routes: it names a principal that did
not act.

Two rules keep the list from fraying:

- **`admin` beats `system:` when a human operator is behind the action.**
  `ee/` billing composes its actor from a `source` term, which produced
  `system:admin` for operator-driven trial extensions, comps and resyncs —
  the `system:` prefix asserting "unattended" about the one source that is a
  person. Operator sources now record `admin`; the `source` stays in metadata,
  so queries that group by source are unaffected. Rows written before this ADR
  still carry `system:admin`.
- **`admin:<operator_id>` is for account deletion only.** An admin action
  normally writes a paired `admin_audit_events` row that names actor and
  target, so the tenant-facing row does not need the operator's id. Deletion
  is the exception worth the special case: it is the action whose subject
  stops existing, and `audit_events.user_id` nilifies underneath it.

**Bare `"system"` is not a member of the vocabulary — it is a defect signal.**
`attribution/2` derives it when a request has no `:current_user` and no API
key, which happens on the unauthenticated pipelines: login, registration,
`POST /api/auth/token`, email verification. Every one of those is a plainly
human action, so every such call site passes an explicit `:actor` override:

```elixir
Accounts.register_user(params, Audited.attribution(conn, actor: "ui"))
Accounts.verify_email(user, Audited.attribution(conn, actor: "api"))
```

The fallback stays in `attribution/2` because a wrong actor is worse than an
unknown one — but a `"system"` row in the trail means a call site forgot to
say who it was, and should be read as a bug rather than as information.

**This settles `self` vs `system`, which previously depended on whether the
caller passed attribution at all.** They are not two spellings of "unknown".
`self` is a *claim*: the account, acting for itself, through no surface worth
naming — the correct default for a tenant-scoped context function, since the
overwhelming majority of its callers are the tenant. `system` was an *absence*:
no principal on the request. Absences are now overridden at the call site, so
the two no longer compete for the same rows.

### 3. The exclusions are decisions, not gaps

High-volume machine state is not audit material, and recording it would bury
the events that are:

- `ConversationServer`'s per-turn state-machine writes — turn started, output
  chunk, turn ended. The conversation's own log events already hold this, at
  the right granularity.
- `Accounts.touch_api_key/1` — a last-used stamp on every authenticated
  request. The key's *creation* and *revocation* are audited; its use is what
  the request log is for.
- `Conversations.mark_read/2`, theme and display preferences — reading and
  presentation are not state changes anyone reconstructs an incident from.

Two system paths record a **summary per run** rather than per row, for the same
reason: `Workers.RetentionPruner` (which deletes `audit_events`, so the trail
must account for its own shrinkage) and the trial-backfill release task.

Adding to this list is allowed; doing it silently is not. The exclusion goes in
`@deliberately_silent` in the guardrail test with a reason, and in the
`Fountain.Audit` moduledoc.

### 4. Two rows per API mutation, deliberately

An API write leaves both a semantic context event (`agent.updated`, naming the
fields that moved) and a request-log row from the `:api` pipeline plug
(`PUT /api/agents/:id` and the status code). This looks like duplication and is
kept anyway (#552): they answer different questions. The context event says
**what changed**; the plug says **what was attempted**, including for requests
that were refused. A 403 on a route whose context never ran leaves no semantic
event at all, and a run of them is the signal you actually want.

Scoping the plug down to "only routes whose context does not audit yet" was
considered and rejected: that list is a second place to remember, one forgotten
entry away from a silently unaudited route — the exact failure mode #540
existed to remove.

The plug's action is the **route pattern** (`PUT /api/agents/:id`), not the
request path. The code recorded `conn.request_path` until #979, which put the
resource id inside the action and cost two things: the trail's only groupable
column, and — because `Fountain.Analytics` mirrors `action` through as the
PostHog event name ([ADR 0025](0025-product-analytics-in-posthog.md)) — a bounded event
taxonomy. The Fountain project had grown a separate event definition per
conversation before anyone looked.

### 5. Deleting an account anonymises its trail

`audit_events.user_id` is `on_delete: :nilify_all`. Deleting an account does
not delete its audit rows; it detaches them, leaving operational history that
names nobody ([ADR 0009](0009-account-deletion-and-export.md)). One row is exempt: `account.deleted` denormalises the
email and user id into `metadata`, because the event describing a deletion is
the one that must still stand alone afterwards.

The tempting generalisation — denormalising ids into other rows so the trail
stays correlatable — is **rejected**. It would defeat the nilify on every path
and quietly undo [ADR 0009](0009-account-deletion-and-export.md)'s erasure promise. `Audit.record/1`'s
`record_unattributed` fallback follows the same line: when the account
disappears mid-write, the row is kept and attributed to nobody, rather than
kept with the id put back.

## Consequences

- A new context mutation has one correct shape, and the guardrail fails until
  it has it. A reviewer does not have to reason about which surfaces call it.
- A new actor string is now an ADR amendment rather than a judgement call at a
  call site. `self`, `ui`, `api`, `sprite`, `admin`, `admin:<id>` and
  `system:<worker>` are the whole list.
- Actor history is not uniform across time: operator-driven billing rows
  written before this ADR read `system:admin`, and rows from the
  email-verification paths read `system` where they now read `ui`/`api`.
  Anything querying by actor must tolerate both, or filter by date.
- The `/audit` page shows two rows for one API mutation. That is intended, and
  the UI should not "fix" it by deduplicating.
- `Fountain.Audit.record!/1` stays test-only: no mutation in this system is
  one where losing the audit row is worse than failing the mutation.

## Alternatives considered

- **Audit at the caller (controller/LiveView), where the actor is known** —
  what the system did before #540. Coverage then depends on which door a
  request came through, and the gap is invisible until someone goes looking.
  Rejected; it is the bug this campaign existed to remove.
- **Audit in a `Repo` hook or an Ecto callback** — catches every write, and
  can name none of them. `agent.updated` with the fields that moved is the
  value; `UPDATE agents` is not. Rejected.
- **Retire the `:api` plug's request-log row** — see §4. Rejected.
- **One actor string per surface, dropping `self`** — would mean every context
  function is unsafe to call without attribution, including from tests,
  releases and future internal callers. `self` as the default keeps the
  common case honest and makes the override the interesting thing. Rejected.
- **Keeping `system:admin` in `ee/` billing** — it is the same shape reached
  by a different route, and it makes the one human source look unattended.
  Rejected in favour of converging on `admin`.

## Addendum — 2026-10-12: two system actors retired

The account data export and outbound webhooks are removed (simplify 4/5; ADR
[0009](0009-account-deletion-and-export.md) and
[0024](0024-outbound-webhooks.md) carry the addenda). Nothing writes the
`system:account_export` or `system:webhook_delivery` actors, or the
`account.export_*` and `webhook_endpoint.*` actions, any more. Rows already
written keep them.
