# Mail

**You must decide.** Production refuses to boot with no mail setting. A
verification email that Fountain throws away leaves signup at a dead end, with
no error to see. There are exactly three options, and Fountain checks them in
the order below.

## Summary

| | |
|---|---|
| Required | **Yes, as a decision.** Production refuses to boot without one of the three. |
| Options | Resend, any SMTP server, or none. |
| Env vars | `RESEND_API_KEY` *or* `SMTP_*` *or* `EMAIL_DELIVERY=none`, and `EMAIL_FROM`. |
| Precedence | Fountain checks them in the order below. Resend wins when you set several. |
| Without it | Production will not start. |

## Option 1: Resend

| Variable | Effect |
|---|---|
| `RESEND_API_KEY` | [Resend](https://resend.com) delivers the mail. |

On the provider side, verify the domain you send from in Resend before you
point `EMAIL_FROM` at it. That means the SPF, DKIM and DMARC records. A domain
nobody verified will not deliver to an arbitrary inbox.

## Option 2: any SMTP server

| Variable | Default | Effect |
|---|---|---|
| `SMTP_HOST` | — | Chooses SMTP delivery. |
| `SMTP_PORT` | `587` | |
| `SMTP_USERNAME` | — | Omit it for a relay that wants no authentication. |
| `SMTP_PASSWORD` | — | |
| `SMTP_TLS` | `always` | STARTTLS by default. Use `never` for a relay on a trusted network that does not offer it. |

If you also set `RESEND_API_KEY`, Resend wins, because Fountain checks the
options in order.

## Option 3: no email, on purpose

| Variable | Effect |
|---|---|
| `EMAIL_DELIVERY=none` | Turns email off, with a notice on stderr at boot. |

Use it for an OAuth-only instance, or while you evaluate Fountain. An account
created with email and password self-verifies at registration. A verification
link that can never arrive gates nothing (ADR 0011).

A password reset is dead in this mode. The one route back into a locked-out
account is the operator.

## In each mode

| Variable | Default | Effect |
|---|---|---|
| `EMAIL_FROM` | — | The From address, on a domain your provider verified. A real delivery provider needs it, and the app refuses to boot without it. It does not send mail that your provider will reject. |

Here is what sends email today. Account verification, with a 24-hour link.
Password reset, with a 1-hour link.

With `CREDITS_ENABLED` on, two credit emails go out as well. Credits low.
Credits exhausted.

An OAuth signup skips verification, so [GitHub OAuth](github-oauth.md) with
`EMAIL_DELIVERY=none` is a coherent minimal setup.

## Verify

Register a throwaway account, then confirm that the verification email
arrives. Check the spam folder, which is where mail from a domain nobody
verified lands.

On a live instance, the boot logs state the mode Fountain chose.
`EMAIL_DELIVERY=none` prints its notice to stderr. An absent configuration
refuses to boot, and says so.

## Related

- [Configure email](../guides/operate/email.md), the operator guide.
- [Nobody can log in](../troubleshooting/nobody-can-log-in.md), which is
  usually this.
- [Services Fountain uses](index.md).
