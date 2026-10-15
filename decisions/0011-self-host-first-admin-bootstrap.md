---
type: ADR
title: "Self-host first login without release tasks"
description: "A self-hosted instance's first login needs no release task: with mail off, accounts verify themselves, the first verified account becomes admin, and registration closes once an admin has existed."
tags: [self-host, auth]
status: stable
adr: "0011"
adr_status: "Accepted"
date: 2026-08-04
generated: { by: human:jhgaylor, at: 2026-08-04T21:35:27-04:00 }
---

# 0011 — Self-host first login without release tasks

**Status:** Accepted, 2026-08-04.

## Context

A self-hosted instance's first login once required two `bin/fountain_server
eval` release tasks: `verify_email/1`, because with no mail the verification
link never arrives while login requires `email_verified_at`, and
`promote_admin/1`, the only first-admin path. Deploy tooling grew machinery
(pods lifted from the live Deployment spec) to run per-account eval commands,
and the getting-started docs led with it. Both steps guard nothing on the
instances that need them: email verification proves an address can receive
mail, which is meaningless on an instance that sends none, and the first admin
of a single-operator instance is the person who just deployed it.

When this was first decided the same codebase also ran a hosted multi-tenant
deployment, so both behaviors were opt-in switches. That deployment is gone
(2026-10-12), and Managoat is one operator's instance and that operator's own
apps.

## Decision

1. **Mail is optional; with mail off, accounts verify themselves.** Mail is
   off when `SMTP_HOST` is unset or blank. Production still boots;
   `runtime.exs` sets `:email_enabled false`, registration stamps
   `email_verified_at` at creation and the responses say "you can sign in"
   instead of "check your email", and a notice on stderr says mail is off and
   password reset cannot be delivered. `EMAIL_FROM` is required when
   `SMTP_HOST` is set. SMTP is the only adapter (Resend and most hosted
   providers offer it); Swoosh's API client is `false`. `EMAIL_DELIVERY` is
   not read, and a leftover `RESEND_API_KEY` gets one warning at boot, because
   that deployment had mail on before the upgrade and has it off after. The
   mail Managoat sends is account verification, password reset and the
   account-deleted confirmation ([0009](0009-account-deletion-and-export.md)),
   each a durable Oban job on the `mailer` queue; password reset signs its
   token, with the user's current `session_version`, when the job runs.

2. **The first account to become verified on an instance that has never had
   an admin becomes the admin.** There is no switch. The grant fires on
   verification, not registration, so it always lands on an account that can
   sign in; an unverified admin would close `auto` registration and leave an
   instance whose only admin nobody can use. Every door that verifies runs the
   bootstrap after its own commit: the emailed link,
   `Fountain.Release.verify_email/1`, the mail-off auto-verify at
   registration, and a new GitHub identity (`Accounts.upsert_oauth_user/3`,
   verified at insert). An account an admin opens
   ([0064](0064-an-admin-opens-accounts-for-a-platform.md)) runs it as a
   no-op. A returning or linked OAuth identity verifies nothing and does not
   run it. A Postgres advisory xact lock serialises concurrent first
   verifications; the bootstrap's transaction holds only the lock, the check
   and the role update, and the grant is audited after it commits as
   `admin.role.granted` with actor `system:first_user_admin`
   ([0013](0013-audit-trail.md)). It is best-effort on the same terms as audit
   logging: a failure logs rather than failing the verification. The suite
   turns it off in `config/test.exs` (`:first_admin_bootstrap`, not read from
   the environment), because every test database has never had an admin.

3. **The bootstrap never re-arms.** It checks "no admin has ever existed":
   `Accounts.admin_bootstrapped?/0` is true while an account holds the role or
   while the audit trail holds an `admin.role.granted` row. Every route that
   grants the role writes that row, `admin.*` rows are never pruned (#452),
   and the row has no foreign key to `users`, so a deleted admin's grant
   outlives the account. A column or settings table would hold the same bit
   with a migration and a second writer to keep in step.

4. **Registration closes after the first admin.** `REGISTRATION_ENABLED` is
   the one registration control. Unset, blank or `auto` (the default, in the
   app and in compose) leaves self-registration open only until the instance
   has had an admin. `true` keeps it open for everyone; `false` closes it from
   the start; any other value refuses to boot. Admin account creation
   ([0064](0064-an-admin-opens-accounts-for-a-platform.md)) is unaffected.

5. **Verification side effects run after the registration commits.**
   Registration inserts the row already verified and then runs the same steps
   as every other verification route, so `auth.email.verified` and the
   bootstrap's grant are not written inside a transaction.

6. **Login refuses an unverified account.** Browser login refuses it after
   the password checks, with a message pointing at the emailed link and
   "Resend verification email", and issues no session; GitHub sign-in into an
   unverified linked account is refused the same way. The emailed link
   (`/users/confirm/:token`) verifies and signs the user in; the JSON flow
   (`POST /api/auth/verify`) is the same.

`Fountain.Release.verify_email/1` and `create_admin_key/2` remain as escape
hatches. There is no release task to promote an admin: an instance that has
one grants the role from `/admin/users` or `POST /api/admin/users/{id}/role`.

## Consequences

- A self-hoster deploys, registers, and has a verified admin account. The
  deploy tooling's `verify-email` / `promote-admin` recipes and the first-login
  docs' failure-mode tables are unnecessary.
- An internet-reachable instance with no admin yet gives admin to whoever
  verifies first. Accepted: operators register immediately after standing up
  an instance, and `auto` registration means nobody else can register after.
- An existing instance that never had an admin promotes at its next
  verification after upgrading; already-verified accounts are not promoted
  retroactively. An operator in that state verifies their own account first,
  or sets `REGISTRATION_ENABLED=false` before upgrading.
- Losing every admin has no named recovery task. The admin surfaces refuse to
  delete the caller or (over the API) demote them. An operator who still gets
  there grants the role on the running node, for example
  `bin/fountain_server rpc 'Fountain.Accounts.update_user_role(Fountain.Accounts.get_user_by_email("you@example.com"), "admin", actor: "system:release_task")'`.
- With mail off, a forgotten password is not recoverable in-app.
- Accounts verified while mail was off keep `email_verified_at` if the
  operator later configures mail, so a verification timestamp does not prove
  an address ever received anything.
- Deploy files that pin an image which still reads `FIRST_USER_ADMIN` or
  `EMAIL_DELIVERY` keep setting them until the pin moves past that release.
- There are no controls for policing strangers: no account suspension, no
  self-serve email change, no verification waiting room, and no
  `REGISTRATION_ALLOWED_EMAIL_DOMAINS` or `REGISTRATION_ACCESS_CODE` (an
  instance that sets either boots and ignores it). With registration closed
  after the operator's account, there are no strangers left to police; an
  operator who wants someone gone deletes the account. Password change, GitHub
  login, the JSON register/verify/forgot/reset flows, device auth, the
  Managoat OAuth provider, role changes and account deletion stay.

## Alternatives considered

- **`BOOTSTRAP_ADMIN_EMAIL=<addr>`** (Grafana/Keycloak pattern): no
  first-to-register window, but the deploy has to know the admin's address
  before the admin exists, and a typo strands the instance adminless.
- **Setup wizard at `/setup` while no admin exists**: best UX, most surface:
  a new unauthenticated route with its own abuse story, for a flow that runs
  once per instance.
- **First registered (not verified) user is admin**: grants admin to an
  account that may never be able to log in.
- **Opt-in switches (`FIRST_USER_ADMIN`, `EMAIL_DELIVERY=none`)**: what was
  built first, while a hosted deployment shared the codebase. With that
  deployment gone, a switch every install sets the same way is a setting to
  get wrong, and the boot refusal without mail made mail a decision every
  operator had to take before a first boot.
- **Keep release tasks, improve tooling**: leaves every deploy method to
  reinvent eval-pod machinery the app can make unnecessary.

## History

- 2026-08-04 — Accepted: `EMAIL_DELIVERY=none` auto-verifies; opt-in `FIRST_USER_ADMIN` promotes the first verified account; compose defaults it on.
- 2026-10-14 — `REGISTRATION_ENABLED=auto` closes registration after the first admin; the bootstrap checks "ever had an admin" and never re-arms; verification side effects move after the registration commit.
- 2026-10-15 — Account suspension (#287), self-serve email change (#448), the verification waiting room (#533) and the registration domain list and access code (#2436) removed.
- 2026-10-15 — Mail off means no `SMTP_HOST` rather than `EMAIL_DELIVERY=none`; the boot refusal without mail (#223) removed; SMTP the only adapter; the vault-secret expiry notice removed.
- 2026-10-15 — One first-admin path: `FIRST_USER_ADMIN` no longer read, `Fountain.Release.promote_admin/1` removed.
