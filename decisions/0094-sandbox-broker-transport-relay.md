---
type: ADR
title: "A loopback transport relay for HTTPS broker endpoints"
description: "Sandbox tools use an HTTP proxy on loopback; a supervised transport relay carries their bytes over verified TLS to the configured HTTPS broker."
tags: [security, sandbox, broker]
status: stable
adr: "0094"
adr_status: "Accepted"
date: 2026-10-16
---

# 0094 — A loopback transport relay for HTTPS broker endpoints

**Status:** Accepted. Implemented with #2848; live package compatibility
validation is recorded in the implementation PR.

## Context

[Issue #2848](https://github.com/managoat/managoat/issues/2848) reproduced wget,
LuaRocks and RubyGems sending plaintext proxy requests to an HTTPS proxy URL.
Production's broker address was already HTTPS on port 443, through a
TLS-terminating ingress in front of the broker inside Managoat; any deployment
whose ingress terminates TLS has the same mismatch.
Preserving environment variables across sudo does not fix that transport
mismatch. Tool-specific downloader overrides would leave other tools broken.

[ADR 0019](0019-egress-credential-brokerage.md) requires every conversation to
use the broker, with a provider-enforced network floor allowing only its host.
[ADR 0073](0073-one-sandbox-per-conversation.md) gives each conversation its own
sandbox, so a fixed loopback port has one conversation owner.

## Decision

When `BROKER_PROXY_URL` uses HTTPS, sandbox proxy variables name
`http://<token>:<label>@127.0.0.1:18480`. A Node standard-library relay binds
only IPv4 loopback, establishes certificate- and hostname-verified TLS to the
fixed configured broker, and streams bytes in both directions with socket
backpressure. It neither interprets HTTP nor chooses a destination. CONNECT
and absolute-form HTTP therefore retain the existing broker protocol.
HTTP broker endpoints keep their existing direct path.

The relay explicitly reads the system CA bundle installed by provisioning;
it does not inherit tenant CA overrides or TLS-disable variables. TLS setup
has a ten-second deadline. Established streams have no new idle deadline or
request retries. The listener caps concurrent client connections at 256.

Session credentials remain solely in client process environments and request
bytes. No token is written into relay configuration, command arguments, wgetrc,
LuaRocks configuration or the shared `.env`. Session rotation changes client
proxy variables exactly as before; the relay does not need a token refresh.
The broker remains responsible for authentication, policy, credential
injection and request logging. The provider network floor is unchanged.

### Ownership and lifecycle

Provisioning installs the script atomically under a per-sandbox `flock`.
Cold start and wake wait for a verified upstream handshake and a bound local
listener before setup, skills, package installation or runtime preparation.
Broker trust/transport failure now refuses a wake, as it does a cold start.

A detached supervisor uses a mode-0700, UID-owned directory and Unix control
socket. Readiness identifies both the conversation and configuration/script
fingerprint. A different conversation owner is refused; a changed upstream or
script replaces the old worker. Repeated ensure calls reuse a ready worker.
The supervisor restarts an unexpectedly exited worker, stopping after three
failures in a minute. Losing the supervisor closes its worker through IPC
disconnect. Failures close affected sockets; they never retry a request or
fall back to direct egress. A later wake can restart a failed supervisor.

The machine park protocol stops the relay before provider suspension, under
the existing park lease. Failure to stop refuses suspension and uses the
existing suspend-failure handling. Wake starts it again. Destroying the
sandbox removes both processes and all connections; normal broker session
revocation is unchanged. The detached process does not retain a provider exec
session or send keepalive traffic.

## Consequences

Tools that support ordinary HTTP proxies can use a broker reached over TLS. Node and `flock`, already part of the supported sandbox shape, are
required before setup scripts. The extra process and connection boundary add
lifecycle and diagnostic work. Relay errors expose only a generic failure,
never payloads, credentials or raw transport errors.

This does not make applications honor proxy variables, change CA requirements
for intercepted HTTPS destinations, or solve broker bandwidth and stall issues.
[Issue #2844](https://github.com/managoat/managoat/issues/2844) remains independent.
Existing environments using apt's `lua-check` need no configuration change.

## Alternatives considered

- **Per-tool downloader configuration:** does not cover the broader wget and
  RubyGems compatibility gap and creates tool/version-specific maintenance.
- **Plaintext proxy endpoint:** exposes authentication and HTTP payloads on
  the internet path between sandbox and broker.
- **Transparent interception:** [#2854](https://github.com/managoat/managoat/issues/2854)
  is deferred feasibility work. It must establish an unbypassable network
  boundary before it can replace the current floor or explicit proxy path.
- **A second policy proxy in the sandbox:** duplicates broker responsibilities
  without helping this transport mismatch.

## History

- 2026-10-16 — Accepted and built (#2848).
- 2026-10-17 — Kept when the remote broker was removed ([0093](0093-the-broker-runs-inside-managoat.md)): the relay serves any HTTPS broker endpoint, including one inside Managoat behind a TLS ingress.
- 2026-10-17 — The relay starts beside the broker CA install instead of after it: it verifies the endpoint with the system bundle, which that install does not change for it.
