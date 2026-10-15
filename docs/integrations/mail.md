# Mail

Fountain sends mail over SMTP, or sends none. Set `SMTP_HOST` and mail is on.
Leave it unset and mail is off, which is a complete mode rather than a
broken one: an account verifies itself at registration, and Fountain says at
boot that mail is off.

Off is right for an instance only you use. Set SMTP before you invite anyone
else, because a password reset needs mail.

## Summary

| | |
|---|---|
| Required | No. |
| Options | Any SMTP server, or off. |
| Env vars | `SMTP_HOST` and the other `SMTP_*`, and `EMAIL_FROM`. |
| Without it | Mail is off. Accounts self-verify, and nobody can reset a password in-app. |

## SMTP

| Variable | Default | Effect |
|---|---|---|
| `SMTP_HOST` | — | Turns mail on, through this server. |
| `SMTP_PORT` | `587` | |
| `SMTP_USERNAME` | — | Omit it for a relay that wants no authentication. |
| `SMTP_PASSWORD` | — | |
| `SMTP_TLS` | `always` | STARTTLS by default. Use `never` for a relay on a trusted network that does not offer it. |
| `EMAIL_FROM` | — | The From address. Required with `SMTP_HOST`: the app refuses to boot without it, because a provider that checks SPF and DKIM rejects mail from a domain you do not control. |

Any SMTP server works: your own relay, or a hosted provider's SMTP endpoint.
Resend is one example. Its endpoint is `smtp.resend.com` on port 587, with
the username `resend` and an API key as the password.

On the provider side, verify the domain you send from before you point
`EMAIL_FROM` at it. That means the SPF, DKIM and DMARC records. Mail from a
domain nobody verified does not reach an arbitrary inbox.

## Off

Leave `SMTP_HOST` unset, or blank. Fountain prints a notice to stderr at boot
and sends nothing.

An account created with email and password self-verifies at registration. A
verification link that can never arrive gates nothing (ADR 0011). A password
reset cannot be delivered, so the one route back into a locked-out account is
the operator.

An OAuth signup skips verification anyway, so [GitHub OAuth](github-oauth.md)
with mail off is a coherent minimal setup.

## What sends mail

| Email | When | Link |
|---|---|---|
| Account verification | Registration with email and password, and "Resend verification email". | Valid 24 hours. |
| Password reset | "Forgot password", in the browser or `POST /api/auth/forgot`. | Valid 1 hour. |
| Account deleted | A verified account is deleted. | None. |

Each one is a background job on the `mailer` queue, tried up to five times
when the SMTP server refuses it or cannot be reached.

## Verify

Request a password reset for your own account, then confirm that the reset
email arrives. Registration is usually closed once the instance has an admin,
so to test the verification email, open it for a moment and register a
throwaway account. Check the spam folder, which is where mail from a domain
nobody verified lands.

On a live instance, the boot log says when mail is off.

## Upgrading from Resend's API or `EMAIL_DELIVERY`

In releases up to v0.24, `RESEND_API_KEY` sent mail through Resend's HTTP API, and
`EMAIL_DELIVERY=none` turned mail off. Fountain reads neither now, and warns
at boot when one is set. To keep sending through Resend, use its SMTP
endpoint above. To keep mail off, remove both; that is already the default.

## Related

- [Configure email](../guides/operate/deploy.md#configure-email), the operator guide.
- [Nobody can log in](../troubleshooting/nobody-can-log-in.md), which is
  usually this.
- [Services Fountain uses](index.md).
