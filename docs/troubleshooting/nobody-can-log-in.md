# Nobody can log in

This guide walks the chain from the most common cause to the least.

Note the symptom, because it misleads. Managoat accepts the password and the
session is real, but the user never leaves the "check your email" page. That
reads as a broken app, and not as a refused login.

## 1. Did the verification email go anywhere?

The page means the account is unverified, so the instance has mail
configured (`SMTP_HOST`) and the link went nowhere. With mail off, the
default, an account verifies itself at registration and never sees the page.
An account registered while mail was on stays unverified after you turn
mail off.

Verify an account by hand.

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.verify_email("them@example.com")'
```

If that unblocks the account, the problem is mail delivery. Read
[Configure email](../guides/operate/deploy.md#configure-email).

## 2. You configured mail, and nothing arrives

The provider accepts mail from a domain that nobody verified. SPF, DKIM and
DMARC then fail downstream, and the receiver rejects the message or files it
as spam. Read the [mail integration guide](../integrations/mail.md).

## 3. OAuth still works when mail does not

A GitHub sign-in arrives already verified, so it is a way back in while mail
fails.

The reverse also holds. A GitHub outage breaks the button and nothing else.
Password auth still works.

## 4. A password reset needs mail that works

With mail off, a locked-out password account has no self-serve route back.
That is the trade the boot notice warns you about, and the one route left is
a release task.

## 5. 429 responses

The API allows 600 requests each minute for each API key. Before
authentication, every request from one address also counts toward a ceiling
of 6,000 each minute, and refused authentication has its own budget of 600
each minute for each address.

If Managoat rate-limits *everyone* at once behind a proxy, `TRUSTED_PROXIES`
is unset. Each client then shares the proxy's bucket. Read
[Put it on the internet](../guides/operate/deploy.md#put-it-on-the-internet).

## Related

- [Configure email](../guides/operate/deploy.md#configure-email).
- [Run a release task](../guides/operate/run-a-release-task.md), for
  `verify_email/1`.
- [Mail integration guide](../integrations/mail.md).
