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

**Status:** Accepted, 2026-10-13. Built: `POST /api/admin/users`,
`Fountain.Accounts.create_account_by_admin/3`, `User.admin_created_changeset/2`.

## Context

The maintainer's home platform (home-cloud) gives each of its applications
conversational agents, the way it gives them a database: an application
declares agents, and a provisioner makes them. Each application should be its
own tenant here, so one application's agents, conversations, secrets and
transcripts are invisible to another's, because each is its own account scoped
by `user_id`. (A second reason when this was decided, a per-account credit
ledger as a spending cap, went with credits in #2609; what the deployment
spends is shared by all accounts and bounded only by the fleet ceiling.)

Nothing could open an account without a person. Registration is the public
door, gated by `REGISTRATION_ENABLED` and, for a password signup, an emailed
link; neither is something a provisioner can pass. The admin API (#527) could
not open an account.

## Decision

1. **`POST /api/admin/users`** opens an account from `{email, key_name?}`. It
   is verified at creation, with no password, so nobody signs in as it. It
   comes with one full-scope API key, returned once in `api_key`. Its role is
   always `user`. After its transaction commits and its audit rows are
   written, it runs the same post-verification steps as every other door;
   the only one is the first-admin bootstrap
   ([0011](0011-self-host-first-admin-bootstrap.md)), which does nothing here
   because an admin is making the call.
2. **It sits behind the admin pipeline** (`:require_full_scope` and
   `:require_admin_api`). `REGISTRATION_ENABLED` does not apply: it guards the
   public door, and this is the operator's.
3. **It is audited three ways:** `account.created_by_admin` and
   `api_key.created` on the new account, both naming the admin, and
   `admin.account.created` as an administrative row
   ([0013](0013-audit-trail.md)).
4. **The platform's provisioner is a dedicated admin account,** not a
   person's, holding an admin key that only the provisioner holds.

`/api/admin` requires an admin key as well as the admin role: a key whose
scopes are `["full", "admin"]` (#2660). Only
`Fountain.Accounts.create_admin_api_key/3` mints one; its callers are the
Admin key box in the API keys section of `/account`, shown only to admins, and
the release task `Fountain.Release.create_admin_key/2`. OAuth sign-in
([0021](0021-oauth-for-first-party-apps.md)), `POST /api/auth/token` and
`POST /api/auth/api-keys` never mint it, `create_api_key/3` refuses the scope,
and an admin key cannot mint another over the API. The role check stays, so
demoting an admin stops their admin keys. A full-scope key without the scope
gets `403 admin_key_required`. The key `POST /api/admin/users` returns for a
new account is an ordinary full-scope key on a `user` account.

## Consequences

- **The provisioner's key is an admin key.** It can do anything the admin API
  does to any account on the instance: list, show, change the role of and
  delete it. A narrower provisioner scope that could act only on the accounts
  it opened, and pin an account to particular sandbox providers, was drafted
  and declined for the smaller change. The platform keeps the key in its
  secret store, synced only into the provisioner's namespace. Requiring the
  admin scope means that key is the only one on the admin account that
  reaches `/api/admin`; without it, the 30-day key an OAuth sign-in mints and
  each CLI login's key could too.
- **Provisioner keys minted before #2660 stopped working.** No earlier key had the
  scope and none was upgraded in place: grandfathering every full-scope key
  on an admin account would have grandfathered exactly the OAuth and CLI keys
  the scope closes, and nothing told the provisioner's key apart from them.
  An operator mints an admin key, puts it where the old one was, and revokes
  the old one.
- **An application's own key is a full-scope tenant key,** so it can make
  agents on any provider the instance enables. The platform applies the
  agents it declares with the provider it wants; it does not stop the
  application doing otherwise.
- **Removing an application is the admin delete.** There is no other route
  that undoes what this opens; account suspension was removed
  ([0011](0011-self-host-first-admin-bootstrap.md)).

## History

- 2026-10-13 — Accepted and built: `POST /api/admin/users` opens a verified, passwordless `user` account with one full-scope key.
- 2026-10-14 — Credits and the per-account sandbox limit removed (#2609); the account-per-application decision stands on isolation alone.
- 2026-10-14 — `/api/admin` requires an admin key (`["full", "admin"]`) as well as the role (#2660); existing provisioner keys stop working.
- 2026-10-15 — An account this route opens gets the starter agent; superseded the same day when [0038](0038-onboarding-first-reply.md) retired the starter agent, leaving the first-admin bootstrap as the only post-verification step.
- 2026-10-15 — The registration access code, email-domain list, verification broadcast and account suspension removed ([0011](0011-self-host-first-admin-bootstrap.md)); `REGISTRATION_ENABLED` is the one gate this door skips.
