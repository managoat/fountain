---
type: ADR
title: "Where auditing happens, and who the actor is"
description: "Mutations audit inside the context function with an explicit actor, into one audit_events trail that administrative actions share."
tags: [audit, security]
status: stable
adr: "0013"
adr_status: "Accepted"
date: 2026-08-07
generated: { by: human:jhgaylor, at: 2026-08-07T15:03:06-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-07T15:03:06-04:00 }
---

# 0013 — Where auditing happens, and who the actor is

**Status:** Accepted, 2026-08-07. Built; nothing described here is unbuilt.

## Context

Before #540, auditing depended on which door a mutation came through. A plug
on the `:api` pipeline recorded every API write; the browser surface recorded
whatever its LiveView remembered to; seven contexts recorded nothing at all.
Creating a secret through the UI left no trace, while the same write through
the API left one: the wrong way round for a product whose job is holding
tenant secrets (#543).

The campaign that fixed it settled a rule, an actor vocabulary and a set of
exclusions that bind the context functions and a guardrail test. They live in
`CLAUDE.md`, the `Fountain.Audit` moduledoc and `audit_guardrail_test.exs`;
this ADR is what a change that wants to audit at the caller, or to invent a
new actor string, has to argue with.

## Decision

### 1. Mutations audit inside the context function, not at the caller

A function that changes tenant-owned state records its own event. The UI, the
API, background workers, and any future surface are covered by construction
rather than by each caller remembering.

Callers supply only what a context cannot know about its caller: `:actor` and
`:request_ip`, from `FountainWeb.Audited.attribution/2` on a web surface or a
`"system:<worker>"` string from a background one.

```elixir
def create_agent(attrs, opts \\ []) do
  %Agent{} |> Agent.changeset(attrs) |> Repo.insert() |> audited("agent.created", opts)
end

Agents.create_agent(attrs, Audited.attribution(conn))   # or (socket)
Agents.create_agent(attrs, actor: "system:my_worker")   # background caller
```

Three constraints came out of building it:

- Never record inside a transaction. `Audit.record/1` is best-effort by
  rescuing, and a rescue does not undo an aborted transaction: a failed audit
  insert inside one poisons the enclosing transaction, so a lost audit row
  would take the mutation with it. This bit `Agents.upload_avatar/4`,
  `Agents.delete_avatar/2` and `Accounts.register_user/2`.
- Never record values. Update events name the fields that moved
  (`Audit.changed_fields/1`); secret, credential and prompt events record
  keys, sizes and providers. The trail is not a second copy of tenant data;
  if it were, it would be the most sensitive table in the database with the
  loosest read path.
- Only record what happened. A rejected changeset, a no-op sync, or a
  re-assertion of a status the account already had records nothing. A trail
  that logs attempts as changes cannot be read literally.

`apps/fountain/test/fountain/audit_guardrail_test.exs` enforces the rule: add a
context mutation and the guardrail fails until it audits, or until the function
is added to the documented exclusion list with a reason.

### 2. The actor vocabulary is closed

| Actor | Meaning |
|---|---|
| `self` | the account acted on its own behalf; the context default when no caller says otherwise |
| `ui` | a browser session |
| `api` | a bearer token |
| `sprite` | a per-conversation callback token: an agent acting as the tenant |
| `admin` | an operator acting on another account, on the tenant-facing row |
| `admin:<operator_id>` | the operator, on the administrative row itself (§6) |
| `system:<worker>` | an unattended path, named after the worker or path that writes it |

`sprite` is separate from `api` deliberately: "the agent did this" and "the
account owner did this" are materially different claims, and the scopes added
for the sandbox privilege-escalation fix make them distinguishable.

`system:<worker>` names are snake_case and name the module or path doing the
work. The ones written today are `conversation_server`, `sandbox_reaper`,
`retention_pruner`, `release_task`, `launch`, `wake`, `reattach`,
`provision_watchdog`, `autonomous_turn_reaper`, `chatgpt_refresh`,
`connection_refresh` ([0085](0085-mcp-connections.md)) and
`first_user_admin` (the bootstrap grant of
[0011](0011-self-host-first-admin-bootstrap.md)). A new `system:` actor is
added to this list in the PR that introduces it. Rows already written keep
whatever actor they carry, including retired ones.

Two rules keep the list from fraying:

- `admin` beats `system:` when a human operator is behind the action. The
  `system:` prefix asserts "unattended"; billing code once wrote
  `system:admin` for operator-driven actions, and old rows may still read it.
- Bare `"system"` is not a member of the vocabulary; it is a defect signal.
  `attribution/2` derives it when a request has no `:current_user` and no API
  key, which happens on the unauthenticated pipelines: login, registration,
  `POST /api/auth/token`, email verification. Each of those is a human action,
  so each call site passes an explicit `:actor` override:

  ```elixir
  Accounts.register_user(params, Audited.attribution(conn, actor: "ui"))
  Accounts.verify_email(user, Audited.attribution(conn, actor: "api"))
  ```

  The fallback stays because a wrong actor is worse than an unknown one, but a
  `"system"` row means a call site forgot to say who it was.

This settles `self` against `system`. `self` is a claim: the account, acting
for itself, through no surface worth naming, which is the right default for a
tenant-scoped context function. `system` was an absence: no principal on the
request. Absences are overridden at the call site, so the two no longer
compete for the same rows.

### 3. The exclusions are decisions, not gaps

High-volume machine state is not audit material, and recording it would bury
the events that are:

- `ConversationServer`'s per-turn state-machine writes. The conversation's
  log events already hold these, at the right granularity.
- `Accounts.touch_api_key/1`, a last-used stamp on every authenticated
  request. The key's creation and revocation are audited.
- `Conversations.mark_read/2`, theme and display preferences: reading and
  presentation are not state anyone reconstructs an incident from.

`Workers.RetentionPruner` records a summary per run rather than per row; it
deletes `audit_events`, so the trail must account for its own shrinkage.

Adding to this list is allowed; doing it silently is not. The exclusion goes in
`@deliberately_silent` in the guardrail test with a reason, and in the
`Fountain.Audit` moduledoc.

### 4. Two rows per API mutation, deliberately

An API write leaves both a semantic context event (`agent.updated`, naming the
fields that moved) and a request-log row from the `:api` pipeline plug
(`PUT /api/agents/:id` and the status code). They answer different questions
(#552): the context event says what changed; the plug says what was attempted,
including requests that were refused. A 403 on a route whose context never ran
leaves no semantic event, and a run of them is the signal you want.

Scoping the plug to "only routes whose context does not audit yet" was
rejected: that list is a second place to remember, one forgotten entry away
from a silently unaudited route.

The plug's action is the route pattern (`PUT /api/agents/:id`), not the request
path (#979). A request path puts the resource id inside the action and costs
the trail its only groupable column.

### 5. Deleting an account anonymises its trail

`audit_events.user_id` is `on_delete: :nilify_all`. Deleting an account
detaches its audit rows rather than deleting them, leaving operational history
that names nobody ([0009](0009-account-deletion-and-export.md)). One row is
exempt: `account.deleted` denormalises the email and user id into `metadata`,
because the event describing a deletion must still stand alone afterwards.

Denormalising ids into other rows so the trail stays correlatable is rejected:
it would defeat the nilify on every path and undo
[0009](0009-account-deletion-and-export.md)'s erasure promise.
`Audit.record/1`'s `record_unattributed` fallback follows the same line: when
the account disappears mid-write, the row is kept and attributed to nobody.

### 6. One trail, administrative actions included

Administrative actions are rows in `audit_events`, written by
`Fountain.Audit.record_admin/1` against a closed allowlist
(`Fountain.Audit.admin_actions/0`). A rejected action fails loudly: an error
log and `[:fountain, :audit, :admin_record_rejected]`. The row has the action
as `action`, `user_id` null, the admin as `actor` (`admin:<id>`, or
`system:first_user_admin` for the bootstrap), and the target as the resource:
`user` / `<account id>`, or `sandbox` / `<sandbox id>` for a reap. The target
has no foreign key, so it outlives the account. `user_id` null keeps the row
out of the target's own trail, which already holds the tenant-facing event
(`account.role_changed`, `account.deleted`, actor `admin`), and in the admin's
cross-tenant `/audit` and `GET /api/admin/audit`.
`GET /api/admin/users/{id}` lists an account's `admin_events` from these rows.

`admin.*` rows are never pruned: `Workers.RetentionPruner` skips them, the
unbounded retention #452 chose for the privilege trail.
`Accounts.admin_bootstrapped?/0` reads `admin.role.granted` from
`audit_events`, so it stays true after the last admin is deleted, as
[0011](0011-self-host-first-admin-bootstrap.md) needs.

## Consequences

- A new context mutation has one correct shape, and the guardrail fails until
  it has it. A reviewer does not have to reason about which surfaces call it.
- A new actor string is an amendment to this ADR rather than a judgement call
  at a call site.
- Actor history is not uniform across time: old operator-driven rows read
  `system:admin`, and old email-verification rows read `system` where they now
  read `ui`/`api`. Anything querying by actor must tolerate both, or filter by
  date.
- The `/audit` page shows two rows for one API mutation. That is intended, and
  the UI should not deduplicate it.
- `Fountain.Audit.record!/1` stays test-only: no mutation here is one where
  losing the audit row is worse than failing the mutation.

## Alternatives considered

- Audit at the caller (controller/LiveView), where the actor is known: what
  the system did before #540. Coverage then depends on which door a request
  came through, and the gap is invisible until someone looks.
- Audit in a `Repo` hook or an Ecto callback: catches every write and can name
  none of them. `agent.updated` with the fields that moved is the value;
  `UPDATE agents` is not.
- Retire the `:api` plug's request-log row: see §4.
- One actor string per surface, dropping `self`: every context function
  would be unsafe to call without attribution, including from tests, releases
  and internal callers.
- A separate `admin_audit_events` table: what existed until 2026-10-15. An
  admin acting on another account has two people to name, but two trails meant
  two readers, two retention rules, and an admin page and endpoint that served
  only the second one, while the cross-tenant `/audit` showed everything except
  what admins did. Neither the page nor the endpoint was requested in the 30
  days before it was folded in.

## History

- 2026-08-07 — Accepted, documenting the #540 campaign: audit in the context, closed actor vocabulary, exclusions, two rows per API write, anonymised trail on deletion.
- After 2026-08-07 — `system:webhook_delivery` ([0024](0024-outbound-webhooks.md)) and `system:onboarding` ([0038](0038-onboarding-first-reply.md), #1389) added; operator billing sources moved from `system:admin` to `admin`.
- 2026-10-12 — Account data export and outbound webhooks removed; `system:account_export`, `system:webhook_delivery` and their actions no longer written.
- 2026-10-14 — The `system:` list brought back in line with the code: undocumented actors recorded; `unverified_pruner` (#2633), `verify_lifecycle` (#1116, [0031](0031-credits-are-the-product.md)) and the billing sources (#2609) retired.
- 2026-10-15 — One audit trail: administrative actions move into `audit_events` with actor `admin:<id>` and are never pruned; `admin_audit_events`, `/admin/activity`, `/admin/conversations/:id` and `GET /api/admin/events` removed; the table is dropped one release later (`20261016171732_drop_admin_audit_events`).
- 2026-10-15 — `system:onboarding` retired with the starter agent. The `system:` list rechecked against the code: `team_scheduler`, `home_reset`, `provisioning` and `detached_request_sweeper` are no longer written.
- 2026-10-17 — `system:connection_refresh`, written since ADR 0085, added to the list of `system:` actors.
