---
type: ADR
title: "A user links several ChatGPT subscriptions, and a credential set names one"
description: "All five stages are built except stage 5's controlled run with two real subscriptions, and the ADR is still Proposed: accepting it is the maintainer's decision (the table, the owner-scoped context and the per-owner source lock; a credential set naming a grant and resolution to it with no fallback; the transport and custody: a CODEX_HOME per grant and generation, broker sessions that carry which grant they may use, and a per-request check against the durable generation; then durable link attempts, /api/account/chatgpt-subscriptions, and the ChatGPT subscriptions card and the set picker in the console; then exhaustion recorded for a user's grant when OpenAI confirms it with nothing substituted, which grant served a turn, a daily keepalive with one job per grant, and grants in the account export and deletion). Linking is behind a flag that is off everywhere, and a rollout checklist says what is owed before it is on for anyone. Rebuilds ADR 0052's user surface with many grants per user instead of one: the grant table loses its one-row-per-user index for a named row, an inference credential set names a grant, and an agent selects a subscription the same way it selects an API key. No automatic failover between a user's subscriptions and no platform fallback when the named one is exhausted."
tags: [inference, codex, oauth, security, billing]
status: draft
adr: "0060"
adr_status: "Proposed"
date: 2026-09-20
---

# 0060 — A user links several ChatGPT subscriptions, and a credential set names one

