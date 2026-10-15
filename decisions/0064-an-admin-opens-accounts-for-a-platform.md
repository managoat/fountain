---
type: ADR
title: "An admin opens accounts over the API for a platform built on the instance"
description: "POST /api/admin/users opens a verified, passwordless account and returns a full-scope key, for a provisioner holding a dedicated admin's admin-scoped key."
tags: [api, accounts, admin]
status: stable
adr: "0064"
adr_status: "Accepted"
date: 2026-10-13
---

# 0064 — An admin opens accounts over the API for a platform built on the instance

**Status:** Accepted, 2026-10-13. Built in the same PR: `POST /api/admin/users`,
`Fountain.Accounts.create_account_by_admin/3`, `User.admin_created_changeset/2`.

## Context

The maintainer's home platform (home-cloud) gives each of its applications
conversational agents, the way it gives them a database: an application
declares agents, and a provisioner makes them. Each application should be its
own tenant here, with its own ledger, so a monthly credit grant is a real cap
for that application, and one application's conversations are invisible to
another's.

Nothing could open an account without a person. Registration is the public
door: on the hosted instance it is gated by an access code and then by an
emailed link, and neither is something a provisioner can pass. The admin API
(#527) could top up, limit, suspend and delete an account, but not open one.

## Decision

1. **`POST /api/admin/users`** opens an account from `{email, key_name?}`. It
   is verified at creation, with no password, so nobody signs in as it. It
   comes with one full-scope API key, returned once in `api_key`. Its role is
   always `user`.
2. **It sits behind the existing admin pipeline** (`:require_full_scope` and
   `:require_admin_api`). Registration's gates (`REGISTRATION_ENABLED`, the
   access code, the email-domain list) don't apply: they guard the public
   door, and this is the operator's.
3. **It is audited three ways:** `account.created_by_admin` and
   `api_key.created` on the new account, both naming the admin, and
   `admin.account.created` in the admin trail.
4. **The platform's provisioner is a dedicated admin account,** not a
   person's, with a full-scope key that only the provisioner holds.

## Consequences

- **The provisioner's key is an admin's full-scope key.** It can do anything the
  admin API does to any account on the instance: delete it, change its role,
  suspend it, grant it credit. A narrower provisioner scope that could act only
  on the accounts it opened, and that could pin an account to particular
  sandbox providers, was drafted and declined for the smaller change; the
  platform keeps the key in its secret store, synced only into the
  provisioner's namespace.
- **An application's own key is a full-scope tenant key,** so it can still make
  agents on any provider the instance enables. The platform applies the
  agents it declares with the provider it wants; it does not stop the
  application doing otherwise.
- **No route deletes what this opens beyond the existing admin delete.** A
  platform removing an application suspends its account (the existing admin
  suspend) and keeps its transcripts.

## Addendum — 2026-10-14: no ledger and no credit grant

*Context* gives one reason for an account per application that no longer
exists: its own ledger, so a monthly credit grant caps that application.
Credits were removed a few hours after this ADR merged (#2609, the
2026-10-12 decision to stop selling a hosted service), and the per-account
sandbox limit the same day. The admin API can no longer
top up or limit an account; under `/api/admin/users` it lists, opens, shows,
changes the role of, suspends and deletes one. In *Consequences*, "grant it
credit" is gone from what the provisioner's key can do; the rest of that
blast radius stands.

The decision stands on its other reason, which was always the stronger one:
one application's agents, conversations, secrets and transcripts are
invisible to another's because each is its own account, scoped by
`user_id`. What the deployment spends is shared by all of them and bounded
only by the fleet ceiling.

## Addendum — 2026-10-14: the provisioner's key is an admin key (#2660)

*Consequences* says the provisioner's admin key is controlled by keeping it
in one place. That control did not reach the admin account's other keys:
`:require_admin_api` checked only the role, so every full-scope key an admin
held could call `/api/admin`. That included the 30-day key an OAuth sign-in
mints (ADR 0021) and the key each CLI login mints at `POST /api/auth/token`.

`/api/admin` now requires an **admin key** as well as the admin role: a key
whose scopes are `["full", "admin"]`. Only
`Fountain.Accounts.create_admin_api_key/3` mints one, and its callers are the
admin's Account → API keys page (an **Admin key** box shown only to admins)
and the release task `Fountain.Release.create_admin_key/2`. OAuth,
`POST /api/auth/token` and `POST /api/auth/api-keys` never mint it, and
`create_api_key/3` refuses the scope. An admin key cannot mint another over
the API. The role check stays, so demoting an admin stops their admin keys.
A full-scope key without the scope gets `403 admin_key_required`.

Decision 4 now reads: the provisioner is a dedicated admin account holding
an **admin key** that only the provisioner holds. The key `POST
/api/admin/users` returns for a new account is unchanged: an ordinary
full-scope key on an account with the `user` role.

**Existing provisioner keys stop working.** No key minted before this change
has the scope, and none is upgraded in place. Grandfathering every existing
full-scope key on an admin account would grandfather exactly the OAuth and
CLI keys this closes, and there is no record that tells the provisioner's key
apart from the rest. An operator mints an admin key, puts it where the old one
was, and revokes the old one. The blast radius of an admin key is still every
account on the instance; what changed is that it is now one key.

## Addendum — 2026-10-15: an account an admin opens gets the starter agent

*Superseded the same day:* [0038](0038-onboarding-first-reply.md) retired the
starter agent, so no door plants one. The post-verification steps below still
run, and are now only the first-admin bootstrap.

Decision 1 is extended: an account this route opens starts with the
`starter` agent, the same as a password or OAuth signup
([0038](0038-onboarding-first-reply.md), decision 4). The account is inserted
verified, so it never passed through `verify_email/2` and started with no
agent at all. `create_account_by_admin/3` now runs the same post-verification
steps the other doors run, after its transaction commits and after its own
audit rows ([0013](0013-audit-trail.md)). The agent is recorded as
`agent.created` with the actor `system:onboarding`.

Those steps include the first-admin bootstrap
([0011](0011-self-host-first-admin-bootstrap.md)). It does nothing here: an
admin is making the call, so the instance has had an admin, and the account
stays a `user`, as decision 1 requires. The verification broadcast that
follows reaches nobody, because no session can be waiting on a new account's
verification.

For a platform's provisioner the agent is one more on each application's
account, beside the agents the platform declares. It is an ordinary agent:
the application's key can delete it, and nothing recreates it.

## Addendum — 2026-10-15: fewer gates to skip

The signup access code and the email-domain allowlist named in decision 2,
and the verification broadcast named above, were removed
([0011](0011-self-host-first-admin-bootstrap.md), 2026-10-15 addendum).
Registration's one remaining gate is `REGISTRATION_ENABLED`, which this door
still skips. Nothing else here changes.
