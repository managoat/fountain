---
type: ADR
title: "An admin opens accounts over the API for a platform built on the instance"
description: "POST /api/admin/users opens a verified, passwordless account and returns one full-scope key for it, so a platform's provisioner can make one account per application. It sits behind the existing admin pipeline; registration's gates don't apply. The provisioner holds a dedicated admin account's full-scope key, and that key's blast radius is every account on the instance."
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
