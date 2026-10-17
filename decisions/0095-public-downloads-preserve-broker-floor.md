---
type: ADR
title: "Public downloads preserve the broker network floor"
description: "Public artifact hosts do not receive direct egress exceptions: the current Sprites DNS/IP policy cannot preserve the broker's HTTP destination boundary on shared addresses."
tags: [broker, security, sandbox]
status: stable
adr: "0095"
adr_status: "Accepted"
date: 2026-10-17
---

# 0095 — Public downloads preserve the broker network floor

**Status:** Accepted, 2026-10-17. The existing floor remains implemented;
no direct-egress configuration or provider capability is added here.

## Context

[#2889](https://github.com/managoat/managoat/issues/2889), under
[#2946](https://github.com/managoat/managoat/issues/2946), investigates reducing
broker bandwidth by allowing approved public artifact hosts directly from
sandboxes. The proposed permission was the intersection of operator approval,
tenant destination policy, and absence of credential or inspection needs.
This must preserve the destination restriction even when the sandbox ignores
proxy variables or deliberately chooses its connection address.

[0019](0019-egress-credential-brokerage.md) makes the provider allow only the
broker host. The broker decides the HTTP destination and credential rules.
`Provisioning.apply_broker_floor/2` compiles that floor into
`Managoat.Sandbox.NetworkPolicy.allow`; the Sprites adapter sends domain
rules. `Egress.apply_policy/2` also applies the floor on reattach. The current
model still includes Environment `networking_type` and `allowed_hosts`;
retiring environment layers did not remove that tenant policy.

The [Sprites networking documentation](https://docs.fly.io/sprites/concepts/networking)
describes a DNS-based allowlist: a raw IP becomes reachable after resolution
from an allowed domain. It documents live connection dropping on tightening,
but not isolation of HTTP authority or TLS SNI at shared addresses. An
isolated qualification confirmed the distinction; the complete procedure and
results are in `contributing/selective-egress-qualification.md`.

## Decision

Do not add public registry domains to the current provider allowlist or use
`NO_PROXY` to bypass the broker for them. Keep the implemented broker floor.
The evaluated Sprites DNS/IP policy is insufficient to preserve the broker's
HTTP destination boundary for shared-address hosts. The HTTP 403 obtained
from a denied hostname over verified TLS proves reachability, not access to
protected data. A failed ordinary DNS lookup is insufficient evidence that a
destination cannot be reached.

This is a rejection of the evaluated direct-host implementation, not a claim
that credential custody intrinsically requires all traffic to be proxied.
Reconsider only with an independently enforced authority boundary, or an
explicitly accepted weaker destination guarantee. Qualify each provider
separately; the Sprites result is not evidence about E2B or Vercel.

A replacement design must also account for all paths on a mixed-use host,
credential/inspection changes, and existing connections. Revocation must take
effect before a newly protected destination becomes usable, including during
reattach. Client proxy settings choose a route; they never authorize one.

## Consequences

Public downloads still pay broker bandwidth and latency. Improve connection
reuse using an existing HTTP client (see the
`contributing/broker-transport-evaluation.md`) and avoid
repeat downloads through image reuse or verified pinned
artifact preloading. These changes can preserve the floor. They do not
justify a generic package cache or a new remote broker deployment.

The selective direct-egress investigation has a supported negative result:
no performance benchmark can qualify a route that already fails its required
destination boundary. The historical download timing and unexplained stalls
in [#2844](https://github.com/managoat/managoat/issues/2844) remain separate.
No production sandbox or egress configuration changed in this qualification.

[PR #2942](https://github.com/managoat/managoat/pull/2942), open when this
investigation ran, proposes ADR 0093 and removal of the remote broker. That
proposal restates 0019's floor. This decision neither depends on the PR being
merged nor changes broker placement or CA custody.

## Alternatives considered

- **A small exact-domain public allowlist.** Rejected for the current Sprites
  implementation: an allowed registry address also answered TLS requests for
  a denied hostname.
- **Tool-specific direct routing or `NO_PROXY`.** Cannot repair a boundary
  that malicious sandbox code can bypass. Tool compatibility remains a
  separate concern; curl's host exclusions also include subdomains.
- **Opaque CONNECT through the broker.** Still relays every payload byte and
  cannot enforce HTTP path rules inside encrypted traffic. It is a separate
  proposal, not direct egress.
- **Provider-side credential injection.** Potentially removes the home
  bandwidth leg, but changes credential custody and needs its own policy,
  lifecycle and provider qualification. It is not built here.
