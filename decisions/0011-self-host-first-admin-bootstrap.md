---
type: ADR
title: "Self-host first login without release tasks"
description: "A self-hosted instance's first login needs no release tasks: EMAIL_DELIVERY=none implies auto-verification and FIRST_USER_ADMIN=true promotes the first verified account. Addendum 2026-10-14: registration defaults to auto, open only until the instance has had an admin, and FIRST_USER_ADMIN never re-arms once any admin has existed. Addendum 2026-10-15: account suspension, self-serve email change, the verification waiting room, the signup access code and the email-domain allowlist are removed. Addendum 2026-10-15 (mail): mail is optional and SMTP-only; an unset SMTP_HOST means mail is off, which now carries the auto-verification EMAIL_DELIVERY=none used to; EMAIL_DELIVERY and RESEND_API_KEY are no longer read. Addendum 2026-10-15 (first admin): FIRST_USER_ADMIN is removed and the bootstrap is unconditional; Fountain.Release.promote_admin/1 is removed."
tags: [self-host, auth]
status: stable
adr: "0011"
adr_status: "Accepted"
date: 2026-08-04
generated: { by: human:jhgaylor, at: 2026-08-04T21:35:27-04:00 }
---

# 0011 — Self-host first login without release tasks

**Status:** Accepted. Amended 2026-10-14: registration closes after the
first admin, and the bootstrap never re-arms; see the
[addendum](#addendum--2026-10-14-registration-closes-after-the-first-admin).
Amended 2026-10-15: the account controls that policed strangers are
removed; see the
[addendum](#addendum--2026-10-15-the-controls-that-policed-strangers-are-gone).
Amended 2026-10-15 again: mail off is the absence of `SMTP_HOST`, not
`EMAIL_DELIVERY=none`; see the
[addendum](#addendum--2026-10-15-mail-is-optional-and-off-means-no-smtp_host).
Amended 2026-10-15 a third time: the first-admin bootstrap has no switch; see
the [addendum](#addendum--2026-10-15-one-first-admin-path).

## Context

A self-hosted instance's first-login path required two `bin/fountain_server
eval` release tasks before the instance was usable: `verify_email/1` (because
`EMAIL_DELIVERY=none` means the verification link never arrives, while login
still hard-requires `email_verified_at`) and `promote_admin/1` (the only
first-admin path). Deploy tooling had to grow machinery — pods lifted from the
live Deployment spec — to run per-account eval commands, and the getting-started
docs led with it. Both steps guard nothing on the instances that need them:
email verification proves an address can receive mail, which is meaningless on
an instance configured to send none; and the first admin on a single-operator
instance is always the person who just deployed it.

The constraint making this non-obvious: the same codebase runs the hosted
multi-tenant deployment, where auto-verification would weaken signup and
first-user-admin would hand the instance to whoever registers first.

## Decision

Two independent switches, both inert on the hosted deployment:

1. **`EMAIL_DELIVERY=none` implies auto-verification.** `runtime.exs` sets
   `:email_enabled false` in that branch (default `true`); registration then
   stamps `email_verified_at` at creation and the registration responses say
   "you can sign in" instead of "check your email". No new variable — the
   existing opt-out already declares that delivery is impossible.

2. **`FIRST_USER_ADMIN=true` promotes the first verified account.** Opt-in,
   default off. The grant fires on *verification*, not registration, so it
   always lands on a login-capable account and stays orthogonal to how the
   instance handles email. It is hooked into `Accounts.verify_email/1` (the
   emailed link, the release task, and the auto-verify path all converge
   there) and into the OAuth new-user path (which stamps verification at
   insert). A Postgres advisory xact lock serializes concurrent first
   verifications so exactly one can observe "no admin exists". The promotion
   is audit-recorded as `admin.role.granted` with a nil actor and
   `via: "first_user_admin"`, and is best-effort on the same terms as audit
   logging — a bootstrap failure logs rather than failing the verification.

`Fountain.Release.verify_email/1` and `promote_admin/1` remain as escape
hatches (broken mail provider, lock-out recovery, instances that keep the
switch off), but stop being part of the documented first-login path.

## Consequences

- A self-hoster sets `FIRST_USER_ADMIN=true` (and typically
  `EMAIL_DELIVERY=none`), registers, and has a verified admin account — the
  deploy tooling's `verify-email` / `promote-admin` recipes and the
  first-login doc's failure-mode tables become unnecessary.
- `docker-compose.yml` defaults the switch **on** (the app default stays
  off): compose is the single-operator quickstart, and its posture already
  optimizes for first run (`EMAIL_DELIVERY=none` by default). Other deploy
  methods opt in explicitly.
- An internet-reachable instance with `FIRST_USER_ADMIN=true` and no admin
  yet gives admin to whoever verifies first. Accepted: the switch is opt-in,
  operators register immediately after standing up an instance, and the
  declared-email alternative below remains buildable if this proves wrong.
- With `EMAIL_DELIVERY=none`, a forgotten password is unrecoverable in-app
  (no reset email). This was already true; the boot-time notice now says it
  plainly instead of pointing at `verify_email/1`.
- Accounts created under `EMAIL_DELIVERY=none` keep `email_verified_at` if
  the operator later configures real mail — verification timestamps no longer
  prove an address ever received anything on instances that have used this
  mode.

## Alternatives considered

- **`BOOTSTRAP_ADMIN_EMAIL=<addr>`** (Grafana/Keycloak pattern) — no
  first-to-register window, but reintroduces coordination between config and
  signup: the deploy has to know the admin's address before the admin exists,
  and a typo strands the instance adminless again.
- **Setup wizard at `/setup` while no admin exists** — best UX, most surface:
  a new unauthenticated route, its own rate-limit/abuse story, and layout
  work, for a flow that runs once per instance.
- **First *registered* (not verified) user is admin** — simpler, but grants
  admin to an account that may never be able to log in, and couples the two
  switches: correct only when auto-verification is also on.
- **Keep release tasks, improve tooling** — the status quo; leaves every
  deploy method (compose, k8s, bare release) to reinvent eval-pod machinery
  the app can obsolete in two branches.

## Addendum — 2026-10-14: registration closes after the first admin

A decisions review found that a default install was open to strangers. The
compose defaults (`REGISTRATION_ENABLED=true`, `EMAIL_DELIVERY=none`,
`FIRST_USER_ADMIN=true`) let anybody who found the instance register,
self-verify and receive the starter agent, which runs on the platform
inference keys when the account has none ([0038](0038-onboarding-first-reply.md)).
Credits were removed on 2026-10-12, so nothing caps what such an account
spends. The "operators register immediately" argument in Consequences
covered who became admin; it did not cover everybody who registered after.

What changes:

1. **`REGISTRATION_ENABLED` has three states.** Unset, blank or `auto` (the
   new default, in the app and in compose) leaves self-registration open
   only until the instance has had an admin, then refuses it. `true` is the
   operator's explicit choice to keep it open for everyone, and the access
   code and email-domain list apply as before. `false` closes it from the
   start. Any other value refuses to boot. Admin account creation
   ([0064](0064-an-admin-opens-accounts-for-a-platform.md),
   `POST /api/admin/users`) is unaffected.
2. **`FIRST_USER_ADMIN` never re-arms.** The bootstrap checked "no admin
   exists", so demoting or deleting the last admin handed the next verified
   account the instance. It now checks "no admin has ever existed":
   `Accounts.admin_bootstrapped?/0` is true while an account holds the role
   or while `admin_audit_events` holds an `admin.role.granted` row. That row
   is the durable signal because every route that grants the role writes
   it (this bootstrap, `Fountain.Release.promote_admin/1`, the admin UI and
   the admin API), the retention pruner never prunes the table (#452), and
   it has no foreign key to `users`, so a deleted admin's grant outlives the
   account. A new column or settings table would hold the same bit with a
   migration and a second writer to keep in step. The cost: an instance
   whose last admin is gone recovers through
   `Fountain.Release.promote_admin/1`, which is what that task is for.
3. **Verification side effects run after the registration commits.** The
   `EMAIL_DELIVERY=none` auto-verify called `verify_email/1` inside the
   registration transaction, so `auth.email.verified`, the bootstrap's
   `admin.role.granted` and the starter agent's `agent.created` were all
   written inside it, against [0013](0013-audit-trail.md). Registration now
   inserts the row already verified and runs the same steps as every other
   verification route after the commit. The bootstrap's own transaction
   holds only the advisory lock, the check and the role update; the grant is
   audited after it commits. The OAuth new-user path's bootstrap moved
   after its transaction too.

The original "operators register immediately" acceptance still holds for
the first admin. It no longer has to hold for everybody after.

## Addendum — 2026-10-15: the controls that policed strangers are gone

Fountain is one operator's instance and that operator's own apps; it is no
longer sold as a service (2026-10-12). Four account controls existed to
police strangers on a shared instance, and with `REGISTRATION_ENABLED=auto`
closing self-registration once the operator has an account, there are no
strangers left for them to police. They are removed:

1. **Account suspension** (#287): `Accounts.suspend_user/2`, the suspension
   gates on launch, wake, every turn, login, API keys and the OAuth
   provider, `POST /api/admin/users/{id}/suspend`, the admin console's
   button and badge, and the suspended/unsuspended emails. An operator who
   wants someone gone deletes the account; it is the operator's own
   instance, so there is nobody else to appeal to. `users.suspended_at`
   is unmapped and dropped one release later.
2. **Self-serve email change** (#448): `POST /api/auth/email`,
   `POST /api/auth/email/confirm`, the `/account/security` form and its
   confirmation link and notices. Password change stays.
3. **The verification waiting room** (#533): `/auth/verify-pending`. Browser
   login now refuses an unverified account after the password checks, with
   a message on the login page pointing at the emailed link and at
   "Resend verification email", and issues no session; GitHub sign-in into
   an unverified linked account is refused the same way. The emailed link
   (`/users/confirm/:token`) still verifies and signs the user in, and the
   JSON flow (`POST /api/auth/verify`) is unchanged.
4. **`REGISTRATION_ALLOWED_EMAIL_DOMAINS` and `REGISTRATION_ACCESS_CODE`**
   (#2436). `REGISTRATION_ENABLED` is the one registration control, with
   the three states of the 2026-10-14 addendum. Point 1 of that addendum
   ("the access code and email-domain list apply as before") no longer
   holds. An instance that sets either variable boots and ignores it.

What stays: registration's `auto` default, the first-admin bootstrap that
never re-arms, GitHub login, the JSON register/verify/forgot/reset flows,
device auth, the Fountain OAuth provider, admin account creation
([0064](0064-an-admin-opens-accounts-for-a-platform.md)), role changes,
account deletion and its confirmation email.

## Addendum — 2026-10-15: mail is optional, and off means no `SMTP_HOST`

Decided by the maintainer. Decision 1 tied auto-verification to an explicit
opt-out, `EMAIL_DELIVERY=none`, because production refused to boot with no
mail configured: a silent fallback had dead-ended signup (#223). That
refusal made mail a decision every operator had to take before a first boot,
when the instance it guards is one operator's own, and the opt-out already
said what the refusal was protecting against.

What changes:

1. **Mail is off when `SMTP_HOST` is unset or blank.** Production boots,
   `runtime.exs` sets `:email_enabled false`, registration auto-verifies as
   decision 1 describes, and a notice on stderr says that mail is off because
   `SMTP_HOST` is not set and that password reset cannot be delivered. The
   boot refusal is gone. `EMAIL_FROM` is still required when `SMTP_HOST` is
   set.
2. **SMTP is the only adapter.** `Swoosh.Adapters.Resend` and
   `RESEND_API_KEY` are removed; Resend and most hosted providers also offer
   SMTP. With no HTTP adapter, Swoosh's API client is set to `false`.
3. **`EMAIL_DELIVERY` is no longer read.** Unset `SMTP_HOST` is the same
   state, so a leftover `EMAIL_DELIVERY=none` is ignored quietly. The
   compose, Kubernetes and Fly files keep setting it while they pin v0.24.0,
   which refuses to boot without it, and drop it once the pin moves past.
   A deployment that still sets `RESEND_API_KEY` gets one warning at boot,
   the treatment the retired inference keys got
   ([0075](0075-no-deployment-paid-inference.md)), because it had mail on
   before the upgrade and has it off after.
4. **The mail Fountain sends** is account verification, password reset and
   the account-deleted confirmation ([0009](0009-account-deletion-and-export.md)),
   each a durable Oban job on the `mailer` queue. Password reset moved from
   an unsupervised task to a job that signs its token, with the user's
   current `session_version`, when it runs. The vault-secret expiry notice
   and `Fountain.Workers.SecretExpirySweeper` are removed; `expires_at` on a
   vault secret stays as owner-recorded metadata.

Everything else in decision 1 and its consequences holds with "mail off" in
place of `EMAIL_DELIVERY=none`, including the trade it names: with mail off a
forgotten password is not recoverable in-app.

## Addendum — 2026-10-15: one first-admin path

Decided by the maintainer. Decision 2 made the bootstrap opt-in because the
same codebase ran a hosted multi-tenant deployment, where it would have handed
the instance to whoever registered first. That deployment is gone
(2026-10-12), and `REGISTRATION_ENABLED=auto` (the 2026-10-14 addendum)
already closes self-registration once an admin exists. A switch that every
install sets the same way is a setting to get wrong, and a second first-admin
path, `Fountain.Release.promote_admin/1`, existed for the installs that left
it off.

What changes:

1. **The first account to become verified on an instance that has never had
   an admin becomes the admin, always.** `FIRST_USER_ADMIN` is no longer read.
   The rest of decision 2 holds: the advisory lock, the "ever had an admin"
   check of the 2026-10-14 addendum, the audit record (`admin.role.granted`,
   nil actor, `via: "first_user_admin"`) and best-effort failure. The suite
   turns it off in `config/test.exs` (`:first_admin_bootstrap`), because every
   test's database is an instance that has never had an admin; that key is
   not read from the environment.
2. **Promotion stays on verification, not registration.** An unverified
   account cannot sign in, and if it held the role, `admin_bootstrapped?/0`
   would close `:auto` registration and leave an instance whose only admin is
   an account nobody can use. Every door that verifies runs the bootstrap
   after its own commit: the emailed link, `Fountain.Release.verify_email/1`,
   the mail-off auto-verify at registration, and a new GitHub identity
   (`Accounts.upsert_oauth_user/3`, verified at insert). An account an admin
   opens ([0064](0064-an-admin-opens-accounts-for-a-platform.md)) runs it as
   a no-op, since its creator is an admin. A returning or linked OAuth
   identity does not verify anything and does not run it.
3. **`Fountain.Release.promote_admin/1` is removed**, with its documentation.
   An instance that has an admin grants the role from `/admin/users` or
   `POST /api/admin/users/{id}/role`. `Fountain.Release.create_admin_key/2`
   stays.

Consequences:

- **An existing instance that never had an admin promotes at its next
  verification.** On upgrade, an instance that ran with the switch off and
  has no admin hands the role to the next account to verify. Already-verified
  accounts are not promoted retroactively. An operator in that state registers
  or verifies their own account first, or sets `REGISTRATION_ENABLED=false`
  before upgrading.
- **Losing every admin has no release task to recover it.** The bootstrap
  never re-arms, by the 2026-10-14 addendum, and the admin surfaces refuse to
  delete the caller or (over the API) demote them. An operator who still gets
  there grants the role on the running node, for example
  `bin/fountain_server rpc 'Fountain.Accounts.update_user_role(Fountain.Accounts.get_user_by_email("you@example.com"), "admin", actor: "system:release_task")'`.
  That is rare enough not to need a named task.
- Compose, Fly and the Kubernetes guide pin v0.25.0, which still reads
  `FIRST_USER_ADMIN`, so compose and Fly keep setting it until the pin moves
  past v0.25.0, the treatment `EMAIL_DELIVERY` got above.

