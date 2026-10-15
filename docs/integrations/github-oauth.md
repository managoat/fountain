# GitHub OAuth

**Optional.** It adds "Continue with GitHub" to the login and registration
pages. Email and password auth works without it.

## Summary

| | |
|---|---|
| Required | No. |
| Provider | A GitHub OAuth app. |
| Env vars | `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET` |
| Scope requested | `user:email` |
| Callback | `<PUBLIC_URL>/auth/oauth/github/callback` |
| Without it | Email and password auth alone, with no dead-end button. |

## The provider side

Create an OAuth app at
[github.com/settings/developers](https://github.com/settings/developers).

| Field | Value |
|---|---|
| Homepage URL | Your `PUBLIC_URL`. |
| Authorization callback URL | `<PUBLIC_URL>/auth/oauth/github/callback` |

Fountain requests the `user:email` scope.

## Env vars

| Variable | Effect |
|---|---|
| `GITHUB_OAUTH_CLIENT_ID` | From the OAuth app. |
| `GITHUB_OAUTH_CLIENT_SECRET` | From the OAuth app. |

The button renders only when you set `GITHUB_OAUTH_CLIENT_ID`. An instance
with no configuration shows plain email and password auth, and no dead-end
GitHub button.

## Behavior worth knowing

- **Fountain accepts a GitHub-verified email and no other.** It checks the
  address's `verified` flag with GitHub, and it does not trust the primary
  email. A sign-in links to an account that already exists by email, so an
  unverified address set to somebody else's email must not attach to their
  account. Fountain refuses an unverified email with a message that tells the
  user to confirm it on GitHub first.
- An OAuth signup arrives with its email already verified, so Fountain sends
  no verification email. OAuth therefore works on an instance with
  `EMAIL_DELIVERY=none`.
- `REGISTRATION_ENABLED` (including its default, closed once an admin
  exists) and `REGISTRATION_ALLOWED_EMAIL_DOMAINS` apply to an OAuth signup
  as well, and not to the forms alone. A user who already
  exists can still sign in after you close registration.

## Verify

Sign in with the button. The audit log at `/audit` records
`auth.oauth.signup` or `auth.oauth.login`. It records a rejection as
`auth.oauth.rejected`, with the reason.

## Limits

**A GitHub outage breaks the button and nothing else.** Email and password
auth still works, so an instance with both does not depend on GitHub alone.

**The button is all or nothing.** There is no gate for one user or one domain
on who can use it, beyond `REGISTRATION_ALLOWED_EMAIL_DOMAINS`.

## Related

- [Nobody can log in](../troubleshooting/nobody-can-log-in.md), where OAuth is
  the way back in when mail fails.
- [Put it on the internet](../guides/operate/deploy.md#put-it-on-the-internet).
- [Services Fountain uses](index.md).