**Status:** Proposed, 2026-09-20. **All five stages below are built, stages
4 and 5 in two halves each, except the second sentence of stage 5: the
controlled run with two real subscriptions has not been made. Linking is
off for every account.** The status stays Proposed: accepting this ADR is
the maintainer's decision, and the run and the rollout checklist
(`contributing/chatgpt-subscriptions-rollout.md`) come first.
Stage 1 is the table change, the owner-scoped context in
`Fountain.ChatGPTAccounts` and the per-owner source lock. Stage 2 is
selection: `inference_credentials.chatgpt_grant_id`,
`InferenceCredentials.set_grant/3`, and a resolver that turns a set naming
a grant into a `:grant` source for a codex run or into an error naming the
grant, with no fallback. Stage 3 is transport and custody: a conversation
that resolved to a grant now runs on it, with a `CODEX_HOME` of its own per
grant and generation, a broker session that records which grant it may use
and never holds its bearer, a check against the grant row on every request,
and a renewal by grant id and generation before every turn. Stage 4a is the
link-attempt lifecycle, its job, `/api/account/chatgpt-subscriptions`,
`chatgpt_grant_id` on the credential-set API and `CHATGPT_GRANT_CEILING`.
Stage 4b is the console: the **ChatGPT subscriptions** card and a set's
picker on `/account/inference-credentials`, and the `/start` banner and the
agent form saying when a named grant cannot serve.
A new link is behind the `chatgpt_subscriptions` flag, which fails closed:
it is off wherever nobody has turned it on, a deployment with no PostHog
included, and nobody has. Stage 5a records a user's grant as exhausted when
OpenAI confirms it, with nothing substituted, and says which grant served a
turn. Stage 5b is the daily keepalive, one job per grant, and grants in the
account export and deletion. Resolution does run in production, for every
conversation, and for a set that names no grant it resolves exactly what it
did. **The deployment's own grant (0047) is not on the new path**: it still
travels as a substitution rule and writes the shared `~/.codex/auth.json`,
exactly as before stage 3; moving it is a separate change (see
[Stage 3 as built](#stage-3-as-built)), and it, the two measurements and
the two broker gates named there are owed **before the flag is turned on
for anyone**. What stage 1 left running is
`ChatGPTAccounts.RefreshSupervisor`, a task supervisor and the refresh
coordinator, which start idle on every node; since stage 5b they serve the
keepalive's jobs as well as a turn's renewal. The Context section describes
`main` at `9122474f`, before stage 1.

What each stage built, and where it settled something this ADR left open or
had wrong, is recorded under [Stage 1 as built](#stage-1-as-built),
[Stage 2 as built](#stage-2-as-built),
[Stage 3 as built](#stage-3-as-built),
[Stage 4a as built](#stage-4a-as-built),
[Stage 4b as built](#stage-4b-as-built) and
[Stage 5 as built](#stage-5-as-built).

Rebuilds the user-facing half of
[0052](0052-user-owned-chatgpt-grants.md) — its decisions 2, 4 and 5, which
were never built — and **replaces 0052's one-linked-account-per-user model
with many**. Completes [0053](0053-inference-credential-sets.md) decision 3,
which reserved this: "a set may name a grant only once 0052 decision 4
lands." Inherits 0052's decision 1 (ownership and encryption) with one
change, the grant id added to a user grant's AAD
([as built](#stage-1-as-built), item 3), and, unchanged, its decisions 3
(one refresh owner per grant) and 6 (managed grant destinations cannot be
overridden by tenant bindings), and 0047's platform grant.

Amends [0047](0047-codex-platform-chatgpt-account.md) decision 6 as amended
by #2362: a **user** grant whose Codex usage is spent does not fall back to
the platform API key. Amends 0052 decision 4, whose selection table assumes
one link per user and a user-level preference.

## Context

The deployment's own ChatGPT account has served codex runs since 2026-09-08
(0047): one row with a NULL `user_id`, refreshed by the server, carried to
`chatgpt.com` by the broker, and seen by the sandbox only as the placeholder
`__codex_chatgpt_access_token__`. Users cannot link their own. The two things
standing between them and it are that the user surface of 0052 was never
built, and that the table admits one grant per user.

What the codebase has today, verified against `main` at `9122474f`:

- `platform_chatgpt_account`
  (`apps/fountain/priv/repo/migrations/20260908150000_create_platform_chatgpt_account.exs`)
  already carries `user_id` with a deletion cascade, and its own comment
  names this ADR's direction: "the column exists so a per-tenant 'connect
  your ChatGPT' later is the same row with an owner, not a second table."
  Two partial unique indexes sit on it: `[:user_id] where user_id IS NOT
  NULL`, which is exactly the one-per-user rule this ADR removes, and
  `platform_chatgpt_account_platform_row`, which keeps the platform row
  singular and is **not** changed here.
- The row already has the fencing columns 0052 decision 1 asked for:
  `generation` (`Ecto.UUID`, autogenerated) and `lock_version`
  (`apps/fountain/lib/fountain/platform_chatgpt/account.ex:52-53`), added by
  `20260912020000_version_chatgpt_grants.exs`, plus the `usage_exhausted_at`
  / `usage_exhausted_until` / `usage_checked_at` trio from #2362.
- `Fountain.ChatGPTAccounts` is owner-scoped in shape but platform-only in
  fact: every function is `platform_*` and queries `where: is_nil(a.user_id)`
  (`apps/fountain/lib/fountain/chatgpt_accounts.ex:16-19`). The
  `ChatGPTAccounts.Cipher` dispatch on owner, `RefreshLock`, and `Reserved`
  all survive and all serve the platform row.
- The dormant tenant-owner half — the `*_for_user` functions, the grant
  struct, the user refresh coordinator, its supervisor, the two keepalive
  workers and `ProtectedCompiler` — was deleted under #2188 (#2176 decision
  1) because nothing in production inserted or read it. 0052 records
  `105fb6d1` as the last commit of `main` that carried it, and that code
  splits cleanly in two for this ADR's purposes. Its **lifecycle half is
  already per grant** and survives a straight revert:
  `credential_for_user/4` and `refresh_for_user/3` take a `grant_id`
  alongside the `user_id` and `generation`
  (`chatgpt_accounts.ex:133,150` at `105fb6d1`). Its **lookup half assumes
  one**: `status_for_user/1` selects `where: a.user_id == ^user_id` with no
  grant id and ends in `Repo.one()` (`chatgpt_accounts.ex:97-119`), which
  raises `Ecto.MultipleResultsError` the moment a user holds two. Nothing
  deleted ever *chose* a grant: at `105fb6d1` there were no production
  callers of any `*_for_user` function, because 0052's selection half was
  never built. The revert is a starting point for decisions 3 and 6; the
  lookup entry point and all of selection are new work.
- The revert is mostly mechanical. #2188's deletions were `73fe870d`
  (#2198, the workers, sweep, coordinator and supervisor) and `4563e3df`
  (#2199, the reads, the typed `Grant` and `ProtectedCompiler`), together
  about 715 lib and 1,447 test lines, and **no column or index was
  dropped**. #2362 (`231773be`) did not rewrite `do_refresh`,
  `current_result`, `current_query` or `swap_in`: `git diff 4563e3df
  9122474f` over `chatgpt_accounts.ex` touches the moduledoc, the new
  exhaustion block, one `platform_status` field and the `exhausted_until/2`
  helper, and none of those four functions. Restoring their owner branches
  is #2199's hunks reversed. What
  needs care is the other direction: #2362's additions are scoped to the
  NULL-owner row and stay that way (decision 4 treats a user grant's
  exhaustion differently, in stage 5). The whole-file deletions and the
  `application.ex` wiring revert mechanically, and `Cipher` and
  `RefreshLock` are unchanged since `105fb6d1`.
- At `105fb6d1` there was **no application writer** for a user grant: test
  rows were inserted through the schema, and the fixture said "application
  linking remains unbuilt". So the reads and the refresh path are a
  rebuild; connect, reconnect, rename, disconnect and the cap are new.
- `Source` (0053 decision 2) already anticipates this work: "Add `set_id`
  with named sets, and owner scope, `grant_id`, `generation` and matching
  provider-account metadata with managed grants."
  `20260913120000_bind_inference_sources.exs` persists the binding.
- A credential set (`inference_credentials`) holds four typed ciphertext
  columns — `anthropic_api_key`, `claude_code_oauth_token`,
  `openai_api_key`, `gemini_api_key`
  (`apps/fountain/lib/fountain/inference_credentials/credential.ex:32`) —
  and has no way to name a subscription.

Why more than one subscription per user, when 0052 called one "deliberate"
scope: 0052 made that call about a rotating grant where switching accounts
is reconnect, and it made it before sets existed. Sets changed the shape of
the question. A user with a personal ChatGPT plan and a work one is holding
two different bills and two different quotas, and the thing that picks
between them — an agent naming a set — was built in the meantime. One link
per user forces reconnect as the switching mechanism, which means losing one
grant's lifecycle to use the other, per agent, per run.

The subscription is not an API key and the difference drives the whole
design: the refresh token rotates on every use, so custody has to stay on
the server (0052), and the ChatGPT backend serves a different model list
from the API (0047's Measured, finding 1), so a subscription is not a
drop-in for an `openai_api_key`.

**An open dependency:** 0047's measurement 5, the idle lifetime, was due
2026-09-17 and still reads Pending. It sets the keepalive interval, and this
ADR multiplies the number of grants that interval applies to. Decision 5
below does not assume a value for it.

## Decision

Let a user link **several** ChatGPT subscriptions, each a named grant with
its own lifecycle, and let an inference credential set name one. An agent
then selects a subscription with the field it already uses to select an API
key. The server keeps custody and rotation exactly as 0052 decided; what
changes is how many grants a user may hold and how a run names one.

### 1. A grant is a named row; a user may hold several

Drop `unique_index(:platform_chatgpt_account, [:user_id], where: "user_id IS
NOT NULL")`. Add a `name`, non-null for a user grant, and
`unique_index([:user_id, :name], where: "user_id IS NOT NULL")` in its
place. Leave `platform_chatgpt_account_platform_row` alone: the deployment
still has exactly one grant of its own, and the platform row keeps its NULL
name.

Add a second partial unique index on `[:user_id, :account_id]` so a user
cannot link the **same** ChatGPT account twice under two names. Two rows for
one upstream account would give one subscription two independent refresh
chains, two generations and two sets of broker rules over a single quota —
distinct rows that OpenAI cannot tell apart. Reconnecting an existing
account is a reconnect of that grant, not a second link.

Keep the table and its historical name, as 0052 decision 1 already decided.
Renaming it is a migration that buys nothing; the create migration's comment
already documents the intent.

Bound the count per account with a configurable cap, refused at the door
with an actionable error rather than silently. The cap exists to stop a
runaway client, not to price the feature.

A grant is owned by exactly one user and is never shared, inherited by an
owned principal, or pooled for platform fallback. 0052's consequence stands
with the count changed: **several** user grants serve only that tenant.
[0053](0053-inference-credential-sets.md) decision 7 still applies — a
business with many customers gets principals, not a pile of grants.

### 2. A credential set names a grant

Add a nullable `chatgpt_grant_id` to `inference_credentials`, referencing a
grant owned by the same user. A set names at most one grant; a grant may be
named by several sets. This is the whole of the new selection surface:
`agents.inference_credential_id`, `conversations.inference_credential_id`
and `agents.allowed_inference_credential_ids` already exist (0053 decision
3) and need no change to carry a subscription.

This **replaces 0052 decision 4's user-level preference**. There is no
account-wide "prefer my subscription" flag, because with several
subscriptions there is no single thing for it to prefer. A set that names a
grant resolves to that grant; a set that does not resolves as it does today.
The user's default set is what an unset agent gets, which is the existing
rule and needs no subscription-specific version.

A set may name a grant **and** hold an `openai_api_key`. They are not in
competition: the grant serves Codex on a brokered backend, the key serves
every other OpenAI consumer (0052 decision 4's eligibility rule, unchanged —
OpenCode, image generation and direct API callers still require a key). A
set with a grant and no key is eligible for Codex and `:missing` for the
rest, and says so at selection rather than at the turn.

Cross-owner naming is refused at the changeset and again at resolution:
a set may name only a grant its owner holds.

### 3. Linking, naming and disconnecting are per grant

Rebuild 0052 decision 2's device-code flow, with every operation addressing
one grant by id rather than the user's single link:

- The **ChatGPT subscriptions** card on `/account/inference-credentials`
  lists the user's grants and links another, up to the cap. Connect, plan
  and account display, Connecting, Connected, Reconnect required, Rename
  and Disconnect, each scoped to one grant.
- The same operations under the full-scope `/api/account` boundary, as a
  collection: list, create/read/cancel an attempt, rename, disconnect. No
  public "get access token" or refresh endpoint, and a sandbox's
  conversation-scoped token still cannot start or change a link.
- A name is supplied at connect time and is what a set names in the console.
  Renaming does not touch `generation` — it is not a credential change.
- Reconnect targets one grant and keeps the old one usable until the new
  exchange commits (0052 decision 2). Reconnecting a grant that a set names
  keeps that set pointed at the same row, and advances `generation` as 0052
  decision 5 requires.

0052 decision 2's attempt rules carry over per grant: short-lived,
owner-bound, single-use, opaque id, encrypted exchange secrets, jobs carry
ids and never tokens, completion rechecks eligibility and generation. The
per-user pending-attempt limit now bounds attempts across all of a user's
grants, not one link.

Device code stays the only user-facing flow in the first version. Auth-file
import and static workspace tokens remain admin capabilities.

### 4. A named grant is used or the run fails; nothing switches for you

When a set names a grant, that grant serves the run. If it is revoked,
expired, unavailable, or its Codex usage is spent, the turn fails with an
actionable error naming the grant and the reset time OpenAI gave. Fountain
does not try the user's other subscriptions, does not fall back to the set's
own `openai_api_key`, and does not fall back to platform inference.

This keeps 0052 decision 4's rule under a model that makes breaking it
tempting. A silent switch moves a run onto different quota, and — for the
platform fallback — onto a different bill. The user linked several
subscriptions and named one; naming another is a configuration change they
make, not an inference the server draws.

**This amends 0047 decision 6 as amended by #2362.** That amendment skips an
exhausted grant in favour of the platform API key, which is correct for the
platform grant, where the deployment pays either way. For a user grant it
would convert the user's own exhausted subscription into platform-billed
inference without asking. Exhaustion of a user grant is recorded the same
way — only when OpenAI confirms it, with the failing turn not retried — and
is then surfaced, not routed around.

An exhausted or revoked grant is reported on the subscriptions card and
through the account API as grant state, so the user can repoint a set
before the next run rather than discovering it mid-turn.

### 5. Refresh and keepalive scale to many grants per user

0052 decision 3 is inherited whole: request coalescing by grant id, a
per-grant PostgreSQL advisory lock tried without waiting, writes fenced by
grant id, generation, `lock_version` and active state, and refresh both
before expiry and before a turn.

**One lock has to change, and it is not the one 0052 names.**
`ChatGPTAccounts.RefreshLock` is already per grant — it keys on
`:erlang.phash2(grant_id)` under namespace `52_001`
(`chatgpt_accounts/refresh_lock.ex:42`) — so the refresh path itself
survives. But every grant *write* also takes
`InferenceCredentials.lock_platform_source/0`, a single deployment-wide
advisory key `hashtextextended('inference:platform', 0)`
(`inference_credentials.ex:612` at `9122474f`), from `store/3`,
`platform_disconnect/1`, `swap_in/3`, `mark_revoked/2`, `mark_expired/1`
and `write_exhaustion/4`. Worse, `lock_source/1` (`:604` there) takes that
same key **shared** before every `resolve/4`. With one platform grant that
is a non-event. With many user grants it serializes every grant's refresh
against every user's credential resolution, deployment-wide.

Key that lock by owner — the platform row keeps `'inference:platform'`, a
user grant takes a per-user or per-grant key — so one user's reconnect
cannot block another user's turn admission. This is new work that 0052 did
not anticipate, because at one grant per deployment the contention did not
exist.

**The lock is also taken by a database trigger, which this decision
originally missed.** `fountain_lock_inference_source()`
(`20260913120000_bind_inference_sources.exs`) runs before every INSERT,
UPDATE and DELETE on `platform_chatgpt_account` and took
`'inference:platform'` exclusive for every row whatever its `user_id`.
Re-keying only the Elixir call sites would have changed nothing: the first
write to a user's row would still have taken the platform key. The re-key
is therefore a migration that replaces the function as well. And the key is
per user, not per grant, because one already exists: `lock_source/1` takes
the platform key shared and then `'inference:' || user_id` exclusive, and
the same trigger takes that per-user key for the user's credential sets,
environments and vaults. Resolution has to lock before it reads the set, so
it cannot know a grant id yet; a user's grant row joins the things that
per-user key already serializes.

The rest is volume. Keepalive today is one cron entry refreshing one row
(`workers/platform_chatgpt_keepalive.ex:23`, `config/config.exs:100`); it
becomes a fan-out over active refreshable grants in bounded batches with
jitter, one job per grant, sized for the grant count rather than the user
count. Bound refresh-worker concurrency and HTTP timeouts so lock holders
cannot exhaust the DB pool — 0052 decision 3's constraint, now load-bearing,
because a single user can multiply the work.

Keep the interval provisional until 0047's measurement 5 is recorded, and
size the fan-out from the measured lifetime rather than from the 10-day
access-token figure alone.

### 6. Sandbox identity, custody and billing follow the named grant

0052 decisions 5, 6 and 7 are inherited with "the selected grant" reading
"the grant the set named":

- The selected grant builds Codex's placeholder `auth.json`; peers with
  different grants or generations get separate `CODEX_HOME` auth locations,
  so two of one user's subscriptions in one shared sandbox cannot overwrite
  each other's account file. 0052 decision 5 required this for a user grant
  against a platform one; several grants per user makes the collision
  reachable within a single account. Three specific things stand in the way
  and are work, not inheritance: `CodexChatGPT.auth_path/0`
  (`conversations/codex_chatgpt.ex:118`) is a fixed `$CODEX_HOME/auth.json`;
  `CodexChatGPT.prepare_sandbox/3` (`:80,89`) reaches for the global
  `ChatGPTAccounts.platform_sandbox_auth/0` and is passed no user,
  conversation or `Source` by its caller (`conversations/provisioning.ex:994`),
  which is exactly the lookup 0052 decision 5 said to eliminate; and the
  broker derives a credential's placeholder from the env-var name alone
  (`broker.ex:250`), so **two grants produce the identical
  `__codex_chatgpt_access_token__`** and `Broker.@inference`
  (`broker.ex:295-309`) holds one entry per name per conversation. Carrying
  two grants into one sandbox needs the placeholder and the broker entry to
  be per grant, not per key name.

  **Two things in that paragraph were wrong about the code, and stage 3
  found both.** The placeholder and the `@inference` entry do not collide
  across two grants in one sandbox: a broker session is per *conversation*,
  not per sandbox, and a conversation is pinned to one source, so two grants
  in one sandbox are two sessions. They are made per grant anyway, because it
  is cheap and makes a file read out of place attributable, but they were
  never a blocker. And the list missed the thing that really refused the
  acceptance test: `Machines.Binding.bind_inference/2` binds a codex machine
  to one inference source for its life and answers
  `:codex_inference_conflict` to a peer on another. See
  [Stage 3 as built](#stage-3-as-built), items 1 and 2.
- Identify the grant by id and generation, never by its token. `Egress`
  currently recognises the credential to refresh by comparing token strings
  (`conversations/egress.ex:136`), which 0052 decision 4 forbids outright
  and which cannot distinguish two grants at all.
- Owner scope, grant id and generation persist as broker authorization data
  on each managed rule; disconnect and replacement fence and invalidate in
  the same transaction; the broker authorizes every credential-bearing
  request inside an open tunnel against the durable active generation.
- Managed grant values stay in the protected typed input, never in the
  ordinary `brokered` map. `Reserved`
  (`apps/fountain/lib/fountain/chatgpt_accounts/reserved.ex`) already
  refuses configuration that names `CODEX_CHATGPT_ACCESS_TOKEN` or its
  placeholder, for every grant, and keeps doing so.
- A user grant produces `inference_origin: :own`: no platform inference
  debit and no platform daily-ceiling consumption. This is not automatic —
  `Source.platform?/1` (`inference_credentials/source.ex:38`) is the only
  origin signal today, and it is what charges the deployment ceiling at
  `conversations/turn_machine.ex:1099` and `platform_inference.ex:441`. A
  user grant that resolved as `:platform`, as the platform grant does now,
  would burn the deployment's ceiling on the user's own subscription. The
  usage stamp records **which** grant served the turn, not merely that a
  user grant did, so reconnect, restart or a repointed set cannot relabel
  usage.

Audit events — connected, renamed, reconnect-required, disconnected — are
tenant events with an explicit actor and carry the grant id and name, never
tokens or raw provider responses.

## Implementation sequence and acceptance

Each stage is its own PR; 0052's adversarial cases are required for the
platform grant and for **two grants of one user**, which is the new case.

1. **The table and the context. Built; see
   [Stage 1 as built](#stage-1-as-built).** Index swap, `name`, the cap,
   the owner-scoped reads rebuilt from `105fb6d1` for many grants with
   `status_for_user/1` replaced by a list, and the owner-scoped writes,
   which are new. Re-key the `'inference:platform'` advisory lock by owner
   (decision 5), in the trigger as well as in Elixir, before anything can
   contend on it. No user surface yet. Tests: two grants for one user, a
   third refused at the cap, name uniqueness per user, the same upstream
   account refused a second link, cross-user read refused, wrong-DEK
   failure, one user's write not blocking another user's resolve, and the
   platform row unaffected by every one of them.
2. **Selection. Built; see [Stage 2 as built](#stage-2-as-built).**
   `chatgpt_grant_id` on the set, resolution through `Source` with
   `grant_id` and `generation`, cross-owner naming refused. Tests: an agent
   on set A and an agent on set B of one user resolve to different grants
   in one account; a set naming a disconnected grant resolves to an
   actionable error with no fallback. (This read "resolves `:missing` with
   an actionable error", which is two different results in the resolver;
   item 1 under stage 2 says which it is.)
3. **Transport and custody. Built; see
   [Stage 3 as built](#stage-3-as-built).** Separate `CODEX_HOME` per
   grant/generation,
   broker rules from the named grant, per-request generation checks, the
   protected rule builder. Tests: two of one user's subscriptions in one
   shared sandbox, concurrently; refresh between prompts on one while the
   other is idle; disconnect one and prove the other is untouched.
4. **The account surface. Built, in two halves; see
   [Stage 4a as built](#stage-4a-as-built) for the API and
   [Stage 4b as built](#stage-4b-as-built) for the console.**
   Attempts, list, rename, reconnect, disconnect, on both the console and
   the API, with OpenAPI and SDK contracts. Tests: ownership and full-scope
   authorization, cancellation, expiry, replay, late completion against a
   newer grant, redaction, page reload. (Page reload is the console's test;
   what it rests on, that an attempt is a row any reader can pick up, is
   4a's.)
5. **Accounting and rollout. Built, in two halves, except the controlled
   run in its second sentence; see
   [Stage 5 as built](#stage-5-as-built).** `:own` origin per grant, the
   exhaustion path of decision 4 with no fallback, deletion and export,
   keepalive fan-out at the grant count. Then a real link of two subscriptions, a Codex turn
   on each, a forced refresh between turns, restart, and disconnect, in a
   controlled environment, with pinned versions recorded.

The console surface stays gated until stages 1 to 3 pass. Disabling new
linking must not orphan existing grants: list, status, refresh, reconnect
and disconnect stay operable.

## Stage 1 as built

Built on 2026-09-20, with no caller in production.

**The table.** `20260920235854_name_chatgpt_grants`: `name`; the check
`chatgpt_grant_name_follows_owner` (an owned row has a non-blank name, the
platform row has none); the one-per-user index replaced by
`platform_chatgpt_account_user_id_name_index` and
`platform_chatgpt_account_user_id_account_id_index`; and
`platform_chatgpt_account_id_user_id_index`, there for stage 2's composite
reference to a grant together with its owner.
`platform_chatgpt_account_platform_row` is untouched. `down` refuses,
rather than deletes, when a user holds two grants.

**The context.** In `Fountain.ChatGPTAccounts`, every function scoped by
the owner and, where it addresses one grant, by the grant id:
`list_for_user/1` and `get_for_user/2` (metadata only; they replace
`status_for_user/1`), `connect_for_user/4`, `reconnect_for_user/4`,
`rename_for_user/4`, `disconnect_for_user/3`, `remove_for_user/3`, and the
restored `credential_for_user/4`, `refresh_for_user/3`, the typed `Grant`,
`RefreshCoordinator` and `RefreshSupervisor`. The cap is `config :fountain,
:chatgpt_grant_ceiling` (5), refused as `{:grant_limit_reached, %{count:,
limit:}}` under the owner's source lock so a count and an insert cannot
interleave. There is no environment variable for it until stage 4 makes
linking reachable. Not restored, and still gone: the two keepalive workers,
the sweep, their queue and cron entry (stage 5), and `ProtectedCompiler`
(stage 3).

**The lock.** `20260921000305_key_chatgpt_grant_source_lock_by_owner`
replaces the trigger function as decision 5 now describes, and
`InferenceCredentials.lock_tenant_source/1` is the Elixir half. A write to a
user's grant takes that user's key and never the platform's, not even
shared: PostgreSQL queues a new shared request behind a waiting exclusive
one, so a shared platform lock would have let an admin key write or an
account deletion stall every user's token refresh. `resolve/4` is
unchanged. The order everywhere is platform key, tenant key, row lock, and
the refresh try-lock is never waited on. A user's row never sets
`updated_by_user_id`, which keeps one account's deletion from writing
another account's grant row under that account's key.

Two rules follow for later stages, and both are in the `ChatGPTAccounts`
moduledoc. Never renew a grant while holding `lock_source/1` for its owner;
inside the lock, read with `refresh: false`. And any new writer of an owned
grant row takes the owner's key in Elixir before it locks the row: the
trigger alone takes the row first and the key second, the reverse of the
context's order, and the two can deadlock on one row.

**What a caller can rely on.** `reconnect_for_user/4` takes
`:expected_generation` and answers `:stale_grant` to a sign-in that
finishes after a newer one (decision 3's "completion rechecks ...
generation"); it is compared under the row lock. A rename asks what a link
asks of the owner, so a suspended, unverified or principal account gets
`:ineligible_owner`; listing, reading, disconnecting and removing stay open
to it. A grant or owner id that is not a UUID is refused like one that names
nothing, never raised, and the coordinator's job and the refresh lock are
keyed by the loaded row's ids, so another spelling of an id is not another
exchange. The row's ciphertexts, stored claims and account email are
`redact: true` and do not print from a struct or a changeset.

One risk is recorded rather than removed. A user grant's fenced token write
runs in a transaction nested in the refresh lock's. If that transaction
answers `{:error, _}` after OpenAI has rotated the refresh token, the
rotated token is lost and the grant will need a reconnect; the context logs
it by grant and owner id and returns `:refresh_unavailable` instead of
crashing on the match. The platform grant has the same window and its
behaviour there is unchanged.

Four things stage 1 settled that this ADR left open:

1. **Disconnect is a tombstone, not a delete.** Decision 3 says
   "Disconnect" without saying what happens to the row. A user's
   disconnected grant keeps its id, name and upstream account and drops both
   tokens and the stored claims; `generation` and `lock_version` advance, so
   a refresh in flight writes nothing and every pin goes stale; `status` is
   `"disconnected"`, and `chatgpt_grant_tokens_follow_status`
   (`20260921001220`) holds "a tombstone has no token, every other row has
   one" in the database. The reason is decision 4. A set that names a
   disconnected grant has to fail by name, with no fallback; if the row were
   deleted the reference would be nilified or dangling, and a nilified
   reference is exactly the silent switch decision 4 forbids. It is also
   what 0052 decision 5 meant by "disconnect commits the inactive state and
   generation fence": a state change. The same subscription comes back by
   reconnecting the tombstone, which the per-owner account index enforces. A
   tombstone holds its slot under the cap until `remove_for_user/3` deletes
   it, and removal is refused for a grant that still holds a credential.
   The platform grant is unchanged: its disconnect deletes the row.
2. **A reconnect may land on a different upstream account**, as it may for
   the platform grant. It is refused only when another of the user's grants
   holds that account. Usage exhaustion recorded for the old account is
   cleared. Between reconnects the account is pinned: a refresh whose
   `id_token` names another account or provider user is refused as
   `:account_mismatch` and writes nothing.
3. **A user grant's ciphertext is bound to the grant, not only to its
   owner.** This deliberately strengthens what is inherited from 0052
   decision 1, whose AAD named the owner and the token field. With one grant
   per user that was enough; with several, one DEK covers several rows, and
   one subscription's ciphertext would have decrypted in another's row of
   the same user. The AAD is now
   `fountain.chatgpt_grant:<user_id>:<grant_id>:<field>`, and a writer
   chooses the row id before it encrypts. No owned row has ever existed
   (`20260912020000` refused them and nothing has written one since), so
   this was free now and would have been a data migration after stage 4.
   The platform row's format is untouched.
4. **The database refuses to change a grant's owner.** 0052 decision 1's
   "no transfer of a grant between users or scopes" was held only by the
   changesets not casting `user_id`. The trigger function now raises on an
   UPDATE that changes it.

One gap to carry: stage 4 makes linking reachable and stage 5 brings the
keepalive. Between them an idle user grant would lapse at the auth server's
window. `refresh_for_user/3` already renews a grant that is idle past
`platform_keepalive_days/0`; only the schedule is missing.

## Stage 2 as built

Built on 2026-09-20. Nothing a user can reach sets the field, so nothing a
user can do resolves to a grant; the HTTP API and the console for it are
stage 4.

**The reference.** `20260921010319_sets_name_a_chatgpt_grant` adds a
nullable `inference_credentials.chatgpt_grant_id` whose foreign key is
composite: `(chatgpt_grant_id, user_id)` references the grant's `(id,
user_id)`, the index stage 1 left for it. "A set names only a grant its
owner holds" is therefore a fact of the database, and the deployment's
grant is out of reach for free: its `user_id` is NULL and a set's never is.
The key is NO ACTION. Nilifying would turn a set whose grant went away into
a set with no grant, whose next codex run resolves to its own key or to the
platform, which is decision 4's silent switch; RESTRICT is checked
immediately, can never be deferred, and would fail an account deletion,
which cascades to sets and grants from one statement. So
`ChatGPTAccounts.remove_for_user/3` now answers `{:error, {:named_by_sets,
names}}` for a tombstone that sets still name, under the same owner's lock
`set_grant/3` holds. Disconnect is never blocked by a set: it is the kill
switch.

The key is also `DEFERRABLE INITIALLY DEFERRED`, which review of this stage
added. Deleting a user reaches the sets and the grants through two RI
cascade triggers that PostgreSQL fires in trigger-name order, which is OID
order and nothing this repository chooses. Not deferred, NO ACTION is
checked at the end of the grants' cascade, so it passed only because the
sets' cascade happened to run first; a dump and restore can flip that, and
the failure is an account deletion refused on a foreign key. Deferred, the
check runs at COMMIT after both cascades. The cost is that a violation
raises at COMMIT and never becomes a changeset error, so the key is a
backstop only: the guards are `set_grant/3`'s owner-scoped read and the
`{:named_by_sets, _}` refusal. A sandboxed test never commits, so the tests
that prove what the key refuses run `SET CONSTRAINTS ... IMMEDIATE`, and
one deletes the grants before the sets on purpose.

**The write.** `InferenceCredentials.set_grant/3` names a grant or, with
`nil`, stops naming one. It reads the grant with
`ChatGPTAccounts.get_for_user/2` under the owner's source lock. Another
account's grant, the platform's, a missing one and an id that is not one
are a single changeset error, so an id cannot be probed; a disconnected
grant is refused by name; a revoked or expired one may be named, since that
is a state a named grant reaches anyway. `Credential.changeset/2` does not
cast the field, so a credential or name write cannot carry a grant along.
The set's `revision` does not move on a repoint: the source's identity is
the grant, so a repoint already reads as a changed source. A conversation
on the set's API key keeps validating unless its runtime is codex; a codex
one resolves to the grant on its next turn and reads
`:inference_source_changed`, through resolution rather than through
`revision`. Naming a grant therefore ends the set's running codex
conversations, which stage 4's picker should say. Naming the grant a set
already names is a no-op decided before the grant is read, so a caller that
sends the whole set back is not refused because that grant was disconnected
since. Audited after the transaction as
`inference_credential_set.chatgpt_grant_changed` with both grant ids and
the new grant's name.

**The source.** A new scope, `:grant`, beside `:credential`,
`:tenant_secret`, `:platform`, `:none` and `:missing`. It is not
`:platform`, so `Source.platform?/1` is false, the origin is `"own"`, and
neither the platform ceiling nor the platform debit is reached, with no
billing code touched. `kind` is `:codex_chatgpt_access_token`, `identity`
is `chatgpt_grant:<grant id>`, `revision` is the generation, and
`grant_id` and `generation` are carried as fields of their own: the pin
`credential_for_user/4` takes. `Source.dump/1` writes those two keys only
when they are set. Every stored source is compared whole with a fresh dump
(`Resolver.matches/2`, `InferenceBinding`, turn admission), so a key every
source began to carry, even as `nil`, would have refused every conversation
admitted before the deploy with `:inference_source_changed`. The platform
path's dump is held to a literal map. `Source.grant_ref/1` answers `{:user
| :platform, id, generation}` for stage 3.

**Resolution.** The named grant is read only for an OpenAI model or the
codex runtime, by owner and id, metadata only; this is the third refusal of
a cross-owner reference. The runtime is in that rule because an agent's
model may carry no `provider/` prefix (`Agent.changeset/2` refuses only a
wrong one, and `Model.provider("gpt-5")` is nil): keyed on the provider
alone, a codex agent on such a model skipped the grant and ran on the set's
API key, or on an environment or vault `OPENAI_API_KEY`, with no error.
Review of this stage found it. `missing_for_model/3`, `SpriteEnv.build/4`
and `SpriteEnv.without_inference_inputs/3` asked the same prefix and were
closed the same way, the last two only for a `:grant` source, so every
other source on such an agent is as it was. The platform grant's rule stays
narrower (`PlatformInference.credential_for/2` wants the prefix), and can:
with no prefix nothing of the platform's is selected at all. For the codex
runtime the grant is the source, decided ahead of
the override merge, so an `OPENAI_API_KEY` in the environment or the vault
does not outrank it (0053 decision 5 rule 2); the OpenAI key is dropped
from what the runtime is handed and no bearer is put there. For any other
runtime the grant is not a credential: with a key the ordinary selection
serves, with none anywhere the result is `Source.missing/0`, never the
platform's key, and `missing_for_model/3` takes the runtime so the agent
form says so when the set is selected. An unusable grant is
`{:error, {:chatgpt_grant_unusable, %{grant_id:, name:, reason:, until:}}}`
with `reason` one of `:disconnected`, `:revoked`, `:expired`,
`:reconnect_required`, `:exhausted` (with `until`), `:not_found` and
`:broker_required`, and `InferenceCredentials.grant_unusable_message/1` is
the sentence. The grant's own state is reported before the deployment's
missing broker, so a disconnected grant on an unbrokered deployment says
disconnected. The sentence is total: a reason it has not been taught gets a
plain one, because it is called while a 409 is being rendered.
`validate_source/2`, which runs before every turn, passes the error through
instead of flattening it to `:inference_source_changed`, and its readers
keep it whole: the turn stream's `admission_refused` stage carries `reason:
"chatgpt_grant_unusable"`, `grant_reason`, `grant_id` and the sentence, and
a schedule's `last_error` is the sentence. A log line gets
`InferenceCredentials.loggable_reason/1`, the grant id and the reason
without the name the tenant chose. The acceptance test puts a connected
platform grant, a platform key, the set's own key, an environment and a
vault `OPENAI_API_KEY` and a second active grant in place and usable, shows
the vault key, the other grant and the platform grant each serving a set
that does not name this grant, and then asserts the error.

**The guard.** `CodexChatGPT.transport_ready/1` refuses a `:grant` source
until stage 3 builds its transport, answered over HTTP as a 409
`chatgpt_grant_transport_unavailable`. It stands at four doors: launch
admission, `InferenceBinding.reserve/2`, `TurnMachine.gate/2` and turn
admission's locked check in `Conversations._unsafe_create_turn_on_sandbox/4`.
The first two keep a conversation from being bound to a grant. The turn's
two are for a source persisted some other way: a wake that reuses a live
machine starts a server on the stored source without binding again. Stage 3
deleted the function and all four calls, with the transport in place.

**The usage stamp.** A turn on a `:grant` source is stamped `"inference" =>
"own"` with no `"model"`, like any other tenant source, so it is never
priced and never counted against the platform ceiling. Which grant served
it is stage 5.

Four things stage 2 settled or found:

1. **"Resolves `:missing` with an actionable error" was two results.** In
   the resolver `{:ok, Source.missing(), creds}` is a success: the sandbox
   provisions with nothing to call, and under an explicit set it becomes
   `:inference_credential_unusable`, which names nothing. An unusable named
   grant on a codex run is always the tagged error above, whether the set
   was named explicitly or is the account default. `Source.missing/0` is
   kept for the other half of decision 2, a set with a grant and no key
   asked to serve a non-codex OpenAI consumer.
2. **A conversation pinned to something else is told its source changed,
   not that a grant is unusable.** Re-validating a conversation bound to
   the set's API key, or to a grant the set named before it was repointed,
   can meet an unusable grant that conversation never ran on. The resolver
   answers `{:chatgpt_grant_unusable, _}` under an expected source only
   when that source is the same grant, and `:inference_source_changed`
   otherwise. A reconnect is a new generation and also a changed source,
   which is 0052 decision 5's "invalidates old-generation peers". So no
   remedy the sentence offers revives a conversation pinned to that grant:
   reconnecting and repointing both end it. The sentence therefore ends
   "and start a new conversation", which is also right for a refused
   launch. Only exhaustion clears for the same conversation, by waiting,
   and its sentence keeps the two apart.
3. **An unbrokered deployment refuses a named grant; it does not use the
   set's key.** `:broker_required`, for the reason the platform grant is
   never selected there: the token would reach the sandbox in the clear.
4. **Resolution cannot see whether the owner may still use a grant.**
   `get_for_user/2` answers for a suspended, unverified or principal owner,
   and `credential_for_user/4` does not. Suspension is gated beside the
   source check on every turn, and neither of the other two can link a
   grant, so nothing resolves wrongly today; stage 3's credential read is
   where an ineligible owner is refused, and it must map that to the same
   tagged error rather than to a different credential.

Deliberately left for later stages, each with the stage that owes it:

- **Stage 3.** `grant_state/1` does not read `access_expires_at`, and
  nothing on the turn path renews a user's grant
  (`Egress.refresh_platform_chatgpt/3` is platform-only). Harmless while
  the guard stands; without the renewal a grant resolves usable and dies at
  the proxy. `Source.grant_ref/1` has no caller in `lib/` until then. An
  ineligible owner, and every reason `credential_for_user/4` can give, must
  map into `{:chatgpt_grant_unusable, _}` (item 4).
- **Stage 4.** `chatgpt_grant_id` on the credential-set HTTP API, the
  OpenAPI contract, the SDKs and the console. The `chatgpt_grant_unusable`
  409 body renders `grant_id`, `grant`, `until` and new values of `reason`
  that `Schemas.Error` does not declare. The schema is open and other codes
  already render undeclared keys (`credentials_url`), so nothing fails, and
  declaring them regenerates the contract and the SDKs: they join
  `Schemas.Error`, with the two new codes and a changelog fragment, in
  stage 4's regeneration. The controller must fetch the set scoped
  (`get_set(id, current_user.id)`) before `set_grant/3`, which takes its
  tenant from the struct it is handed. Whether a set that names a grant
  counts for `has_any_credential?/1` and the admin funnel. The `/start`
  banner: `needs_credential?/2` answers false for a
  `{:chatgpt_grant_unusable, _}`, so the page says the agent will reach a
  model when its next turn will be refused, and the banner's text is about
  a missing key. The agent form is quiet about a set whose named grant is
  disconnected or gone, because `missing_for_model/3` asks only whether a
  grant is named; and on an unbrokered deployment it asks for an
  `openai_api_key` that resolution would still refuse with
  `:broker_required`, which turns on whether such a deployment may link at
  all.
- **Stage 5.** Exhaustion, which the resolver already reads from the row
  and nothing writes for a user's grant. It must write the row and use the
  existing `:exhausted` reason with `until`, not a second atom. Which grant
  served a turn joins the usage stamp (decision 6); the scope is already
  stamped `"own"`.

## Stage 3 as built

Built on 2026-09-20. A conversation that resolves to a user's grant now
runs on it; no user can hold one before stage 4, so nothing does.

**No library release was needed.** `managoat_broker` 0.14 already had the
protected path 0052 decision 5 asks for: `Session.authorization`,
`http_only` and `protected`, a per-request `Store.authorize/2` called for
every request inside an open tunnel, and `ProtectedRule` /
`ProtectedCredential`, which inject the bearer and the identity header
themselves and refuse upgrades. Fountain's store implemented `lookup/1`
alone and built every session without them. Stage 3 is that half.

**The broker.** `20260921021249` adds the pin to `broker_sessions` as plain
columns: grant id, generation, owner (NULL for the deployment's grant), the
ChatGPT account id, and `managed_revoked_at`. They are outside
`rules_ciphertext` because the proxy reads them and the grant's own
transaction writes one; two checks hold that the pin is all or nothing and
that a user's grant rides only that user's session. There is deliberately
no foreign key to the grant: a grant that is gone must deny, not cascade
the session away from under a conversation whose other egress is good.

- *Issuance.* `Sessions.create/1` with `managed:` locks the grant row `FOR
  SHARE` and re-reads it in the transaction that inserts the session
  (`ChatGPTAccounts.lock_active_grant/1`): same owner, same generation,
  `active`, and for a user an owner who may still use a grant. The account
  id stored beside the pin comes from that read. Every issuance path passes
  the grant (`Egress.session_opts/1`: provision, reattach, the re-mint of an
  expiring session), so a grant disconnected since a conversation began
  gets no fresh session.
- *Every request.* `lookup/1` answers a managed session with an
  authorization reference that names the row and nothing else,
  `http_only: true`, and the policy for the account. `authorize/2` then
  admits a request to the Codex backend only while the session is live and
  unrevoked **and** the grant row still says the same owner, generation,
  `active` and account (`ChatGPTAccounts.protected_credential/2`): one row,
  no lock, nothing cached, the bearer and the account id from that single
  row version. Any other request gets the session's ordinary rules, read
  fresh; a fenced grant closes the Codex backend and nothing else. A failed
  read is `:unavailable`, a 503 at the proxy, never a cached success.
- *Invalidation.* One private seam in `ChatGPTAccounts`, `revoke_broker/2`,
  called inside the transaction of every write that ends what a session was
  issued for: a user's disconnect, reconnect and removal, the platform's
  disconnect and reconnect, a revocation and an expiry. The sessions are
  marked, not deleted. The mark is the fast path; the authority is the
  per-request read, which denies on a node that never heard of any of it.
  `update_rules/4` writes rules and `meta` and no `managed_*` column, so a
  delayed rewrite cannot restore a grant or move a session onto a newer
  generation.
- *The rule builder.* `ProtectedCompiler`, restored from `105fb6d1` and
  reshaped to take no bearer: `policy/1` is the fixed route (`POST
  https://chatgpt.com:443/backend-api/codex/responses`) for one account, and
  `compile/3` builds the session's ordinary rules and refuses any input that
  names the managed credential or injects into that route, including
  bindings persisted before `Reserved` refused them at the write. Its
  destination is fixed except under the test suite's
  `:codex_chatgpt_backend`, which is how the proxy rig drives the real
  listener through it; no environment variable sets it.

**The typed input.** The resolver hands a `:grant` run the grant's own
placeholder (`Reserved.placeholder/1`) where a credential would be, and
nothing else. `Broker.split_inference/2` takes no custody of one, so the
grant is never in the `brokered` map, a rule, a binding or a template. No
conversation process ever holds the bearer: it exists only inside
`Sessions.authorize/2`, for one request, as a `%Grant{}` whose `inspect`
omits it. One consequence follows, and review of this stage made it a
gate rather than an accepted risk (gate A under "Not built"): the bearer is
the one brokered credential that is not in the conversation's redaction
registry, because it was never anywhere to register it from. A response
that echoed `Authorization` back would put it in `log_events` and on the
SSE stream unredacted. The only destination is the fixed Codex route, which
is not known to; "not known to" is not a control.

**The sandbox.** `CodexChatGPT.managed_grant/2` says which sources are on
this path. For one, `env/3` exports the placeholder and
`CODEX_HOME=/home/sprite/.codex-grants/<grant id>.<generation>`, both from
the source; `prepare_sandbox/5` takes the source and the owner, which both
callers already held and passed neither of, links everything in `~/.codex`
except `auth.json` into that home with a constant script, and writes
`auth.json` from `ChatGPTAccounts.sandbox_auth/1`, pinned by owner, id and
generation. `platform_sandbox_auth/0` is no longer reachable from a user's
source: review found one way it still was, a `:grant` source that pins
nothing (no owner, or persisted without its grant id or generation), which
fell through to the shared path; that is now `:invalid_codex_home`, and
`env/3` exports nothing for it. The home is process env only
(`Identity.disk_env/1`, by its value, so a tenant's own `CODEX_HOME` is
where it was), a tenant `CODEX_HOME` is dropped beside it, and on a
self-hosted runner the value goes through `Sandbox.host_path/2` because env
values reach a runner verbatim. Same unix user, so this prevents overwrite
and mis-attribution, not reads: a peer that reads another grant's file gets
a placeholder and an account id, and its own session still sends only its
own grant's bearer and account.

**"Everything else stays shared" is order-dependent, and the first draft of
this section did not say so.** The script links the entries `~/.codex` holds
when it runs and skips any name the home already has. It cannot link what
does not exist yet. Whatever codex first creates under its per-grant
`CODEX_HOME` is therefore a real file private to that home, and shadows the
shared name from then on. From codex's source and not observed, that is its
sqlite state, `history.jsonl`, and a `config.toml` it rewrites by atomic
rename, which replaces the link with a file. Two grant conversations on a
fresh machine get separate sqlite state. On a machine whose `~/.codex`
already holds it they share it through the link, as every codex conversation
on a machine did before. What is reliably shared is what Fountain or an
earlier run put in `~/.codex` before the home was first prepared, which is
what the script's comment and the tests claim: `config.toml` as Fountain
wrote it, `AGENTS.md`, `skills/`, `sessions/`. This is #1910's subject, the
sqlite state runtime not being isolated per conversation on a shared
sandbox, and this stage is neither reliably better nor worse for it: #1910
names `CODEX_HOME` as the root that state lives under and prefers
`CODEX_SQLITE_HOME` per conversation, which this stage does not set; a home
here is per grant and generation, so two conversations on one sign-in still
share whatever state the home holds, and two on different sign-ins may or
may not, by the order above. #1910 stays open and unchanged by this.

The script is constant text run on every provision and reattach. Review
made it tolerate a peer preparing the same home at the same moment (the
check and the `ln` are two steps; a link that exists once `ln` has run is
what was wanted), refuse a home, or a directory of homes, that is itself a
symbolic link (exit 3), and remove an `auth.json` that is a link before the
write, leaving a regular one for the write to replace because a peer on the
same sign-in may be reading it. Everything under `/home/sprite` is the
agent's to write, so this narrows a same-user race and does not close it: a
link planted between the script and the write wins.

**The turn.** `TurnMachine.gate/2` ends in `CodexChatGPT.ensure_fresh/2`:
for a grant inside its refresh margin, `refresh_for_user/3` by grant id and
generation, outside the source lock, after the account's own gates so a
suspended account costs no provider call. Nothing is handed back and no
rule is rewritten: rotation reaches the proxy through the grant row. A
grant that cannot serve refuses the turn with stage 2's tagged error,
including the reasons only the credential side can see (stage 2's item 4):
`:revoked` for a refresh token the auth server has just refused, and a new
`:owner_ineligible`, with its own sentence, for an owner who may no longer
use a grant. A renewal that failed for a reason that may pass lets the turn
go ahead on the token it has (0047's limitation, kept). `Egress` renews
nothing for a user's grant and compares no token for one.

Two other places meet a grant that ended, and review made both say so in
the same words. The issuance fence can refuse between a server resolving
its source and minting its session (`{:broker, :session,
:managed_grant_inactive}`); a wake published that `retryable: true` with an
inspected tuple, as it does a broker outage, and a first provision
published the tuple. Both now publish `chatgpt_grant_unusable` with the
grant's reason, id and stage 2's sentence, `retryable: false`
(`CodexChatGPT.refusal_stage/3`). The reason is read from the row first,
because a disconnect is a new generation too and `ensure_fresh/2` alone
calls every ended grant a changed source. And `prepare_sandbox/5`, whose
pinned read finds nothing for a grant that was reconnected, answered
`:reconnect_required` where `ensure_fresh/2` answers the same fact
`:inference_source_changed`; it now answers that too.

**The guard is gone.** `CodexChatGPT.transport_ready/1`, its four call
sites and the 409 `chatgpt_grant_transport_unavailable` are deleted. The
four tests that pinned the refusal became the tests of what replaces it.

Five things stage 3 settled or found:

1. **Decision 6's placeholder paragraph was wrong as a blocker.** A broker
   session is per conversation (`broker.ex`, "Custody"), its token rides in
   `HTTPS_PROXY`, which is process env, and a conversation is pinned to one
   source. "Two grants in one sandbox" is two conversations, two sessions
   and two policies, and `managoat_broker`'s "one non-exportable bearer per
   session" is enough. Under the protected path the placeholder is not even
   read by the broker: the proxy drops the client's `Authorization` and
   supplies its own. Two grants inside *one conversation* would need a
   library release; nothing here wants that.
2. **The fourth blocker decision 6 missed: the machine binding.**
   `bind_inference/2` is 0053 decision 6's interim rule, one inference
   source per codex machine for its life, there because every codex peer
   shared one `~/.codex/auth.json`. It would have answered the acceptance
   test with a 409. `20260921023458` adds `sandboxes.codex_peer_homes`, set
   at a machine's very first Codex bind and never again. On such a machine
   a source with a home of its own is compatible with every peer, is not
   recorded as the machine's binding, and is not counted against a newcomer
   that uses the shared file; and nothing recorded means nothing has used
   the shared file, so an API key may join a subscription. **Unchanged:**
   two API keys still collide (0053 decision 6's isolation for them is out
   of this ADR's scope), and a machine first bound before the column
   existed keeps the old rule for every source, a subscription included;
   the way forward on one is still an ephemeral sandbox or a reset of the
   home. No existing assertion of `:codex_inference_conflict` moved.
3. **`CODEX_HOME` is per source, and done from Fountain.** Per grant and
   generation, as decision 6 words it, not per conversation: two
   conversations on one sign-in share a home and write identical files, and
   the directories are bounded by grants times reconnects. Bounded is not
   cleaned up: nothing removes `/home/sprite/.codex-grants/<grant>.<generation>`
   after a disconnect, a reconnect or a removal. What it holds is links, a
   placeholder and an account id, for the life of the machine.
   `managoat_runtimes` fixes codex's config root and neither it nor
   `managoat_acp` reads `CODEX_HOME`; 0052 decision 5 anticipated a library
   release here, and this ADR's authors cannot make one, so the home is a
   directory of symbolic links made from Fountain.
4. **The deployment's grant is not moved onto this path here.** Every piece
   above serves owner `:platform` and is tested for it: issuance, the
   per-request check, every lifecycle write's revocation, 0052's adversarial
   cases through the real proxy. But `managed_grant/2` names a user's
   subscription only. Moving the platform grant changes a working feature
   in ways nobody can re-measure from here: no WebSocket egress from a
   codex conversation on it, `chatgpt.com` narrowed to one route whose
   capture predates the current `managoat_runtimes` pin, a tenant binding
   that matches the route failing the provision instead of being shadowed.
   So `Broker.@inference` keeps its `CODEX_CHATGPT_ACCESS_TOKEN` entry, the
   platform bearer is still a substitution rule in `rules_ciphertext` and
   still reaches a custom binding's template map behind `Reserved`'s
   write-time guards, and **`Egress.refresh_platform_chatgpt/3` still
   recognises the platform grant by comparing token strings**, which 0052
   decision 4 forbids. That compare now serves the platform grant only and
   can never see a user's. 0052 decision 6's "apply these restrictions to
   the existing platform path before enabling user grants" is therefore
   **still owed**, and is a gate on stage 4's surface opening. The change
   that pays it is one clause of `managed_grant/2`, the platform resolver
   returning a placeholder, a drain of the legacy substitute sessions, and
   the deletion of that compare; it is prepared as its own branch so it can
   be reviewed, measured and reverted alone.
5. **The published wording of `codex_inference_conflict` was left alone.**
   `Schemas`, the fallback message and `docs/configuration.md` say a shared
   Codex sandbox requires the same resolved source. That stays true of every
   source an account can hold until stage 4, which regenerates the contract
   for `chatgpt_grant_id` and rewords it then.

**After review.** Two reviews of this stage, one for security and one for
correctness, found nothing of high severity. What they changed is in the
paragraphs above where it belongs, and in one place here:

- The per-request path had a read with no timeout, the tenant key's, under
  a docstring and a sentence of this ADR that said every read had one. It
  has one now, and the cost sentence below counts what is really read.
- A grant that ended between the resolve and the broker session is a
  named, permanent refusal on a wake and on a first provision, not a
  retryable broker failure ("The turn").
- A reconnected grant is `:inference_source_changed` at the home as at the
  turn; a `:grant` source that pins nothing is refused and never reaches
  the shared path; the link script survives a concurrent peer and a planted
  link ("The sandbox").
- `Reserved` held a secret's value to the rule for names, a case-insensitive
  substring match, so a setup script or a JSON blob that mentions
  `codex_chatgpt_access_token` was refused at the write and, for a row older
  than the write's check, failed every provision on a grant. Names (keys,
  every binding field, network patterns, the account id) keep that rule. A
  value is refused only where it could stand for the credential: the
  reserved name alone, a placeholder occurring anywhere in it, the
  deployment's or any grant's, or a `{{ NAME }}` reference. That loosens
  nothing the protected route depends on: what stops a tenant rule
  injecting there is `ProtectedRule.prepare/4` over the effective rules,
  which no value reaches, and a placeholder inside a value, the one thing a
  `:substitute` rule would rewrite, is still refused.
- The grant's revocation leaves expired sessions to the sweep; a failing
  managed session logs once a minute instead of once per request; the
  second migration takes a lock timeout like the first; the acceptance
  test also reaches its machine by a first bind on a `pending` row, which
  is how production sets `codex_peer_homes`.

What review left is the rest of this section: two claims corrected rather
than code changed (what "shared" means under a per-grant home, and that
homes are bounded but never removed), two security gates that need a
library release, a rate cap, and two lock orders.

**Not built, and said so where it lives:**

- Closing tunnels that are already open on other nodes, and revoking the
  token upstream (0052 decision 5, "evict ... close affected tunnels").
  Correctness does not wait on either: nothing is cached per tunnel, and
  the next request in an open tunnel is refused.
- The legacy drain (0052 decision 5, "no old socket is grandfathered").
  There is nothing to drain for a user's grant, which has never had a
  session of the old kind. It belongs to the platform move in item 4.
- API-key peer isolation on a shared machine (item 2).
- **Any measurement against a real client.** That codex-acp and the codex
  CLI honour `CODEX_HOME`, resume a session through a linked `sessions/`,
  find skills through a linked `skills/`, and that an atomic-rename writer
  replacing a link with a real file degrades to per-source state rather
  than failing, is asserted from their source and not observed. Nor is it
  observed that the real `chatgpt.com` accepts the protected request shape
  for the client the image installs, or that codex asks that host for
  nothing the one route would refuse: `test/fixtures/codex_protected`
  captured two turns on codex-acp 1.10.0 and CLI 0.153.4, before the
  current `managoat_runtimes` pin. **Both are required before the user
  surface opens**: one run in a real sandbox with a symlinked home across a
  reattach and a `thread/resume`, and a re-run of
  `scripts/probe-codex-protected.py` against the pinned client with
  `capture.json` refreshed. Stage 5's controlled run is where they belong.
  If the symlinked home does not hold, the remaining fix is a
  `managoat_runtimes` release that lets `Layout.config_root/1` take an
  override.
- A per-request cost that is new, because the library calls `authorize/2`
  for all of a managed session's requests, `apt` and `npm` included. An
  ordinary request is two indexed reads (the session row, the owner's
  wrapped key) and two AES opens (the key, the rules). A request to the
  Codex backend is three reads (the session, the grant joined to its owner,
  the owner's wrapped key) and two opens (the key, the bearer); on the
  deployment's grant, two reads and one open, its token being under the
  master key. That is beside `lookup/1`, which costs an ordinary request's
  worth once per tunnel and once per request on the plain path. Every one
  of `authorize/2`'s reads has a five-second timeout, the key's included,
  which `Crypto.load_tenant_key/2` takes for this caller only. 0052's
  consequences accept the cost; it is worth watching once there is traffic.
- **A per-session request rate cap.** Those reads come from the shared
  `Repo` pool, each may hold a connection for up to five seconds, and the
  sandbox decides how many requests there are. A prompt-injected agent in a
  loop can therefore spend the pool's connections on its own egress. Review
  bounded the reads and the log (a failing session writes each of its
  warnings once a minute per node through `Fountain.LogThrottle`, not once
  per request) and left the rate alone: a cap belongs at the proxy's
  admission, per session, and nothing here builds one.
- **Removing a grant's homes.** See item 3: the directories outlive the
  sign-in they were for.
- **A home that exists before the environment's own steps run.** Package
  installs, clones and the `setup_script` run with the conversation's spawn
  env, so with `CODEX_HOME` pointing at the grant's home, and
  `FreshProvision` runs them before `prepare_runtime_sprite/7` creates it. A
  script that ignores codex never notices. One that runs codex there makes
  the home itself, with real files where the link script would have put
  links, and by the order-dependence above the conversation then runs on
  that `config.toml` and not on the one Fountain wrote with the agent's MCP
  servers. Not fixed: preparing the home earlier puts it in front of a
  checkpoint restore, and withholding the variable from those steps is a
  decision about what a setup script is promised, which stage 4's
  documentation should make.
- **Two lock orders PostgreSQL would have to break.** Both rare, both
  detected by the database and surfaced as one aborted transaction, neither
  prevented. `revoke_grant/2`, inside the grant's transaction, and
  `update_rules/4` both update a conversation's live sessions with a
  multi-row statement; they share two rows only while a re-minted session
  overlaps its predecessor, and then may lock them in opposite orders, and
  the side that aborts can be `disconnect_for_user/3`, the kill switch.
  Review took the expired rows out of `revoke_grant/2`, which removes the
  same shape against `sweep_expired/0`; that is safe only because nothing
  extends a session's `expires_at`, which was checked and is said where a
  future write would break it. And an account deletion locks the user row
  and cascades to the grant, while `Sessions.create/1` holds the grant `FOR
  SHARE` and then needs `FOR KEY SHARE` on the user for the session's
  foreign key. Taking the user's key share first would order them, and was
  not done because no audit of every other path that locks a user row after
  a grant row stands behind it.

**Two security gates, not built, both before the console surface opens
(stage 4's route, stage 5's gate), and both a `managoat_broker` release
rather than Fountain code:**

- **Gate A: the bearer in a response.** The grant's bearer is the one
  brokered credential absent from the conversation's redaction registry (see
  "The typed input"). If `chatgpt.com`, or an error page from whatever sits
  in front of it, ever reflects the request's `Authorization`, the bearer
  lands unredacted in `log_events` and on the SSE stream, where anything
  that can read the conversation reads it. Only the proxy holds the bearer
  at that moment, so the fix is there: scrub, or refuse, a protected
  response that contains the bearer its request was sent with. Fountain
  cannot do it: registering the bearer would mean a conversation process
  holding it, which is what this stage exists to prevent.
- **Gate B: the query string on the protected route.**
  `Managoat.Broker.ProtectedRule` matches the path and forwards whatever
  query string came with it, under the bearer. The pinned client sends none,
  and `scripts/probe-codex-protected.py` asserts the exact target, so
  nothing legitimate is lost by refusing one; an agent that can reach the
  proxy can add one today. The gate is a library option to refuse a
  non-empty query on a protected route, set by `ProtectedCompiler.policy/1`.

What the tests hold, for the platform's grant and for a user's unless the
case is about two of one user's: this stage's three acceptance tests
(`conversations/codex_grant_peers_test.exs` through two real
`ConversationServer`s, `broker/managed_grant_proxy_test.exs` through the real
listener, a CONNECT tunnel and a TLS origin); 0052's pause-and-resume cases
with really contending connections (`broker/managed_grant_fence_test.exs`);
a request inside a tunnel opened before the disconnect, refused from the
durable generation with the revocation mark cleared, which is the
suppressed-notification case; an unavailable store; an in-flight request
that completes; an upgrade and a nested CONNECT refused before the origin
sees them, on every host of the session; a forged account id and the other
grant's placeholder; persisted bindings that name the managed key or a
wildcard over its route; and the bearer absent from server state, the
`brokered` map, `rules_ciphertext`, the redaction registry, log events and
every `inspect`. After review, also: the tenant key read under the
request's timeout on both halves of `authorize/2`; a grant ended just
before the mint, through a real server on a wake and on a first provision;
the link script run for real against an `ln` that loses the race every
time, one that fails outright, eight at once, a planted home, a planted
directory of homes and a planted `auth.json`; secret values that mention
the reserved name and values that stand for the credential, each through
the write and through `compile/3`; twenty failing requests and one line of
each warning; and the acceptance pair on a machine that starts `pending`.

**For stages 4 and 5.** Disconnect, reconnect and removal already revoke
broker authorization, because the revocation is inside
`disconnect_for_user/3`, `reconnect_for_user/4` and `remove_for_user/3`; a
surface that calls those needs nothing more. Account deletion needs nothing
either: grants and broker sessions both go by cascade, and a session whose
grant is gone denies. The turn-path renewal is `CodexChatGPT.ensure_fresh/2`
at the end of `TurnMachine.gate/2`; stage 5's keepalive is a different
caller of the same `refresh_for_user/3`. Exhaustion, when stage 5 writes it,
should stay out of `protected_credential/2`: an exhausted grant is `active`
and its token is good, so it is a selection fact, not an authorization one.
Stage 4 owes the `owner_ineligible` reason a place in `Schemas.Error` beside
the others, the `codex_inference_conflict` wording of item 5, a sentence in
the manual about what a `setup_script` sees of `CODEX_HOME`, and, before any
of it is reachable, item 4's platform move, the two measurements and gates
A and B.

## Stage 4a as built

Built on 2026-09-21: the half of item 4 that is not a page. A subscription
can be linked, reconnected, renamed, disconnected and removed over the API,
and a credential set can name one over the API. **Linking is off for every
account**, behind a flag that fails closed, and the things stage 3 said are
owed before a user's surface opens are owed before that flag is turned on:
this stage merges dark. The console is 4b.

**The attempt.** `20260921060000` creates `chatgpt_link_attempts`, one row
per device-code sign-in (`ChatGPTAccounts.LinkAttempt`). The row is the
attempt's whole state; no process holds any of it, so an API poll, a page
reload and the job that drives it read the same thing. It carries either the
`name` a new link will take or the `grant_id` a reconnect is for, with the
`expected_generation` the server read under the owner's lock when the
attempt began; the client never sees or supplies a generation. There is no
foreign key to the grant, for `broker_sessions`' reason: a grant removed
under an open attempt has to fail it by name. The auth server's
`device_auth_id` and the user code are stored under the owner's DEK with an
AAD of their own, `fountain.chatgpt_link_attempt:<user>:<attempt>:<field>`,
are `redact: true`, and are dropped by the write that ends the attempt; a
check holds "pending has both, anything else has neither" in the database.
No token is ever stored here. `state` is `pending` and then exactly one of
`completed`, `cancelled`, `expired` and `failed`; `failure_reason` is one of
a closed list in the schema, never anything the auth server said, and
`conflict_grant_id` names, for `account_already_linked`, the grant to
reconnect instead. One open reconnect per grant is a partial unique index,
answered first by the context as `{:link_attempt_pending, %{attempt_id: _}}`.
Fifteen minutes, as codex and the admin flow give a device code.

**The lifecycle**, in `ChatGPTAccounts.LinkAttempts` behind
`ChatGPTAccounts`'s `*_attempt_for_user` functions. Every write is the
context's `user_write`: the owner's source key, then the attempt's row, and
for a completion then the grant's row, which is the stage-1 order with one
row in front.

- *Start.* The admission (an eligible owner whose encryption key loads,
  fewer than ten attempts begun in the last hour in any state, fewer than
  three open across all of the account's grants, and
  for a link a well-formed name that no grant or open attempt of the owner
  holds and room under the ceiling; for a reconnect a grant of the owner's
  with no attempt open) runs twice, each time in its own transaction: before `OAuth.device_start/0`, so
  a refused request costs the auth server nothing, and again in the
  transaction that inserts the row and its job. Each reads the clock for
  itself, because the auth server may take seconds in between, and sweeps
  the account's overdue rows in its own transaction first. The auth server
  is never called inside a transaction or under a lock. The rollout flag,
  whose lookup may be an HTTP call, is asked before either.
- *Expiry is lazy.* A pending row past `expires_at` reads `expired`, shows
  no code and is admitted by no write, whether or not anything has written
  that. Whoever meets one writes it: the job's next run, a cancel, a
  completion, a disconnect or removal of its grant, and a start, which
  sweeps the account's overdue rows first so one cannot hold a grant's only
  open reconnect. Correctness never waits for
  a sweep.
- *Complete.* `connect_for_user/4` and `reconnect_for_user/4` take a new
  `:within` option: a function handed the write, run in its transaction
  under the owner's key before any row is read.
  `complete_attempt_for_user/4` uses it to lock the attempt, require it
  pending and in time, run the write with the pinned generation, and mark
  the attempt `completed` with the grant's id, in one transaction. So the
  owner's eligibility, the ceiling, the upstream account, the name and the
  generation are all asked again by the write that stores the grant, and
  none of that is a second implementation. Whether the account may still
  link is asked again too, for a new link only and before the transaction,
  because that answer may be an HTTP call: a link open when linking is
  turned off fails as `linking_disabled`, and the poll asks before it
  spends the exchange. A refusal rolls back; the
  attempt is then written `failed`, and `chatgpt_link_attempt.failed`
  recorded, in a transaction of its own afterwards. A replay reads the
  completed attempt and writes nothing.
- *Cancel* takes the same two locks in the same order, so exactly one of a
  cancel and a completion ends an attempt. Both interleavings are tested
  with really contending connections.
- *A grant that ends takes its open attempt with it.* `disconnect_for_user/3`
  and `remove_for_user/3` lock the grant's pending attempt before the
  grant's row, which is the order above, and end it in their transaction as
  `failed` with `stale_grant` or `grant_not_found`: what its completion
  would have been told. Its event carries the caller's attribution. A grant
  already disconnected leaves its attempt alone; that one began after the
  tombstone and is how it comes back.

**The driver.** `Fountain.Workers.ChatGPTLinkAttempt`, on a new `chatgpt`
queue (10), is inserted in the transaction that inserts the attempt,
scheduled one poll interval out, unique per attempt while incomplete. Its
args are the attempt's id and its owner's. Each run is
`poll_attempt_for_user/3`: one `device_poll`, outside any lock; on approval,
`device_exchange` and the completion; otherwise a snooze for the auth
server's interval, which is kept between a second and a minute, doubled
per consecutive unanswered poll up to a minute (`poll_failures`). The three
device-flow calls take the refresh's Finch limits, eighteen seconds at the
worst. A run that raises is retried in a constant ten seconds, ten times:
Oban's default backoff grows with `attempt`, which every snooze raises, and
would soon have put one retry past the attempt's fifteen minutes. A reader
of a pending attempt in time puts its job back if no incomplete one names
it (`ensure_enqueued/1`). A 4xx from the auth server ends the attempt as
`authorization_failed` or `exchange_failed`; a 408, 425, 429, 5xx or
transport error is asked again. An attempt that is gone, ended or past its
time costs no request. The device id, the user code, the authorization code
and the tokens are locals of that call; the log line for a failed poll is a
status or a terminal code and nothing else. `RetentionPruner` deletes
attempts a week after they ended, and pending rows a week past their time
whose job was lost.

**The gate.** `chatgpt_subscriptions` is in `FeatureFlags.@flags` and **not**
in `@on_without_posthog`: off where PostHog says so, off where there is no
PostHog, on only by a PostHog release condition or `FEATURE_FLAGS_ON`.
`ChatGPTAccounts.linking_enabled_for?/1` is that flag and
`Broker.configured?/0`, and it is asked by exactly one door: starting an
attempt for a **new** link. A reconnect needs the broker alone. Listing,
reading, renaming, disconnecting, removing and cancelling ask nothing at
all, not even the broker, which is one step further than Connections'
`manageable_for?/0`: a deployment that loses its broker still has grants
with refresh tokens in them, and the kill switch must work there.
`/api/auth/me` reports the gate as `chatgpt_subscriptions_enabled`, and the
list as `linking_enabled`.

**The API.** Eight routes under `/api/account/chatgpt-subscriptions`, behind
`:require_full_scope` (`FountainWeb.ChatGPTSubscriptionController`): list,
`PATCH` to rename, `POST :id/disconnect`, `DELETE`, and `POST`, `GET`,
`GET :id` and `DELETE :id` under `attempts`. Another account's id is a 404
on every one. There is no route that returns or refreshes a token. The JSON
view names its keys one by one: a subscription is id, name, status, plan,
the owner's own ChatGPT email, whether it is refreshable, its two times,
the sanitized revocation reason and `exhausted_until`; never a token, a
claim, the provider's account id, `generation` or `lock_version`. An attempt
carries `user_code` and `verification_url` while pending and null after,
and never the device id. Attempt responses are `cache-control: no-store`.
The list carries `count`, `limit` and `linking_enabled`. The refusals
follow stage 2's rule, a bad state of something the caller owns is a 409:
`chatgpt_grant_limit_reached`, `chatgpt_grant_still_connected`,
`chatgpt_grant_named_by_sets`, `chatgpt_link_attempt_pending`,
`chatgpt_link_attempts_exceeded`, `chatgpt_link_attempt_not_pending`; 404
`chatgpt_subscriptions_not_enabled` (the Connections precedent); 403
`chatgpt_owner_ineligible`; 502 `chatgpt_auth_unreachable`; 503
`chatgpt_tenant_key_unavailable`; 429 `chatgpt_link_attempts_rate_limited`
with `Retry-After`. `account_already_linked`, `stale_grant` and
`linking_disabled` are not HTTP errors: they happen in the job, minutes after the request, and
are the attempt's `failure`.

**What stage 2 left for this one.** `PATCH
/api/account/inference-credential-sets/:id` takes `chatgpt_grant_id`, `null`
included, after fetching the set scoped by the caller; every set reports
`chatgpt_grant_id` and a read-only `chatgpt_grant` of id, name and status,
from one read of the owner's grants per response. `Schemas.Error` declares
`grant_id`, `grant`, `until` and the values of `reason`, `owner_ineligible`
among them, with `count`, `attempt_id`, `state` and `sets` for the new
codes. `codex_inference_conflict` says who is exempt, in the schema, the
fallback message and `docs/configuration.md` (stage 3's item 5). The
contract, the TypeScript types and the Swift wire models are regenerated;
the operations sit under the existing `* /api/account/*` omission, so no
SDK's handwritten surface or version moved. `CHATGPT_GRANT_CEILING` is the
environment variable stage 1 withheld.

**For 4b.** Every committed write that changes what a user's grants or
attempts read as, a revocation found by a refresh included, broadcasts
`{:chatgpt_grants_changed, user_id}` on `ChatGPTAccounts.topic/1`. The one
write that does not is a poll's `poll_failures` count moving between two
values above zero, which changes nothing anybody is shown; it broadcasts
when the auth server stops answering and when it answers again, which is
when `AttemptView`'s `auth_unreachable` changes. The message carries
nothing, and a subscriber reads `list_for_user/1`,
`list_pending_attempts_for_user/1` and `list_recent_attempts_for_user/1`
again. The last is the attempts that ended in the past half hour, newest
first and ten at most: the pending list drops an attempt the moment it
ends, so it is where a page reads why a sign-in failed and which grant to
reconnect instead. A page reload is a `mount` that renders a pending
attempt's code from that read. The context takes
`Audited.attribution(socket)` as it takes a conn's.

Nine things stage 4a settled that this ADR left open. Each is a call a
maintainer may reverse:

1. **A job polls, not the reader.** Polling `device_poll` from the read
   endpoint would make a client's poll rate the auth server's, and would
   link nothing for a user who closed the tab after approving.
2. **An unbrokered deployment links nothing and reconnects nothing.** A
   grant there resolves `:broker_required` (stage 2, item 3), so a link
   would store a rotating credential that can serve no run.
3. **The owner's ChatGPT email is in the API body**, to the owner only, and
   in no audit event, log line or job.
4. **`generation` is not in any body**, and since the review not in a
   tenant audit event either. The server pins it when an attempt begins. One consequence: with one open reconnect per grant, two sign-ins
   racing on one grant cannot be produced through this surface at all. A
   disconnect and a removal end the open attempt themselves, so the fence
   is what a writer outside the context meets, and "a late completion
   cannot undo Disconnect" is tested both ways.
5. **A fourth attempt event, `chatgpt_link_attempt.expired`**, beside
   `started`, `cancelled` and `failed`, recorded by whoever writes the
   expiry, as `system:chatgpt_link_attempt`. A completion is the grant's own
   `chatgpt_grant.connected`, with that actor when the job did it and the
   attempt's id in its metadata, which is what ties it to the `started`
   event that says who began the sign-in.
6. **An open link attempt holds its name, not a place under the ceiling.**
   The ceiling is asked when the attempt begins and again when it
   completes, so an account at four of five with two attempts open links
   one and fails the other as `grant_limit_reached`.
7. **The context refuses a principal, an unverified and a suspended
   account** a start and a rename (`eligible_owner/1`), and leaves them
   list, disconnect, remove and cancel. That is what a LiveView meets. Over
   HTTP only the principal gets that far, as 403 `chatgpt_owner_ineligible`
   to a `principal: true` user holding a full key: `TenantAPIAuth` answers
   a suspended account 401 and an unverified one 403 `email_unverified` on
   every route before any controller runs. So a suspended owner cannot
   clear stored refresh tokens over the API; that is an operator's act.
8. **Rate limiting is two things, both in the database and both per
   account**: three open attempts, and ten begun in an hour in any state,
   counted from the rows under the owner's key. The second is what bounds
   a start that is cancelled and started again, whichever API key, node or
   caller asks.
9. **Attempts are pruned after a week**, by `RetentionPruner`, on fixed
   terms like expired exports rather than a configurable window.

**Known limitations, recorded rather than removed.**

- **Tokens that are not stored are not revoked.** A cancel that wins after
  the exchange has returned, and every refusal at completion (`stale_grant`,
  `account_already_linked`, the ceiling, an owner who became ineligible),
  discards an access and refresh token the auth server has issued.
  Upstream revocation is not built for any grant (stage 3, "Not built").
- **A completion that raises loses the sign-in.** If the database is
  unreachable after the exchange, the job's retry polls a device code the
  auth server has already redeemed; the attempt ends `authorization_failed`
  or expires, and the user starts again. Nothing is half-written.
- **There is no deployment-wide bound on device codes.** Ten an hour is per
  account, and accounts are free to make where registration is open. Every
  device code and every grant's refresh, the platform's included, go to one
  host, so enough accounts could have that host throttle the deployment. A
  global ceiling was not built: counted without a lock it is approximate,
  and any number small enough to matter is one a few accounts could use up
  to deny everyone else a sign-in. Linking is behind the flag; a reconnect
  is not.
- **A job orphaned in `executing` loses the sign-in.** A node killed
  mid-run leaves its job `executing`, which is incomplete, so a reader does
  not replace it, and `Oban.Plugins.Lifeline` rescues it after thirty
  minutes, which is after the attempt's fifteen. The attempt reads
  `expired` and the user starts again. A job that was discarded or deleted
  is put back by the next read.
- **The fifteen minutes are fixed.** The device-start answer this code has
  seen carries a code, an id and an interval and no lifetime, so a code the
  auth server ends sooner is polled until the auth server refuses it.
- **A 429's `Retry-After` is not read.** A rate-limited poll backs off as an
  unanswered one does, to the same minute a `Retry-After` would be capped
  at.
- **A purged pending row has no ending event.** `purge/0` deletes a pending
  row a week past its time that nothing ever wrote `expired`; its `started`
  event is then the only one it has.
- **Oban keeps what a crash carried.** A job's blamed exception is stored in
  `oban_jobs.errors`, arguments included. That the poller cannot put a
  device code or a token there rests on the functions its secrets pass
  through staying total: `OAuth.device_poll/2` and `token_response/1`,
  `Tokens.decode_payload/1`, and `LinkAttempts.device_code/1` for the
  start. Each has a fallback clause that names no value, and a comment
  saying why it must stay.
- **An idle user grant still lapses** at the auth server's window (stage
  1's gap): the keepalive is stage 5, and is one more reason the flag is
  off.

**Owed, with who owes it:**

- **Before the flag is on for anyone** (stage 3's list, unchanged): the
  platform grant's move onto the protected path, the two measurements
  against a real client, and broker gates A and B.
- **Stage 4b.** The **ChatGPT subscriptions** card and the set picker, whose
  confirm text says naming a grant ends the set's running codex
  conversations; page reload; whether a set that names a grant counts for
  `has_any_credential?/1` and the admin funnel; `needs_credential?/2` and
  the `/start` banner for a `{:chatgpt_grant_unusable, _}`;
  `missing_for_model/3` and the agent form for a named grant that is
  disconnected or gone, and for an unbrokered deployment (settled by item 2
  above: it may not link, so the form should stop asking for a key it would
  refuse). The manual: a guide page, `docs/concepts/secrets.md`, the codex
  runtime page, and the sentence stage 3 owes about what a `setup_script`
  sees of `CODEX_HOME`. This stage documented the API (`docs/api.md`), the
  flag and the ceiling (`docs/configuration.md`) and the feature's status
  (`docs/reference/feature-status.md`, "In development").
- **Stage 5.** Unchanged: the keepalive fan-out, exhaustion written for a
  user's grant (the API already renders `exhausted_until`), which grant
  served a turn, and deletion and export. A grant's metadata is not in the
  account export, and neither is an attempt. Account deletion needs nothing
  here: attempts go by cascade, and a job that finds no row ends.
- **No CLI and no SDK client** wires any of this; the `/api/account`
  omission stands.

**The trust model, stated.** An OAuth client's token is an API key of
`full` scope (`Fountain.OAuth.Host`), so a third-party app a user has
authorized reaches this whole surface, the user code included. That is the
existing model for every account-level route, not a new one. Device-code
phishing is inherent to the flow: a victim who types an attacker's code at
ChatGPT's page links their subscription to the attacker's Fountain account.
What the server controls it does: `verification_url` is built from
configuration and never from a response, and a code is shown only to the
account that started it. `docs/api.md` tells an integrator to show the code
only to the user who started the sign-in and to say "only enter a code you
started yourself". A reconnect of a disconnected tombstone may sign in a
**different** upstream account than the grant held, so with linking off a
user who holds a tombstone can still, in effect, link a new subscription
into it. That is the "one door" as decided, and it is unchanged.

**After review.** Two reviews, of security and of correctness, found
nothing critical or high. What they found, and what was done:

- The start limit was a plug keyed per API key per node, and the console
  would have bypassed it. It is now the admission's, per account, counted
  from the rows (item 8). The plug is gone.
- The poller had Oban's default backoff, which a snoozing job outgrows; its
  queue was sized by one account's pending limit; its calls had no connect
  timeout. Constant backoff, ten slots, the refresh's limits.
- A lost job left an attempt pending with nothing polling it. Its readers
  put it back. The orphaned-`executing` case is a known limitation.
- A name was counted in graphemes against a column that counts codepoints,
  so a name of combining marks was a 500 after a device code had been
  spent, and a NUL was a 500 at the first query. Names are counted in
  codepoints and carry no `\p{C}` character, in `Account.name_format/1`,
  for a link and a rename alike.
- The controller's tag took unmapped atoms out of the fallback's safety
  net. A final tagged clause hands them back to it.
- A disconnect or removal left the grant's open attempt pending, and the
  next reconnect was a 409 until it was cancelled. They end it now.
- One `now` spanned the auth server's answer. Each admission reads its own.
- Any interval was kept. It is clamped to a minute.
- `generation` was in three tenant audit events, contradicting item 4.
  Nothing read it, so it is dropped, and a completion's event gains
  `attempt_id`.
- A new link in flight completed after linking was turned off. It fails as
  `linking_disabled`.
- A credential set's `PATCH` with a grant that could not be named stored
  the rename and then answered 422. The grant is asked first
  (`InferenceCredentials.check_grant/2`).
- The migration set its lock timeout after the drop on a rollback. It is
  `up` and `down` now.
- Item 7 and the broadcast sentence said more than the code did, and are
  corrected above.

What the tests hold: the row's checks, its cascade, its ciphertext bound to
owner, attempt and field, and nothing secret from `inspect` of the row, a
changeset or a view (`chatgpt_accounts/link_attempt_test.exs`); ownership,
the pending limit, the ceiling at creation, one open reconnect per grant,
cancellation, lazy expiry, ineligible owners, and the flag and the broker
each off with everything else still operable
(`chatgpt_link_attempts_test.exs`); replay as one grant, one event and an
unchanged row, a late completion against a newer credential and after a
disconnect with the grant row compared whole, completion after a cancel and
after expiry storing nothing, the same upstream account, the ceiling and
the name asked again, and the cancel-against-complete race in both orders
on contending connections (`chatgpt_link_attempt_completion_test.exs`); the
job against a stubbed auth server, with its args, its snooze and backoff,
and the auth server's words in neither the row nor the log
(`workers/chatgpt_link_attempt_test.exs`); and over HTTP, a sprite-scoped
key refused on every route with nothing changed, another account's ids as
404 on every route, each refusal's status and code, no body on any route
carrying a token, the device id, a claim, the provider's account id or a
fencing column, and the flag off closing one door
(`chatgpt_subscription_controller_test.exs`,
`inference_credential_set_controller_test.exs`). The audit guardrail covers
the attempt's five ends. Since the review they also hold: the eleventh
start in an hour refused with no device code spent, from a second API key
and for a reconnect alike; a constant backoff at any `attempt`; a lost job
put back once and an orphaned one left alone; a device-flow call against a
socket that never answers ending inside the refresh's ceiling
(`platform_chatgpt/oauth_test.exs`); names the column cannot hold or nobody
can see as 422 with no device code spent; a disconnect and a removal ending
the open attempt, and the fence against a tombstone written outside the
context; linking turned off under an open link; and the recent list, its
ownership and its half hour.

## Stage 4b as built

Built on 2026-09-21: the console half of item 4. **Linking is still off for
every account**, and nothing here changes what is owed before the flag is
turned on. With the flag off and no grant held, the page is what it was.

**The card.** `FountainWeb.InferenceCredentialsLive.SubscriptionsCard`, a
LiveComponent under the provider rows of `/account/inference-credentials`:
one row per grant with its state (Connected, Reconnect required, Cannot
serve here, Usage spent, Disconnected), the owner's ChatGPT email and plan, Rename, Reconnect,
Disconnect and Remove; the count against the ceiling; and a Connect form
that takes a name and starts an attempt. An open attempt shows its user
code, the page to type it on, when it expires, Copy and Cancel, and one
sentence this ADR did not ask for and a device-code flow needs: approve a
code only if you started it yourself, because whoever's code you approve
gets the use of your plan. The page subscribes to `ChatGPTAccounts.topic/1`
and, on `{:chatgpt_grants_changed, _}`, calls `SubscriptionsCard.load/2`
again; every event handler writes through the context and lets that
message redraw the card, so a second tab, an API call and the job all
arrive the same way. Since the review every handler also sends the page
that message itself, because a write that changes nothing broadcasts
nothing. **Page reload** is therefore a `mount`: the test opens
a second LiveView on a pending attempt, sees the same code, runs the job,
and watches both pages turn to Connected without a reload.

**What is assigned.** `load/2` is the one place the page reads
`ChatGPTAccounts`, and it projects key by key: a grant is its id, name,
display state, plan, email, last renewal and `exhausted_until`; an attempt
is its id, kind, name or grant id, user code, verification link, expiry and
whether the auth server has stopped answering; an ended attempt is its id,
kind, name or grant id, state, the grant it wrote, and its failure's reason
and conflicting grant's name. Attempts are read only for the connected
mount: the render before it is the body of a `GET` with no `no-store`, and
carries no code.
`generation`, `lock_version`, `account_id` and the claims are in the
context's grant view and are not in an assign, so no template can print
them; the redaction test reads the rendered page in three states and
`inspect` of the projection, with no `:sys.get_state`. The verification
URL becomes a link only when it parses as `https` on `auth.openai.com` with
no userinfo; otherwise the card shows the code and tells the user to type
`https://auth.openai.com/codex/device`, a constant of the module and not
the row's value. Names and everything else go through HEEx's escaping;
nothing is `raw/1`.

**Ownership.** Every handler calls the context with the user the page was
mounted for and treats an id in an event as the client's word. Another
account's grant or attempt id is the context's `:not_found` and reads "no
longer on this account"; an event with no id, a non-string id or an unknown
name gets a plain sentence from a catch-all clause, on the card and, since
the review, on the picker's `set_grant` too, and the LiveView stays
up. Every refusal `ChatGPTAccounts` documents has a sentence, and a term
the card does not know gets a generic one, never `inspect/1`.

**Reconnect.** A second attempt over the same row, offered where the
deployment brokers, whatever the flag says. The button goes while an
attempt is open on the grant, its confirm text says a completed reconnect
ends conversations pinned to the old sign-in (stage 2, item 2), and the
test reads the old bearer through `credential_for_user/4` while the attempt
is pending and the new one, under the new generation, after. How an
attempt ended is said from `list_recent_attempts_for_user/1` (see "After
review"): connected, reconnected, expired, or the failure in words.
`stale_grant` is "was discarded ... left exactly as it is", which is true
of a late completion and of the sign-in a disconnect ended;
`account_already_linked` names the grant to reconnect instead.

**The picker.** A fifth row beside the four providers, about the selected
set, with a select of the owner's grants and None, submitted through
`InferenceCredentials.set_grant/3` behind a confirm that says what stage 2
found: changing what a set names ends the codex conversations running on
it. The set's named grant is always listed, with its state when it is not
connected, and the row warns that codex runs on the set are refused. A
disconnected grant is offered only to the set that already names it.

**The gate, in the console.** The card renders when
`linking_enabled_for?/1` is true, or the account holds a grant, or has an
attempt open. With the flag off Connect is absent and the context refuses a
crafted `connect`; the picker lists only the grant the set already names,
with None, and the handler refuses any other id; Rename, Reconnect,
Disconnect, Remove and Cancel stay. With no broker the card says these
cannot serve or be reconnected, Reconnect is absent, and each grant that
would otherwise read Connected reads Cannot serve here.

**What stage 2 left for this one.** `/start` shows a second banner, the
sentence of `grant_unusable_message/1`, for a `{:chatgpt_grant_unusable,
_}`. `InferenceCredentials.named_grant_problem/4` asks `resolve/4` the same
question for the agent form, only for codex on a set that names a grant,
and the form shows the sentence when the set is selected.
`missing_for_model/3` no longer asks for an `openai_api_key` for such a
set, broker or no broker: for codex the grant is the source or the run is
refused, so the form had been collecting a key resolution would never use.

Six things stage 4b settled that this ADR left open. Each is a call a
maintainer may reverse:

1. **The picker is a provider-style row, not a control on the set panel.**
   The panel is hidden for an account with at most one set (0053), and the
   default set names a grant like any other. An account with no set at all
   gets its default set by naming a grant, as a first key would have given
   it one.
2. **The flag gates naming as well as linking.** `set_grant/3` and the API
   ask no flag; the console does, for a grant the set does not already
   name. It is the narrower reading of "the console surface stays gated",
   and it is the console's alone: the API can still repoint a set with the
   flag off.
3. **A set that names an `active` grant counts for `has_any_credential?/1`
   and the admin funnel's `_unsafe_user_ids_with_credential/1`.** A grant
   no set names does not, and neither does a named one that is
   disconnected, revoked or expired. Both are account-level questions and
   cannot ask "for a codex agent only"; the per-agent questions are the
   banner's and the form's, which do.
4. **The card's display state is the resolver's.** As first built it
   restated `Resolver.grant_state/1` less the broker, and said Connected
   where a run is refused. The function is now public behind
   `InferenceCredentials.grant_state/1`, unchanged, and the card maps its
   answer: it reads the view it is handed and nothing else, so the card
   still does not resolve per row. A state resolution learns and the card
   has not reads "Reconnect required".
5. **How an attempt ended is read from its row, for half an hour.** As
   first built it was shown only to a page that saw the attempt pending.
   4a's review added `list_recent_attempts_for_user/1`; `load/2` projects
   it and the notices are computed from it, three at most, so a page
   mounted afterwards says the same sentence. Starting another sign-in
   dismisses them for that page, not for the next mount.
6. **No new JavaScript.** Copy is the existing `CopyToClipboard` hook, and
   the expiry is a clock time, not a countdown. A code whose time passes
   stays on an open page until the job's next run writes the expiry and
   broadcasts. That is one poll interval later, or up to 60 seconds when
   the job has backed off from an auth server that was not answering; no
   write admits it meanwhile.

**After review.** Two reviews, of security and of correctness, found
nothing critical or high. The branch was first rebased onto stage 4a as
reviewed, which is where the ended-attempts read, the start limit,
`auth_unreachable`, `linking_disabled` and a disconnect that ends the open
sign-in come from. What they found, and what was done:

- An account with no set got its Default made before `set_grant/3` was
  asked, and a refusal left the page with no set: every later save made
  Default again and met its unique name. The picker reads the default set
  first, asks `check_grant/2` before it makes one, and reads the sets again
  after every refusal.
- The picker's handler had no catch-all, so a `set_grant` without a string
  crashed the sender's LiveView, and a crash report prints assigns. It has
  one.
- A failed sign-in left no trace after the socket reconnected, which is
  what happens when a phone's owner leaves for the browser to approve the
  code. Item 5 above.
- A LiveView event never meets a plug, so the console's starts were bounded
  only by the three that may be open. The console shares the context's
  limit of ten an hour (4a, item 8) and its refusal has a sentence, with
  the wait in minutes.
- A pending code was in the HTML of the `GET`, without the `no-store` the
  API puts on it. Attempts are read for the connected mount only.
- The agent form ran `named_grant_problem/4`, a resolution under the
  owner's source lock, on every `phx-change` and in both mounts. It runs in
  the connected mount and when the model, the runtime, the set or the
  environment is not what it was.
- The chip said Connected with no broker, and nothing said that an owner
  who may not use a grant is refused at the turn. Item 4 above; the card
  and the picker say the second, and `named_grant_problem/4` answers
  `owner_ineligible` in the turn's terms, for the form and for `/start`.
- A write that changed nothing broadcast nothing, so a stale page could say
  "Disconnected Work." beside a Connected row. Every handler asks for a
  re-read.
- With linking off, removing the last grant unmounted the card with its
  "Removed Work.". A page that has shown the card keeps it until reload.
- The picker's gate read a `linking?` cached at mount. It asks
  `linking_enabled_for?/1` in the handler, and compares ids as UUIDs.
- Saving what a set already names showed the confirm and then "now runs
  codex on". The handler reads the set's row and says nothing was changed.
- A changeset error on `grant_id` read "Name already has a sign-in in
  progress."; a message outlived later changes; a cancel of an overdue
  attempt said so twice; `/start` said "until then" of a reason with no
  time; the Connect input had no label and a long name overflowed. Fixed.
- Disconnect and Remove now end the grant's open sign-in (4a), so the
  Disconnect confirm says so where one is open, the Reconnect confirms say
  what would discard the new sign-in, and `stale_grant` and
  `grant_not_found` no longer say the code was approved.
- The guide's state table presented Usage spent as working. Nothing writes
  exhaustion for a user's grant until stage 5: the guide and feature status
  now say a spent plan is not detected, stays Connected and fails the turn
  with OpenAI's error.

Two things the reviews raised that are left as they are, and said here:

- **`has_any_credential?/1` counts any `active` named grant** (item 3),
  one that cannot be renewed, a deployment with no broker and an ineligible
  owner included, so the dashboard's checklist skips the credential step
  for an account whose codex runs are refused. It is not a dead end: the
  `/start` banner and the agent form say why. The account-level question
  stays a status read.
- **A pending attempt's user code is in the LiveView's assigns** while the
  attempt is open, so a crash of that process would print it, and the
  owner's ChatGPT email, in a crash report. The two known ways to crash it
  are closed (the picker's catch-all above, and 4a's refusal of control
  characters in a name, which the card's test now sends), and
  `AttemptView` already keeps the code out of `inspect/1`; the projection
  is a plain map and does not.

The guide moved in the nav from "Connect a service", which is about OAuth
connections and their flag, to the Catalog beside the codex runtime page.

**The manual.** `docs/guides/chatgpt-subscriptions.md`, in the nav, with
the in-development note, the approval warning, the state table, and the
sentence stage 3 owed: a `setup_script` runs with `CODEX_HOME` already
pointing at the grant's home and before Fountain prepares it, so it must
not run codex or write there. `docs/concepts/secrets.md`, the codex runtime
page, `docs/api.md` and `docs/reference/feature-status.md` point at it, and
the secrets page no longer says per-source Codex homes are unbuilt.

**Owed, with who owes it:**

- **Before the flag is on for anyone**: unchanged from stage 3 and 4a.
- **Stage 5.** Unchanged: the keepalive fan-out, exhaustion written for a
  user's grant (the card already renders it as Usage spent, and until it
  is written never does: a spent plan reads Connected and its turn fails
  upstream), which grant served a turn, and deletion and export. When the keepalive exists the
  card's "Last renewed" is where an idle grant's health shows.
- **Not built, and nobody's yet.** Revoking a token upstream on Disconnect
  (the card says to sign the device out at ChatGPT), and a CLI for any of
  this.

What the tests hold: connect, the code, the link and the expiry; a link
refused for four URLs that are not OpenAI's; page reload and a completion
reaching two open pages; an attempt begun elsewhere appearing; cancel, and
a late approval after it linking nothing; expiry and an auth-server refusal
in words; rename, disconnect, remove, removal refused with the sets named;
markup in a name escaped; another account's ids and malformed events on
every handler with the other account's rows compared whole; redaction; the
flag off with and without grants; reconnect keeping the old credential,
cancelled, over a disconnected grant, late, already linked, cross-owner,
flag off and broker off; the picker on one set, no set, a second set, a
disconnected grant and a foreign id; and since the review, the start limit
in words, a remount saying how a sign-in ended, no code in the `GET`'s
body, a disconnect and a removal ending the open sign-in, an auth server
that stops answering, a no-op event on a stale page, a message that goes,
the card kept after the last removal with linking off, a refused first
save with no set, a set made in another tab, a no-op save, the flag turned
off under an open page, malformed `set_grant` events, control characters in
a name, and the chip and the picker with no broker and for a suspended
owner (`chatgpt_subscriptions_live_test.exs`), and with linking off
(`inference_credential_sets_live_test.exs`); the banner and the form for a
usable, a disconnected and an unbrokered grant
and for a suspended owner on `/start`, and the form resolving again only
when its inputs change (`chatgpt_grant_problem_live_test.exs`); and
`named_grant_problem/4`, `grant_state/1`, `missing_for_model/3` and
`has_any_credential?/1` (`grant_selection_test.exs`).

## Stage 5 as built

Built on 2026-09-21, in two halves: 5a is accounting (exhaustion for a
user's grant, and which grant served a turn), 5b is the keepalive, export
and deletion. **Item 5's second sentence is not done**: nobody has linked
two real subscriptions and run the controlled sequence. That run, the
checklist it belongs to and what is owed before the flag is on for anyone
are in
`contributing/chatgpt-subscriptions-rollout.md`,
and its results go in [Measured](#measured) below. Linking is still off for
every account. No migration in either half: the exhaustion columns were
already on the shared table, and `turns.inference_source` already held the
serving grant.

### 5a: exhaustion, and which grant served a turn

**Exhaustion is written for a user's grant, only when OpenAI confirms it.**
A failed codex prompt whose error passes `UsageLimit.hint?/1`, on a
`:grant` source, starts a background check under `Fountain.TaskSupervisor`
scoped by the conversation's owner (`TurnMachine.ctx/2` gained
`:user_id`). `ChatGPTAccounts.check_exhaustion_for_user/2` answers
`:started | :ignored`; `confirm_exhausted_for_user/3` answers what
`platform_confirm_exhausted/2` does, whose contract and tests are
unchanged: internally `confirm_exhausted/4`, `grant_row/3`,
`claim_usage_check/4` and `write_exhaustion/5` take an owner that is nil
for the platform. The sandbox's report is a hint, as in 0047: the adapter
runs in a tenant's sandbox. The row is read through the eligible-owner
query by owner, grant id, generation and `active`; `usage_checked_at` is
claimed with the platform's 300 s cooldown, per grant, under the owner's
source lock; the token is decrypted with the tenant DEK and sent to
`/wham/usage` with no lock or transaction held; a confirmed limit writes
`usage_exhausted_at` and `usage_exhausted_until`, fenced the same way,
under the tenant key and never the platform's. The tenant event
`chatgpt_grant.exhausted` (actor `system:chatgpt_accounts`; the name,
`until`, `confirmed_by: "wham/usage"`; no account id, no generation) and
the `{:chatgpt_grants_changed, _}` broadcast happen after the write's
transaction commits. Another owner, a replaced generation, a tombstone and
a suspended owner are ignored with no call upstream. The reset is lazy: a
passed `until` reads as nil and nothing clears the column.

**What the owner sees.** The failing turn fails with codex's own message
and is not retried. Every later launch and turn on that grant, a
conversation already pinned to it included, is `chatgpt_grant_unusable`
with `reason: exhausted` and `until`, on the 409 and on both stream stages.

**Nothing is substituted**, which is decision 4 and needed no code: a
`:grant` source never reaches `PlatformInference.grant_unless_exhausted/2`.
It is proven by an acceptance test in which another grant of the same
user, the set's own key, the default set, an environment and a vault
`OPENAI_API_KEY`, a platform grant and `PLATFORM_OPENAI_API_KEY` are each
present and shown usable by the value they would hand the runtime, before
the limit is recorded and again after the refusals: the launch and the turn
are refused all the same. A grant turn is stamped `"own"`, is not priced
and never reaches the platform ceiling
(`ee/test/fountain/credits_chatgpt_inference_test.exs`).

**The broker stays unaware of exhaustion.** An exhausted grant is `active`
with a good token, so `protected_credential/2` still authorizes it.
Selection refuses it, and a turn in flight ends on OpenAI's own 429.

**Which grant served a turn: a divergence from decision 6 and from stage
2's note**, both of which say the grant "joins the usage stamp". It does
not. The pricer and `Turn.inference_stamp_only?/1` read the `usage` map, so
the serving grant stays where `source_stamp/2` already wrote it once per
turn, in `turns.inference_source`, and is read from there. The turn JSON
gains a read-only `inference` object, `{origin, scope, chatgpt_grant_id}`:
null for a row with no source or an unknown scope, never `generation`,
`identity` or `revision`, and the grant id only for a `:grant` source whose
id is a UUID. The id goes on naming a grant after the grant is removed, so
a reconnect, a repoint or a restart relabels no earlier turn. The export's
turn entries carry the same object. The team summary's smaller turn shape
carries none. New `Source.summary/1`, `Source.scopes/0`,
`Source.origins/0`; the OpenAPI schema, the contract and the TypeScript
and Swift types follow.

**After review (5a).** A hint inside the cooldown is dropped before any
lock or transaction, from the row already read; the locked conditional
UPDATE stays the authority. The check uses the token on the row the claim
returned, so a concurrent refresh cannot make it stale. A write that loses
its fence is `:ignored`; a failed write transaction is
`{:error, :usage_write_failed}`, logged with the grant id and the step.
Both doors start their task through one function that answers `:ignored`
if the supervisor refuses. `UsageLimit.request/1` rescues into
`{:error, {:usage, :transport}}`, and the platform's log line goes through
the same sanitiser (`UsageLimit.loggable_reason/1`). A failed or
inconclusive check still spends the five-minute cooldown, so a plan that
really is spent can fail turns with codex's message for up to five minutes
before it is refused by name; the API page, the guide and the changelog
say so. The console re-reads by one timer at the earliest reset it shows,
because the lazy reset writes and broadcasts nothing. And the review found
a real gap: a `ConversationServer` started without the prompt's wake door,
a reattach after a restart for one, resolved the pinned source itself and
for an exhausted grant published `tenant_credential_load_failed` with an
inspected tuple. It now publishes `CodexChatGPT.refusal_stage/3`'s shape.
The wake door refuses an exhausted grant before any server starts and
leaves the conversation alone; **a direct server start still ends the
conversation `failed`**, as it does for a disconnected grant, which may be
too harsh for a state that passes. It is pinned in a test and is the
maintainer's to change.

### 5b: the keepalive, export and deletion

**The keepalive closes the gap stage 1 recorded.**
`Workers.ChatGPTKeepaliveSweep` runs at 04:37 UTC on `maintenance`. It
pages `ChatGPTAccounts._unsafe_due_user_grants/2` in keyset pages of 100
and queues one `Workers.ChatGPTGrantKeepalive` per grant on a new queue,
`chatgpt_refresh`, which runs two per node, below the four renewals
`RefreshCoordinator` admits, so a turn's renewal always has room. The scan
is cross-tenant by design and says so in its prefix; it returns three ids
a grant and fetches no ciphertext. Due is: active, `chatgpt`, holding a
refresh token and an upstream account id, an eligible owner, and
`last_refreshed_at` nil or at least `platform_keepalive_days/0` old. A
tombstone, a revoked or expired grant, a suspended, unverified or
principal owner's grant and the platform row are never selected. The
answer is a hint: the job calls `refresh_for_user/3`, which reads the
grant again by its owner, and a disconnect, reconnect, removal, suspension
or deleted account between the two cancels the job with no call to the
auth server. One job per grant keeps failures apart: `refresh_token_reused`
on one grant marks that grant reconnect-required, through the fenced
`mark_revoked/2` stage 1 built, and the same user's other grant is
renewed. The six days remain provisional on 0047's measurement 5.

**The rate toward `auth.openai.com`.** Jobs are scheduled at a random
second of `min(6 h, max(300 s, due x 5 s))`, from a count the first page
reads and the continuations carry, so about one request every five seconds
up to 4,320 due grants; past that the cap lets the rate rise and the
queue's two slots per node bound it. `:chatgpt_keepalive_spacing_ms` is
the five seconds. Both workers have a bounded `backoff/1`, stage 4a's
lesson.

**Export and deletion.** The export gains `chatgpt_subscriptions` (id,
name, status, plan, the email OpenAI reported, last renewal, the sanitized
revoked reason, `exhausted_until`, the names of the sets that name it, the
two times) and `chatgpt_link_attempts` (id, kind, name or grant id, state,
failure reason, the grant it wrote, the three times), each key named one
by one, from owner-scoped reads that decrypt nothing; its `version` stays
1. The test renders the document and searches it for the fixture's real
access and refresh tokens, user code, device id, provider account ids,
generations and every ciphertext in six spellings. Deletion needed no
write-path change: grants, attempts and broker sessions go by cascade and
the set's deferred key makes the order irrelevant, proven under `SET
CONSTRAINTS ALL IMMEDIATE` with another account's rows compared whole.
`account.deleted` gains `chatgpt_grants_removed`, counted before the
delete, tombstones included. Queued keepalive jobs for a deleted account
cancel and its pollers finish, with no call to the auth server.
**Fountain cannot revoke a sign-in at OpenAI**: `PlatformChatGPT.OAuth`
has `refresh`, `device_start`, `device_poll` and `device_exchange`, and no
revoke leg. For an account that had linked any subscription the
account-deleted email says so and says to sign the device out in the
ChatGPT account; the email job carries the count, a number, only when it
is above zero.

**Design calls beyond this ADR (5b).**

1. **A per-node breaker, `ChatGPTAccounts.RefreshBreaker`.** Decision 5
   asks for bounded volume and says nothing of what to do when the auth
   server throttles Fountain's address, which stage 4a's review named as a
   cross-tenant outage. Refusals that look like a throttled address, for
   two different owners inside ten minutes, pause that node's keepalive
   jobs for fifteen minutes (`:chatgpt_refresh_breaker_ms`). It is
   half-open, one probe per node per fifteen minutes, and any renewal that
   succeeds closes it. A turn's own renewal never waits.
2. **`{:error, :rate_limited}`** is a new answer from a user grant's
   refresh, where every provider error was `:refresh_failed`. It carries
   no part of the response. On the turn path it falls through
   `CodexChatGPT.renewal_refusal/2` like any transient error: the turn
   runs on the token the grant has.
3. **The platform grant's refusal counts as evidence**, as an owner of its
   own, because it leaves from the same address. Nothing else changed for
   it: its renewals never wait on the breaker.
4. **Clocks in the job's `meta`**, never its args: the sweep's window, the
   job's first run and when the breaker first held it. The args stay the
   three ids.
5. **A job is its grant's place in the queue, for three days.** While a
   job is incomplete the next sweep's insert for its grant conflicts with
   it, so it does not give up early; a grant no longer due is an `:ok` at
   the job's next run. Seventy-two hours after its first run it is
   cancelled whatever it is waiting on, because snoozes raise
   `max_attempts` and nothing in Oban ends a job that only ever snoozes.
6. **The deleted-account email is conditional**, and the count rides in
   the email job's args.

**After review (5b).** A review for security and correctness found one
high finding and six lesser ones. All seven were verified against the code
and none was wrong.

- **One tenant could hold the breaker open.** As first built, any 429 or
  non-terminal 403 on any one grant opened it, and the turn path could
  trip it without limit, so an account whose grant is reliably refused, or
  a scripted turn loop, could starve every other tenant's keepalive on a
  node, against a thin margin: a first attempt can come 7 days 6 hours
  after the last renewal, and the idle window is assumed to be 8 days.
  Four bounds now. Only a 429, or a 403 whose body names no code `OAuth`
  can read, is evidence; a 403 that names a code is that account's and is
  `:refresh_failed`. The breaker opens only when two different owners were
  refused inside ten minutes. A grant is heard once per window, which is
  what bounds the turn path. And a job held two hours, or whose grant is
  seven days idle, went ahead as a probe. (The second review found this
  last bound, and the 403 rule, short of what this paragraph claimed; both
  are as the next paragraph says.) The table holds hashes of the grant and
  owner ids, for ten minutes.
- **The herd when it clears.** Held jobs woke within two minutes of each
  other. They now spread over the breaker's remaining time plus the
  sweep's window.
- **A job that fails its last attempt** logs once at `error`, the grant's
  id and an atom. So does a sweep page that is abandoned, which takes its
  continuation with it.
- **The give-up clock** ran from the insert, up to six hours before the
  first run, and a job that gave up while still due cost its grant a day.
  It runs from the first run, and see call 5, which the second review
  changed again.
- **Tests added**: forged args (one owner's grant under another's id; the
  platform row's id), a probe that is refused again, each bound. The test
  in which A snoozes and B renews says in its comment what it does not
  prove: `drain_queue` is serial and the timeout is handed back, so it
  shows the jobs are independent, not the slots. A renewal that really
  hangs holds one of two queue slots and one of four coordinator slots
  until its deadline.
- The breaker's fallback table, which would have died with a refresh
  task, is gone.

**After the second review (5b).** Nothing critical or high and nothing to
revert; three medium findings in how the job and the breaker meet, all
verified and none wrong.

- **The two-hour cap did not bound anything.** It and the seven-day bypass
  were looked at only when a job next ran, and the snooze could be six
  hours. A held job now never sleeps past the moment it becomes due to
  probe, by either clock.
- **Under real throttling Fountain sent more requests, not fewer.** Every
  held job probed at two hours, was refused, retried on its backoff with
  the same stale stamp and burned its three attempts; grants seven days
  idle did it from their first run. The breaker is now properly half-open:
  `claim_probe/0` admits one probe per node per fifteen minutes, counted
  from the claim, because a refused probe is evidence, extends the pause,
  and would otherwise hand the next job a probe at once. The seven-day
  bypass goes through the same door. A refusal that looks like a throttled
  address is a snooze of at least fifteen minutes and never a failed
  attempt, and it restarts the job's two hours.
- **A success never closed it**, so two owners refused every ten minutes
  held it open without end. `succeeded/0`, called where the auth server
  answers any owner's refresh with tokens, the platform's and a turn's
  included, closes it and clears what was heard, since the success refutes
  it. A probe that succeeds therefore releases every held job at its next
  wake.
- Lesser: a job that runs with the breaker down forgets it was held, so a
  later pause starts its two hours afresh. Only a 403 whose body is not a
  JSON object is evidence (`OAuth` calls it `"unreadable"`); an object
  with no readable code, `{"detail": …}` say, is `:refresh_failed`. No
  breaker function can raise if its table's owner has just died, which
  mattered because `observe/2` runs inside a turn's renewal. A held job
  whose grant is revoked under the same generation cancels at once. The
  discard line and the new three-day stop go through
  `LogThrottle.error/2`, once a minute per node, and the counter's new
  `discarded` says how many; a run that raises on its last attempt logs it
  too. The breaker takes a test clock.

**After the third review (5b).** An independent review of the final pass
found nothing urgent, with no user grant yet in production, and nine
lesser things. Eight were as described; one was half wrong: a 429 or 403
labelled JSON with an *empty* body was already evidence, because Req does
not decode an empty body. What changed:

- **An undecodable body keeps its status.** Req answers a JSON-labelled
  body that does not parse with `{:error, %Jason.DecodeError{}}`, so a 429
  cut short lost its status, read as `:refresh_failed`, was never heard by
  the breaker and cost the job an attempt. `OAuth.post/3` turns Req's
  decoding off and decodes the same bodies by hand, keeping the binary
  when it cannot, which `error_code/1` calls `"unreadable"`. The device
  legs go through the same door; a 2xx cut short, which the link-attempt
  poller used to see as a transport error, is still asked for again. That
  exception's `data` is the whole body, and since #1755 the platform
  grant's two failure lines printed `inspect(reason)`, so a token response
  cut short would have been written to a warning. They print a status or
  an atom now, whatever reaches them.
- **The breaker's evidence no longer competes for its probe.** A grant
  that is reliably refused never advances `last_refreshed_at`, so from its
  seventh day it was due to probe at every wake, first come, against the
  jobs it was holding; restarting its two hours did nothing, the seven
  days being an `or`. A `:rate_limited` answer now writes `refused_at` and
  `refusals` to the job's `meta`, and the job is not due to probe by
  either clock until `refused_at + min(24 h, 2 h x 2^(refusals - 1))`.
  With the breaker down it runs as any job does, so a grant that really is
  throttled loses nothing.
- **A refused probe re-opens the breaker by itself**
  (`RefreshBreaker.probe_refused/0`), which the second review's text
  claimed and the code did only when another owner had been refused in
  the last ten minutes. It stands for two pause lengths from the refusal,
  the next probe being one pause length after the last claim, so the
  breaker does not lapse between probes. It does nothing if a success
  closed the breaker while the probe was out.
- **A probe that asked nothing gives its turn back** (`release_probe/0`):
  a renewal crowded out, a grant that cannot be renewed (a suspended
  owner's reads as active to the held job's first, owner-only read, and
  the renewal's own read ends it), one already renewed. A due job that
  lost the claim wakes when the next can be made, or at the pause's end if
  sooner. `claim_probe/0` removes the stale claim it read and no other,
  which at the expiry boundary could have been a claim just made.
- **The opening is logged**, once a minute at `error`, as a count of
  owners; so is a held grant known to be seven days unrenewed, by its id.
  Until now a throttle of days showed in counters only and the first
  `error` line was the 72-hour stop.
- Lesser: `observe/2` ignores ids of another shape where it raised; the
  test clock is read only in a build compiled with
  `:chatgpt_refresh_breaker_test_clock`; every held snooze has the
  thirty-second floor; a grant with no renewal on record is of unknown
  age and is due to probe at once. The no-table test stops the table
  through its supervisor, where it used to skip its assertions whenever
  the restart won the race, which was usually.

**What is bounded now, exactly.** Under real throttling of the address,
while some job is due to probe (held two hours, or its grant seven days
idle, and not inside a refusal's back-off): a node's keepalive sends one
request per fifteen minutes and the breaker does not lapse between them.
When no job is due, as in a throttle's first two hours or once every due
job has been refused and is backing off, the breaker lapses fifteen
minutes after it opened, or thirty after the last refused probe, and the
jobs that wake then call until two owners have been refused again: two
requests, or three with both queue slots busy. A job is refused at most
once per wait, the wait is at least fifteen minutes, and no attempt is
spent on it. Under a breaker held open on false evidence, which takes two
accounts that are each reliably refused as a throttled address is: their
grants probe once each and then at two hours, four, and so on to a day, so
the probe is a victim's job's whenever one is due; that job's success
closes the breaker for everybody, and a victim's job that is not due
waits as long as the breaker stands, less whatever a success from any
owner cuts it short by, and at most seventy-two hours. It is not promised
a request of its own at two hours; that promise, made to every job, was
the hammer. A turn's own renewal is never held.

### Not built

- **The controlled run** of item 5, and everything on the rollout
  checklist.
- **Whether `auth.openai.com` throttles by address or by account is
  unmeasured.** 0047 measured a 401 `refresh_token_reused` and a 400
  ciphertext-integrity answer and nothing else. So is what a throttled
  refusal looks like: that it is a 429, or a 403 with no JSON object, is a
  guess. The two-owner rule and the evidence rule are guesses with the
  bounds stated above, not measurements: if the auth server throttles an
  address with a JSON 403 the breaker never opens, and if it refuses one
  account with an HTML 403 that counts as evidence it should not. The
  runbook lists both as things to observe.
- Revoking a sign-in upstream, on a disconnect or a deletion.
- A cluster-wide breaker: each node learns of a throttle from its own
  refused calls. Reading a 429's `Retry-After`. Holding a turn's renewal
  back while the breaker stands.
- Damping for a grant that fails every day without being refused for
  good: it is queued again by each sweep, three calls a day, and shows
  only as the throttled `error` line and the `discarded` count. No signal
  reaches its owner.
- A log line for a keepalive run, or a sweep page, that Oban kills at its
  timeout or that exits: only a returned error and a raise are seen. Those
  show in Oban's own telemetry.
- One `breaker_opened` per opening: two processes that report in the same
  instant may both open it and both be counted.
- An index for the due scan. Catching, on the same day, a grant that
  became due behind a running cursor.
- Proactive usage polling (detection is only after a failed turn that
  OpenAI confirms); an email or a webhook about a spent plan; failover
  between a user's subscriptions. An exhausted active grant still counts
  for `has_any_credential?/1`. The platform's `usage_checked_at` claim
  still takes no Elixir lock; only the user's takes the tenant key.
- Credential sets in the export beyond the names in `named_by_sets`.
  Pruning of tombstones; attempts keep their week. The account page's
  export sentence does not mention the two new sections.
- Closing tunnels that are already open, a per-session rate cap, removal
  of grant homes, a deployment-wide device-code bound, and a CLI or SDK
  client, all as the earlier stages left them.

### Measured

Empty until the controlled run. One row per gate; the procedure, the
versions to pin and the order are in the rollout document. Dates and pins
for the idle lifetime go in 0047's table, measurement 5.

| Gate | Pinned versions | Date | Result |
|---|---|---|---|
| The protected-path probe against the pinned client (`scripts/probe-codex-protected.py`; the capture fixture reviewed or replaced) | | | |
| A turn on each of two linked subscriptions: hosts, routes, `injected` counts and any refused request, from `broker_requests` | | | |
| A forced refresh of A, then a turn on A: generation unchanged, `lock_version` +1, B untouched | | | |
| Reattach and `thread/resume` through the symlinked home: `sessions/` and `skills/` resolve; whether `config.toml` became a real file | | | |
| A server restart, then a turn on each | | | |
| Disconnect A in an open tunnel: the next request refused, B still serves | | | |
| Exhaustion, real or a stubbed `/wham/usage`: the card and the refusal (optional) | | | |
| The keepalive observed for seven days: no unexpected `reconnect_required` | | | |
| What a throttled refresh looks like: its status, whether the body names a code, and whether it follows the address or the account | | | |
| Gate A (a bearer in a response is scrubbed) and Gate B (a query carrying it is refused), on the released `managoat_broker` | | | |
| The platform grant on the protected path, and its measurement (stage 3b, #2458) | | | |

## Consequences

A user can hold a personal and a work subscription and point different
agents at each, with the same field that points an agent at an API key. The
selection concept count does not grow: sets already carried the agent
field, the launch override and the allowlist.

Blast radius grows with the grant count. Keepalive, refresh contention and
broker rule volume all scale with grants rather than users, and one user can
now drive that number up to the cap. The cap and the bounded fan-out in
decision 5 are what keep it finite, and they are sized against a measurement
that is still outstanding.

A named grant that fails takes the run down with it. That is the intended
trade against a silent switch of quota or bill, and it makes grant state
something the console has to surface well — an exhausted subscription
discovered at the next turn is a bad experience, just a legible one.

`platform_chatgpt_account` now holds mostly user rows under a platform name.
That was already true of the column; it is now true of the row count.

The custody surface of 0052 decision 6 does not get easier with more grants.
Stage 3 built it and put a user's grant on it; the deployment's own grant
is still on the older path, and 0052's requirement that it move first is
still owed before the `chatgpt_subscriptions` flag is turned on for any
account ([Stage 3 as built](#stage-3-as-built), item 4;
[Stage 4a as built](#stage-4a-as-built)).

## Alternatives considered

- **One subscription per user, switching by reconnect (0052 as written).**
  Makes switching destructive: using the work account means losing the
  personal grant's lifecycle, per agent, per run. Sets removed the reason
  for the restriction.
- **A user-level preference plus a per-agent grant field.** A second
  selection mechanism beside `inference_credential_id`, with its own
  allowlist, override and default rules to keep in step. Rejected as
  duplicate machinery for a choice sets already express.
- **Automatic failover across a user's subscriptions.** Moves a run onto
  different quota without being asked, and needs every usage and audit
  record to carry which grant actually served each request. A separate
  decision if demand appears; not free to add later, but not made harder
  by decision 4 either.
- **A separate `chatgpt_grants` table.** Forks the cipher, refresh,
  fencing and generation code across two schemas — what 0052's "duplicate
  the admin implementation into a user module/table" alternative was
  rejected for.
- **Grants as a fifth column on the credential set.** A set would hold the
  rotating token itself, with no lifecycle, attempt state, reconnect or
  per-grant fencing. 0052 rejected this as "add a static token column to
  inference credentials" and it is still the wrong shape.
- **Wait for 0047's idle-lifetime measurement.** It sets a keepalive
  interval, not the data model. Decision 5 names it as a dependency of the
  fan-out sizing rather than of the design.
