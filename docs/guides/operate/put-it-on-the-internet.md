# Put it on the internet

This guide shows you how to expose an instance safely, once it runs locally.

The compose file publishes port 4000 with no TLS. Terminate TLS in front of it
with Caddy, with nginx, or with a tunnel.

## Before you start

Register your own account first. While no admin exists, the first verified
account takes the role. An open instance with no admin is an instance anybody
can take.

## Set two variables

- `PUBLIC_URL`, the external URL, with the scheme. It builds the verification
  links, and Fountain passes it to each sandbox.
- `TRUSTED_PROXIES`, your proxy's address range. Without it, the rate limits
  for each IP collapse into one bucket keyed on the proxy.

Registration is open until the instance has an admin, and closed after. If
you set `REGISTRATION_ENABLED=true` to let other people sign up, also set
`REGISTRATION_ALLOWED_EMAIL_DOMAINS` or `REGISTRATION_ACCESS_CODE`. Somebody
will find an instance on the public internet that has registration open.

## What an https PUBLIC_URL starts

An `https://` `PUBLIC_URL` also starts three more things. It starts the HTTPS
redirect. It starts HSTS, for one year, over subdomains as well, and not
preloaded. It sets the `secure` flag on the session cookie.

Fountain derives all three from the scheme, and you do not set them one by
one. None of them can be on for an `http://` instance. A browser never sends a
cookie marked secure back, and the redirect would point at a port that serves
nothing.

Do you terminate TLS in front of Fountain? Then make sure your proxy sets
`X-Forwarded-Proto`. The redirect reads it. Without it, each request looks
like plain http, and the redirect loops.

`CHECK_ORIGIN_EXTRA` adds the origins that can open a LiveView websocket, as a
comma-separated list. Fountain always includes your own host. Add to this only
for something like a preview environment on a different domain.

## Verify it worked

```bash
curl -sSI https://your-fountain.example.com/health/ready | head -1
```

Then sign in through the public URL. A redirect loop in the browser means the
proxy does not set `X-Forwarded-Proto`.

## If it did not work

Read
[Pods restart or never go ready](../../troubleshooting/pods-restarting.md) for
how probes and the redirect interact. That is the other common surprise here.
`/health` and `/health/ready` are exempt from the https redirect, because
probes reach the pod over plain http.

## Related

- [Deploy an instance](deploy.md).
- [Observability](observability.md), and the health endpoints.
- [Configuration reference](../../configuration.md).
