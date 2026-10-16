---
type: ADR
title: "A remote broker consults home for every HTTP admission"
description: "An optional standalone broker streams payloads off home, fetching destination-scoped credentials over authenticated HTTPS on each HTTP request; rollout and soak validation remain operational work."
tags: [broker, deployment, security]
status: stable
adr: "0091"
adr_status: "Accepted"
date: 2026-10-16
---

# 0091 — A remote broker consults home for every HTTP admission

**Status:** Accepted. Implementation includes the control endpoint and standalone
Fly deployment. Production migration and longer load/soak measurements are
operational validation, not implied by this decision.

## Context

[#2886](https://github.com/managoat/managoat/issues/2886) measured a benefit from
placing the proxy on Fly iad, including hosted E2B and Sprites. This does not
establish a fix for #2844's historical hung install. Home retains accounts,
policy, encrypted credentials and the database. A relay through home would
retain the payload bottleneck. [ADR 0019](0019-egress-credential-brokerage.md)'s
broker-only sandbox egress floor remains mandatory.

## Decision

Ship `broker/` as a separate release with only the broker library and its HTTPS
control client. It has no Fountain application, database access, master key,
account keys or sandbox-provider credentials. `BROKER_MODE=remote` directs new
sandboxes to its HTTPS proxy. Home may retain a local listener for migration.

The deployment-authenticated `POST /internal/broker/v1/{lookup,authorize,events}`
protocol is separate from the user API and intercepted before parameter logging,
Sentry and router instrumentation. A random shared token of at least 32 bytes
is checked in constant time. Requests and responses travel over verified HTTPS;
the client does not retry or follow redirects. Lookup needs both this deployment
token and a valid random sandbox token. It returns only reachability patterns,
expiry, a server-generated session id and a signed log receipt. Each HTTP
request, including every request inside CONNECT, uses that session id to fetch
fresh rules for its actual destination. Host matching limits the delivered
credentials; custom templates export only the variables they reference.
The broker still enforces path rules and rejects private upstream addresses.

A home transaction locks the session row `FOR SHARE` while checking expiry and
decrypting its rules. Deletion and rotation serialize against that read. Missing
or expired sessions deny admission; unavailable authority never uses cached
success. Authorization timeouts are bounded (2-second database query,
3-second transaction, client 2-second connect / 1-second pool / 5-second receive
limits). The remote node retains no credential cache. Initial policy and expiry
remain pinned to a connection; changing network policy requires a new session
and reconnect. An admitted stream may finish after revocation. Protocol upgrades
retain the library's existing behavior: admission is checked, traffic after
upgrade is not reauthorized and revocation does not forcibly close it.

The remote node is trusted with plaintext credentials for requests it admits and
the broker CA private material. `BROKER_CA_SEED` is a dedicated 32-byte seed,
shared with home solely so home can install the matching public CA in sandboxes.
For migration it can be the existing HKDF-derived broker seed; do not export the
master key. Compromise of a broker requires revoking its control token, rotating
exposed provider credentials and CA, and reprovisioning affected sandboxes.

Terminal request events use the signed receipt to recover the home's tenant and
conversation binding even after the session is deleted. Paths, headers, bodies,
raw errors and tokens never enter the event protocol. Receipts expire after seven
days; streams longer than that lose their terminal row. Delivery is explicitly
best-effort, like the existing home request-log buffer: the remote ETS queue holds
at most 5,000 events, sends small batches without retries, and logs drop counts.
Process loss or a home outage can lose events. This is not a durable audit ledger.

One Fly app endpoint distributes new TCP connections; connections stay on their
chosen machine. Replicas share only control configuration and CA seed, and consult
the same home authority. There is no session-affinity database or replica cache.
A failed machine loses its streams; clients reconnect through the endpoint.
Start with one machine; scaling does not guarantee linear throughput. Rolling
deploys and a best-effort 120-second shutdown allowance cannot guarantee draining
arbitrarily long streams. Home readiness remains independent of remote health;
provisioning and broker gauges check the remote TLS listener with a bounded probe.

## Consequences

Payload bytes flow origin → Fly → sandbox. Home handles control traffic and stays
an availability dependency for every new request. This adds a home round trip to
each HTTP admission; measure authorization latency and mixed workloads before
assuming the artifact benchmarks predict interactive performance. A TLS listener
probe verifies transport reachability, not a complete authorized forwarding path.

The [deployment guide](https://github.com/managoat/managoat/blob/main/broker/README.md) covers installation, rollback, cost,
and the validation checklist. A one-machine deployment has maintenance gaps.
Durable event delivery, forced stream revocation, automatic sizing, and prolonged
soak/WAN-counter evidence are not implemented by this change.

## Alternatives considered

- **Database/master key on Fly:** expands remote compromise to all durable secrets.
- **Push and cache decrypted sessions:** creates stale revocation authority and a
  larger resident credential set.
- **Direct public artifact downloads:** changes the broker-only egress floor.
- **Move the whole application:** unnecessary to move the high-volume data path.
