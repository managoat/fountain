# Sentry

**Optional, and inert until you opt in.** With no DSN set, the SDK sits there
and does nothing. No account, no events, and nothing leaves your instance.

## Summary

| | |
|---|---|
| Required | No. |
| Provider | sentry.io, or any service that speaks the Sentry API, such as GlitchTip. |
| Env vars | `SENTRY_DSN`, `SENTRY_ENVIRONMENT` |
| Rate limit | 20 events each minute. |
| Without it | The SDK is inert, and nothing leaves the instance. |

## The provider side

Create a project on [sentry.io](https://sentry.io), with Elixir as the
platform, and take its DSN. Any endpoint that speaks the Sentry API works, so
use GlitchTip for a stack you host yourself.

## Env vars

| Variable | Default | Effect |
|---|---|---|
| `SENTRY_DSN` | — | Turns the reports on. Sentry receives each crash with a stack trace, groups them, and holds them to 20 events each minute. That includes a crash that never touches a web request. |
| `SENTRY_ENVIRONMENT` | The build env. | The environment tag on an event. |
| `FOUNTAIN_BUILD_SHA` | Set by the image build for a release image, or by the deployment for a main-line image. | Matches an event to a release. "This started with `sha-…`". |

Fountain is deliberately conservative about what it reports.
`send_default_pii` is off, so it attaches no cookie, no user IP and no request
body. This app holds tenant secrets, and nothing the SDK gathers on its own
must ride along.

## Crons, an alert when a scheduled job stops

Sentry Monitors, which Sentry calls Crons, catch a failure that a Prometheus
alert often misses. A backup job stops without a sound, and nobody notices.
Fountain's own deployment uses the pattern below for its nightly `pg_dump`,
and it works for any scheduled job.

- The job **verifiably succeeds**, which means the upload confirms it and not
  merely attempts it. Ping the check-in URL that the DSN gives you.

    ```
    curl -fsS -m 10 "https://<sentry-host>/api/<project-id>/cron/<monitor-slug>/<public-key>/?status=ok"
    ```

- The first check-in creates the monitor. Then set its schedule and a grace
  period in the Sentry UI. That arms the alert for a *missed* run, which is
  the point.
- Keep the ping best-effort. A Sentry outage must never fail a backup that
  worked.

## Verify

Set the DSN, restart, then cause any error. It appears in the project within
seconds, tagged with environment and release. Unset the DSN and nothing
appears.

## Limits

**Fountain sends nothing until you set a DSN.** Unset, the SDK is inert. It
buffers nothing, so there is no backlog to flush when you turn it on.

**Fountain withholds tenant data on purpose.** It attaches no cookie, no user
IP and no request body, because this app holds other people's secrets. So a
report carries less context than a stock Sentry integration would.

## Related

- [Observability](../guides/operate/observability.md), and the alert
  pack.
- [Back up and restore](../guides/operate/back-up-and-restore.md), which uses
  the Crons pattern above.
- [Services Fountain uses](index.md).
