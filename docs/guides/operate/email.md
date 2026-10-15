# Configure email

This guide shows you how to choose a mail setting. Fountain makes you decide.
It is not an optional extra.

Fountain refuses to start in production without one. A verification email that
Fountain throws away leaves signup at a dead end, with no error to see.

## Choose one of three

| Setting | Effect |
|---|---|
| `RESEND_API_KEY` | Resend delivers the mail. |
| `SMTP_HOST` (with `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`) | Any SMTP server. The port defaults to 587 with STARTTLS. Omit the username for a relay that wants no authentication. |
| `EMAIL_DELIVERY=none` | No email. An account self-verifies at registration (ADR 0011). |

`EMAIL_FROM` sets the sender in the first two modes.

## What each choice costs you

A password reset also needs mail that works. With `EMAIL_DELIVERY=none`, the
one route back into a locked-out account is the database.

That is the trade the mode's boot notice warns you about. It is usually the
right trade for a one-operator instance, where you can run a release task.

The [mail integration guide](../../integrations/mail.md) covers the provider
side. It has domain verification, and what each mode means for signup.

## Verify it worked

Request a password reset for your own account and watch for the reset mail.
Registration is usually closed once the instance has an admin. To test the
verification mail too, open registration for a moment and register a
throwaway account. If no mail arrives, verify the account by hand. Treat that
as a mail setup that failed, and not as a fix.

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.verify_email("them@example.com")'
```

## If it did not work

The provider accepts mail from a domain that nobody verified. SPF, DKIM and
DMARC then fail downstream, and the receiver rejects the message or files it
as spam. Read
[Nobody can log in](../../troubleshooting/nobody-can-log-in.md).

## Related

- [Mail integration guide](../../integrations/mail.md), for the provider side.
- [Run a release task](run-a-release-task.md), for `verify_email/1`.
- [Nobody can log in](../../troubleshooting/nobody-can-log-in.md).
