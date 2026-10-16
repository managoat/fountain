# Selective direct egress investigation (#2889)

Status: investigation, 2026-10-16. **Do not enable in production yet.**
This proposes a policy and validation gate; it does not amend the accepted
broker-only policy in [ADR 0019](../decisions/0019-egress-credential-brokerage.md).
[Issue #2889](https://github.com/managoat/managoat/issues/2889) remains open:
live enforcement, client compatibility, lifecycle revocation and complete
cold-start measurements are outstanding.

[ADR 0090](../decisions/0090-portable-environment-layers.md) already accepts a
separate, unbuilt exception for a trusted encrypted-artifact fetch on a fresh
machine. It narrows to broker-only before keys, extraction or tenant code are
introduced. Preserve that ordering; it does not authorize general direct
egress while an agent runs.

## Recommendation and measured benefit

Prefer the remote-broker work in [#2886](https://github.com/managoat/managoat/issues/2886)
for the next production performance change. Investigate direct access only as
an explicit whole-host permission, conditional on provider enforcement tests.
Neither missing credential bindings nor an installer choosing a public URL
constitutes permission to bypass the broker.

The [#2886 experiment](https://github.com/managoat/managoat/issues/2886#issuecomment-6216805109)
already supplies a matched direct-path control. These are previously reported
measurements, not new experiments performed for this document:

| Receiver | Direct CDN median | Home broker median | Fly broker median |
|---|---:|---:|---:|
| Sprite | 0.528 s | 4.650 s | 1.692 s |
| Hosted E2B | 0.694 s | 6.007 s | 2.587 s |

The payload was the 163,294,814-byte Codex 0.160.1 linux-x64 archive;
three rotated sequential runs per route used the same receiver/client within
each provider. All 30 transfers, including concurrent broker batches, passed
integrity checks. The direct versus home median differences are 4.122 s and
5.313 s. These are transfer differences, not full cold-start savings or tail
estimates. Home WAN counters were not captured. Each successful direct fetch
would remove that payload from broker forwarding, but measured WAN reduction
and representative workload totals are still missing. Four-receiver direct
controls in the same investigation reached 13–15 Gbps; those controls did not
validate selective policy or client routing.

Remote brokerage improves all brokered traffic and preserves an enforcement
and request-log point, while requiring remote credential custody and control
plane design. Direct egress avoids forwarding eligible bytes entirely, but
loses that enforcement/visibility and still requires a broker for credentials.
It is complementary, with a different security cost. Neither approach has
explained [#2844's historical stall](https://github.com/managoat/managoat/issues/2844).

## Remaining download inventory

Source inspection at `bb3ec69cb` (v0.31.15), not a live traffic census:

| Path | Remaining downloads and eligibility |
|---|---|
| Codex ACP | Manifest has 30 entries, 25 applicable to Linux x64 glibc, all at `registry.npmjs.org`; includes the large Codex native archive. |
| Claude ACP | Manifest has 112 entries, 105 applicable to Linux x64 glibc; 104 when the image executable is reused. All manifest URLs use `registry.npmjs.org`. |
| Claude fallback | Native SDK package remains necessary when image executable reuse fails; the historical native size is not a universal baseline. |
| Manifest failure | npm fallback can consult registry configuration, including private registries. Keep brokered unless the effective host independently qualifies. |
| Gemini | npm installation; dependency resolution and private registry configuration require a live inventory. |
| Packages, repositories, skills, setup scripts, MCP tools | Environment/user-controlled destinations and redirects. No general registry, GitHub or CDN bypass. |

The manifests are in `apps/fountain/priv/runtimes/acp/`; platform filtering,
image reuse, bounded retries, SHA-512 verification and fallback are in
`Managoat.Runtimes.ACP`. A candidate experiment can start with
`registry.npmjs.org`, but this grants the **entire host**, including arbitrary
packages, requests and uploads the origin supports. A package checksum protects
artifact integrity, not outbound data confidentiality. Keep current integrity
checks, TLS verification and version pins. The current manifest curl command
does not follow redirects; do not silently introduce redirect following.
Measure actual selected packages/bytes and image reuse on every cold-start run.

## Candidate policy, not implemented

Compile a versioned conversation policy into both provider enforcement and
client routing. Preserve the broker's current effective destination rules,
including explicitly bound services; direct eligibility must never grant an
otherwise-forbidden destination. A stricter deny-over-binding policy would be
a separate behavior change requiring its own decision.

For each canonical exact hostname:

1. A destination forbidden by the effective environment policy is denied.
2. Any credential-binding overlap (explicit, built-in, inference or MCP),
   inspection requirement, or uncertain match requires the broker.
3. Otherwise direct requires both explicit operator eligibility and explicit
   environment permission. Unrestricted networking alone does not opt in.
4. All other permitted destinations remain brokered.

Initial eligibility excludes wildcard hosts, IP literals, private/link-local
addresses and mixed-use credential hosts. Normalize IDNA, case and trailing
dots consistently; reject unsupported patterns rather than guessing their
intersection. Evaluate overlap across every granted binding, not just a
credential seen in a particular request. Redirect targets are separate
policy decisions and receive no inherited direct permission.

The provider allowance would be `{broker host} union {eligible direct hosts}`.
Client routing would select the same direct set before connecting; a broker
CONNECT passthrough still forwards bytes, and a proxy response cannot be
assumed to make a generic client reconnect directly. `NO_PROXY` is a routing
hint only. An agent can ignore it, use raw sockets, change DNS or send arbitrary
headers. Provider enforcement must contain those actions independently.

## Provider evidence and compatibility gaps

The current abstraction, `Managoat.Sandbox.NetworkPolicy`, exposes only an
allowed-domain list. Sprites compiles it to allow rules, with explicit deny-all
for an empty list. E2B sends `denyOut: ["0.0.0.0/0"]` and `allowOut` to its
network update API. These translations do not prove live isolation semantics.

[E2B's network documentation](https://docs.e2b.dev/network/internet-access)
(accessed 2026-10-16) says domain filtering inspects HTTP Host on port 80 and
TLS SNI on 443; other ports use IP/CIDR rules and domain filtering does not
support QUIC. DNS gets an automatic exception. It explicitly warns that shared
CDN/object-storage endpoints can expose other destinations on an allowed
endpoint. A successful TCP connect alone does not establish allowed traffic;
tests must observe application responses. Updates replace the complete policy.

This is a substantive qualification gap for arbitrary untrusted sandbox code.
Test mismatched SNI/HTTP authority, shared-IP virtual hosts, DNS rebinding and
literal-IP access against controlled endpoints. Certificate verification in a
cooperative installer does not constrain an adversarial process. Do not certify
E2B's whole-host isolation from this documentation alone. Sprites' corresponding
live semantics are also unverified here; adapter unit tests are not proof.

| Client | What must be demonstrated under the candidate policy |
|---|---|
| curl / manifest installer | Upper/lowercase proxy variables, suffix matching, direct and brokered URLs, redirects and integrity failure; preserve bounded fetches. |
| npm | Effective proxy/noproxy and registry settings, public/private scoped registries, lifecycle subprocesses and fallback. |
| git | HTTPS proxy configuration and credential helpers; SSH remains outside a domain-based HTTP routing assumption. |
| Claude, Codex, Gemini | Inference stays brokered with real injection verified using disposable test credentials; runtime and subprocess routing cannot be inferred from curl. |
| wget / RubyGems / LuaRocks | Check tool-specific bypass settings against the existing HTTPS broker loopback relay; do not assume support for `NO_PROXY` from proxy support alone. |
| Setup scripts / MCP clients | Tool-specific settings and ignored proxy variables; denied destinations remain unreachable. |

No row in this matrix is marked passed by the prior transfer experiment.

## Policy changes, restore and existing connections

A process environment update cannot revoke provider access or an established
socket. Before a destination becomes protected, stop admission and quiesce all
sandbox execution, restrict provider egress, and verify old direct connections
cannot continue. Only then activate the new policy generation, broker session
and client routing. A per-turn broker refresh alone is insufficient.

If the provider cannot terminate existing flows and guarantee enforcement
before any process resumes, terminate and recreate the sandbox under the new
policy. Suspending and restoring the same memory/socket state is not a substitute.
On timeout or ambiguous update, retain the pending generation, deny execution
and reconcile or destroy the sandbox; do not report the change active. Broker
session revocation cannot compensate for a still-open direct path.

Warm restore and reattach must establish the current policy before untrusted
processes run, not merely before the next requested command. If the provider
cannot give that ordering, disable direct eligibility for that lifecycle or
recreate. Concurrent binding/environment changes need generation checks and
serialization across every affected conversation. Widening may occur only
after the complete policy has been checked; narrowing must precede activation.
These are required new lifecycle guarantees, not claims about today's code.

## Visibility and secrets

Direct requests omit broker request/status/latency records and broker content
inspection. Policy audit records can show who approved a host, the conversation,
provider, generation, effective scope and application outcome. They cannot show
all requests or prove which data left. Provider telemetry is supplementary and
must be documented with its own coverage; it is not a complete egress audit.

Unbound and non-HTTP secrets already enter sandboxes as real values. Direct
permission therefore authorizes a possible exfiltration destination even when
no broker credential is injected. Never log secret values, proxy tokens or
sensitive request targets to compensate for reduced visibility.

## Proposed ADR 0019 revision, conditional on acceptance

If validation succeeds and this tradeoff is accepted, amend these sections in
the implementation PR, with an explicit new decision date:

- Decision and §2: broker-only remains the default; opt-in exact-host direct
  permissions may widen the provider floor only under the compiled policy.
- §3: destination enforcement is split between provider policy for direct
  traffic and broker rules for brokered traffic, with identical effective
  authorization and protected-host precedence.
- §5 and lifecycle consequences: versioned policy activation, revocation,
  update-failure behavior and recreate requirements become mandatory.
- Egress trail and consequences: the API is a brokered-request trail, not a
  complete account of sandbox egress. Credential custody and universal request
  visibility are distinct guarantees.

Do not edit the accepted ADR to describe this as built. No credential custody
exception is proposed for broker-bound secrets.

## Isolated prototype and follow-up scope

Before implementation, qualify each provider with disposable sandboxes,
controlled origins, throwaway credentials and no production policy changes:

1. Run broker-only and broker-plus-one-exact-host policies. Check approved and
   denied application responses, subdomains, lookalikes, redirects, shared IPs,
   DNS rebinding, IPv4/IPv6, private destinations, alternative ports, QUIC and
   ignored proxy settings. Record effective provider rules and versions.
2. Verify broker credential injection, tenant isolation and inspection-required
   routing alongside direct transfer. Exercise each client matrix row.
3. Add a binding while a direct stream and keep-alive connection are open;
   tighten environment restrictions; force update failures, timeouts and
   concurrent edits. Repeat through suspend/restore and reattach. No protected
   traffic may continue during activation or after acknowledgement.
4. Only after those gates pass, rotate matched direct/brokered downloads with
   identical clients, pins, hashes and destinations, sequentially and at
   concurrency 3 and 12. Record every attempt, bytes, median, maximum, failures,
   and broker plus home-interface byte deltas. Do not claim reliable p95 from
   a handful of trials.
5. Measure complete fresh Claude and Codex launches on both hosted providers,
   including image-reuse/fallback cases, packages and runtime initialization.
   Record cold-start phases and actual downloads. Delete and verify all test
   resources and revoke disposable credentials after the run.

Suggested follow-up work is a provider qualification harness first, followed
by policy compiler/lifecycle implementation only for providers that pass, then
client integration and observability documentation. These are scoped proposals,
not created tickets or accepted implementation commitments. Keep #2889 open
until the missing evidence is recorded or a maintainer explicitly accepts a
stop decision. Prior transfer controls establish potential benefit, not safety
or production readiness.
