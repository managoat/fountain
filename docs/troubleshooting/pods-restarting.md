# Pods restart or never go ready

This guide shows you how to tell the probe layout at work from a real failure.

Most symptoms that look like a Kubernetes fault are the first of those.

## What is at work by design

**Liveness checks the process and nothing else.** A restart does not fix
Postgres, so `/health` always answers 200 while the BEAM runs.

**Readiness checks Postgres.** A pod that cannot reach its database answers
503 on `/health/ready`. Kubernetes drains it from the Service and does not
kill it, and the pod recovers on its own. **NotReady through a database blip,
with no restarts, is the system at work.** That 503 takes about 3 seconds to
answer, so give an external check a timeout above that.

**The startup probe holds the other two off for up to 150 seconds.**
Migrations run at boot, before the listener opens. A slow migration is not a
dead pod.

## Failures that are real

**A boot loop.** Migrations cannot reach the database at all, and the
container fails before it opens a listener. Check `DATABASE_URL`, then check
the database. Read [Connect a database](../guides/operate/deploy.md#connect-a-database).

**A 301 where a probe expected 200.** On an `https://` instance, each path
redirects http to https, *except* `/health` and `/health/ready`. Those two are
exempt because probes reach the pod over plain http. Point a check at any
other path and it scores the redirect as a failure. Point your checks at the
two health endpoints only.

**A redirect loop in the browser.** The proxy in front does not set
`X-Forwarded-Proto`. Each request then looks like http, and Managoat redirects
it to itself. Fix the proxy header. Read
[Put it on the internet](../guides/operate/deploy.md#put-it-on-the-internet).

**A rollout that never completes.** The startup probe usually fails, which
means migrations that cannot finish. The readiness probe can also fail,
against a database problem that is older than the deploy. Read
[Upgrade an instance](../guides/operate/upgrade.md).

## Related

- [Observability](../guides/operate/observability.md), for what each
  health endpoint is for.
- [Deploy on Kubernetes](../guides/operate/hosts.md#kubernetes).
- [Architecture](../architecture.md), for which component owns which symptom.
