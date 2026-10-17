---
type: ADR
title: "The broker runs inside Managoat, with a CA seed that never leaves it"
description: "The egress broker runs only in the Managoat server, as ADR 0019 built it; the standalone remote broker is removed, its variables refuse to boot, and large pinned downloads are avoided rather than proxied faster."
tags: [broker, deployment, security]
status: stable
adr: "0093"
adr_status: "Accepted"
date: 2026-10-17
---

# 0093 — The broker runs inside Managoat, with a CA seed that never leaves it

**Status:** Accepted, 2026-10-17. Supersedes [0091](0091-remote-broker.md).
The removal is built: `broker/`, the private control endpoint and the remote
mode are gone, and the removed variables refuse to boot. Keeping the Codex CLI
download off the broker is built for Sprites (#2914); E2B needs the CLI baked
into its template, which is separate work.

## Context

[0091](0091-remote-broker.md) moved the forward proxy onto a standalone Fly
release that asked home to authorize every HTTP request. What it bought was
download speed. [#2886](https://github.com/managoat/managoat/issues/2886)
measured one 163 MB archive (the Codex CLI package) at a median of 4.65 s
through the home broker against 1.69 s through Fly from a Sprite, and 6.01 s
against 2.59 s from hosted E2B. The limit is home's upload bandwidth, not the
broker code.

What it cost:

- **The remote node held the broker CA seed.** The CA it derives signs a
  certificate for any host, and every sandbox trusts that CA. A compromised
  remote node could impersonate any site to every sandbox, and it also held
  plaintext credentials for every request it admitted.
- **Every request waited on home.** Admission made an authenticated HTTPS call
  to home per HTTP request, including each request inside a CONNECT tunnel,
  and home stayed an availability dependency anyway.
- **A second deployable.** Its own release, CI job, control protocol, event
  queue and failure modes, for one deployment.

The large download that motivated it is avoidable. The Codex CLI is already
in the Sprites image, and Managoat runs that copy instead of downloading a
second one (#2914). The same can hold on E2B by baking it into the template.

## Decision

The broker runs inside the Managoat server and nowhere else, as
[0019](0019-egress-credential-brokerage.md) §8 built it. The `broker/`
release, the `/internal/broker/v1/` control endpoint, `BROKER_MODE` and
`BROKER_CONTROL_TOKEN` are removed.

[0019](0019-egress-credential-brokerage.md)'s floor is unchanged and restated
here because the remote broker was its first exception in placement: every
conversation is brokered; a sandbox holds placeholders, and the credential is
attached at the broker; the provider's network policy allows the sandbox one
host, the broker's, and a release without `BROKER_LISTEN_PORT` and
`BROKER_PROXY_URL` does not boot.

A release with `BROKER_MODE`, `BROKER_CONTROL_TOKEN` or `BROKER_CONTROL_URL`
set refuses to boot and names the variable. Ignored instead, a deployment
still configured for the remote broker would boot and hand new sandboxes
whatever `BROKER_PROXY_URL` still named.

`BROKER_CA_SEED` stays as an optional setting: 32 random bytes, generated
where Managoat runs and given to nothing else. Unset, the seed is still
HKDF-derived from the master key. Setting it lets the CA rotate without the
master key. A changed seed changes the CA, and a sandbox installs the new one
on its next wake, which rewrites the CA, rebuilds the trust store and
re-applies the network floor against the current broker host.

The [transport relay](0094-sandbox-broker-transport-relay.md) stays. Its
reason was never the remote broker: the production broker address was
already an HTTPS endpoint (#2848).

Large downloads are kept off the broker rather than made faster through it.
Only artifacts Managoat pins by hash may be cached or pushed into a sandbox
by Managoat itself; there is no generic npm, PyPI or apt cache.

## Consequences

Payload bytes flow origin → home → sandbox again, so an unpinned large
download is bound by home's upload. A second large artifact that agents fetch
on every provision needs the same treatment as the Codex CLI: in the image,
or pinned by hash and pushed by Managoat.

No process outside Managoat holds the CA seed, the control token or plaintext
credentials. Admission is a local database read again, with no network call.

A deployment that ran the remote broker must, before upgrading, set
`BROKER_PROXY_URL` back to its own broker ingress and unset the removed
variables. Its sandboxes move on their next wake; ones never woken again keep
dialling the old endpoint until it stops, so the remote node should run until
their connections drain.

## Alternatives considered

- **Keep the remote broker, with a fresh seed.** The seed would still have to
  be on the remote node to sign certificates; the impersonation exposure is the
  design, not the seed's origin.
- **A generic package cache at home.** Speeds every download but puts an
  unbounded store of third-party content on the trust path. Pinned artifacts
  only.
- **Allow direct download of large public artifacts.** Breaks 0019's floor.

## History

- 2026-10-17 — Accepted; remote broker, control endpoint and `BROKER_MODE`/`BROKER_CONTROL_*` removed.
