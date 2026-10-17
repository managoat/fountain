# Selective direct egress qualification

This records the bounded investigation for
[#2889](https://github.com/managoat/managoat/issues/2889) and
[ADR 0095](../decisions/0095-public-downloads-preserve-broker-floor.md).
The [transport evaluation](broker-transport-evaluation.md) compares existing
Elixir packages and replacement brokers. This is evidence about a candidate
policy, not an operator instruction to
relax existing sandboxes.

## Hypothesis and environment

An exact allow rule for a public artifact host might let its bytes bypass the
broker while preserving the tenant's destination restriction. The test
attempted to reach a different, denied HTTP authority using the address of an
allowed registry. Both targets were public sites; no credential or private
payload was sent.

On 2026-10-17, one disposable Sprite named
`issue2889-direct-cf072649` was created through `Managoat.Sandbox.create/3`.
The existing adapter applied `%NetworkPolicy{allow: ["registry.npmjs.org"]}`.
The commands used `--noproxy '*'` to exercise provider enforcement directly,
without client cooperation. All requests retained curl's normal certificate
verification. Bodies were discarded; each request had a ten-second limit.
The current repository baseline was `47c81f86d`; this exercised the running
provider adapter through the existing server, not a patched broker.

## Procedure and observations

Each probe ran with this common command prefix:

```bash
curl --silent --noproxy '*' --max-time 10 --output /dev/null \
  --write-out '%{http_code} %{remote_ip} %{ssl_verify_result} %{time_total}'
```

| Additional arguments | curl exit | HTTP status | Observation |
|---|---|---|---|
| `https://registry.npmjs.org/` | 0 | 200 | Allowed host; verified TLS; `2606:4700::6810:322`; 0.040311 s |
| `https://www.npmjs.com/` | 6 | 000 | Ordinary denied-host DNS lookup failed |
| `--connect-to www.npmjs.com:443:registry.npmjs.org:443 https://www.npmjs.com/` | 0 | 403 | Denied authority reached over verified TLS at the same IP; 0.018110 s |
| `https://example.com/` | 6 | 000 | Unrelated denied-host DNS lookup failed |

The third request changes the connection destination while retaining
`www.npmjs.com` as the URL authority and TLS identity. The returned HTTP 403
was reached after certificate verification (`ssl_verify_result=0`). It was
not the provider's ordinary DNS refusal. This demonstrates that the candidate
allowlist permitted reaching a denied HTTP authority through a shared
address. It does not establish access to any protected npm resource or
universal reachability of other Cloudflare tenants.

After those probes, the adapter applied `%NetworkPolicy{allow: []}`. A new
registry request returned curl exit 6 / HTTP 000. The Sprite was then destroyed
successfully in an `after` cleanup block. No existing sandbox was modified;
no broker session or conversation database row was created. The temporary
qualification script was removed from the server.

This is a functional boundary test with one observation per case. The
elapsed values are diagnostic, not a performance comparison. The test did
not measure download throughput, an existing connection surviving revocation,
or E2B enforcement. No claim about historical stalled installs follows.

## What would qualify a future implementation

First establish provider-enforced authority isolation, including shared IPv4
and IPv6 addresses, explicit-IP dialing, alternative DNS, SNI/Host mismatch,
subdomains and redirects. If a provider cannot offer it, record the proposed
weaker guarantee explicitly rather than calling it equivalent to broker host
policy. The current implementation is not qualified by ordinary successful
requests plus DNS refusals alone.

Then test mixed-use hosts, path-scoped credentials, inspection, credential and
policy updates during a turn, open connections, suspend/resume, and reattach.
A tightening failure must prevent continued use of the old direct route. Test
client compatibility separately for apt, curl, git, npm and each runtime.
Curl [documents](https://curl.se/docs/manpage.html#--noproxy) that host entries
also match subdomains; an exact provider-domain rule and `NO_PROXY` do not
necessarily select the same requests.

Only after those gates pass, compare actual remaining artifacts against
brokered delivery: identical verified hashes/bytes, sequential and concurrent
runs, median and tails, full cold-start time, and broker interface bytes.
Record image reuse and preloaded artifacts so avoided downloads are not
counted as a routing speedup. Direct requests also need an explicit
observability contract: broker request logs and content inspection will not
see them, and a policy-decision record is not a per-request audit trail.
