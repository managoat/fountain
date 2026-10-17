# Replacing the broker transport

Prefer Finch/Mint for upstream transport instead of maintaining a custom HTTP client and pool. Keep Managoat's authorization and credential policy. This evaluation supports [#2946](https://github.com/managoat/managoat/issues/2946) and [#2947](https://github.com/managoat/managoat/issues/2947); it does not report a deployed replacement.

Research snapshot: 2026-10-17. Agent Vault source inspected at `872578e4cdf9e03d5e3bcb5512023a70bf90ed65`; Managoat baseline `47c81f86d`. The direct-egress result is adopted in [ADR 0095](../decisions/0095-public-downloads-preserve-broker-floor.md), with [qualification evidence](selective-egress-qualification.md).

## Can an existing Elixir package do this?

### Takeaway

**Yes for the upstream HTTP transport: prefer Finch over a new connection pool and wire protocol implementation.** Keep Managoat's conversation authorization, credential rules, SSRF policy and audit integration. A complete credential-broker replacement is a different, substantially larger migration. The immediate recommendation is a Finch-backed upstream adapter, initially for plaintext HTTP downloads, with existing HTTPS/WebSocket behavior retained until equivalent streaming tests pass.

### Cited Findings

- Finch is built on Mint and NimblePool. Its HTTP/1 pools are origin-specific; tagged pools can separate tenants or tokens. It supports request and response streaming and explicit pool lifecycle management. Its async HTTP/1 API delivers messages as a firehose; synchronous streaming gives tighter control. Latest docs describe v0.24, while this checkout already locks Finch **0.23.0**, Mint **1.11.0**, Req **0.7.4**. Confirm features against the installed version rather than silently upgrading. [Finch documentation](https://finch.hexdocs.pm/Finch.html), [Managoat lockfile](https://github.com/managoat/managoat/blob/47c81f86d/mix.lock).
- Mint allows dialing an address separately from `hostname`, which supplies SNI, hostname verification and Host identity. It supports active/passive operation and HTTP/1 or HTTP/2 selection. This is the relevant primitive for retaining vetted-IP dialing rather than performing an unchecked second DNS lookup. [Mint connection options](https://mint.hexdocs.pm/Mint.HTTP.html#connect/4).
- Req defaults to following redirects and retrying transient GET/HEAD failures; it also has body decoding and decompression steps. Those conveniences change transparent-proxy behavior and are a reason to use Finch directly here. [Req steps](https://req.hexdocs.pm/Req.Steps.html).
- ReverseProxyPlug forwards Plug requests to upstream URLs and supports streamed responses through client adapters, including Finch. Its inclusion of CONNECT in a method list does **not** establish an implementation of forward-proxy CONNECT termination, dynamic CA signing, or conversation credentials. [ReverseProxyPlug](https://reverse-proxy-plug.hexdocs.pm/readme.html).
- Bandit is an HTTP server built on Thousand Island; it does not document a ready-made conversation credential broker. Replacing a server frontend is separable from replacing upstream transport. [Bandit](https://bandit.hexdocs.pm/Bandit.html).

### Inferences

The smaller change is to remove commodity upstream HTTP work, not replace the entire policy plane. Implementation review of Finch 0.23 confirmed its streaming producer/callback APIs; start with HTTP/1 to retain backpressure. Qualify:

1. Resolve and reject prohibited IPs, dial that vetted address, retain the original Host/SNI/certificate identity. Do not validate DNS then let a pool independently resolve another address.
2. Preserve authorization on every applicable request; a warm socket is never authorization. Separate pools where connection-bound authentication can cross tenants or credential generations. Bound pool creation and retire idle pools.
3. Keep redirects visible to the client and preserve content encoding; never replay a partly sent request. Stream bodies with bounded memory, close on cancellation, and reframe chunks/trailers correctly.
4. Verify plaintext apt reuse, same-connection expiry/revocation, two-tenant isolation, stale upstream closure, slow consumers, truncated/chunked bodies and upgrades. Measure end-to-end downloads; package adoption alone proves no speedup.

These are Managoat integration requirements, not missing reasons to write another HTTP client. A remote replacement still carries every relayed byte; neither pooling nor a different language removes the home-uplink ceiling.

### Gaps

No drop-in Elixir package implementing the full current Managoat credential-session contract was established. The published `managoat_broker` 0.19.0 integrates Finch for bodyless plain HTTP GET/HEAD downloads; uploads and CONNECT keep their existing streaming transport. It also binds ordinary Host routing to the checked destination, including inside CONNECT, and refuses inner absolute-form targets.

[Broker PR44](https://github.com/managoat/managoat_broker/pull/44) records controlled loopback measurements: 100 origin connections became 5 across five sequences of 20 requests. With 10 ms added per accepted connection, median sequence time fell from 219.014 ms to 23.728 ms; without that delay it was 13.515 ms versus 10.946 ms. A fixture with Nagle enabled instead exposed a delayed-ACK regression, so these results are transport evidence, not a universal speedup. No deployed apt benchmark has been run. Remaining transport scope and end-to-end measurements belong in #2947.

## Would replacing the entire broker be better?

### Takeaway

**Infisical's standalone Agent Vault is the closest product replacement, but it is not a transparent upgrade. Envoy is a mature data plane with a custom integration requirement, not a ready-made MITM credential broker.** Neither is a better immediate answer than using the HTTP client already in this application's dependency graph.

### Cited Findings

| Candidate | What it supplies | What Managoat would still have to do |
|---|---|---|
| Infisical standalone Agent Vault | Self-hosted binary, vault-scoped short-lived sessions, HTTP/HTTPS forward proxy, substitution, logs; MIT core with `ee` exception. README still labels API preview. | Map each conversation's credential snapshot into an isolated vault/session; synchronize rotations/deletions, map grants and unmatched-host policy, integrate logs and CA lifecycle. Its internal Go interfaces are not an external Managoat Store API. |
| Infisical platform Agent Vault | Access bundles, sessions, enrolled proxies and centralized administration. | Adopt Infisical as another policy/credential custodian, provision bundles/services/sessions, handle polling/revocation and licenses. Current documented proxy rejects WebSockets and HTTP/2-only clients. |
| Envoy | Mature forward routing, connection management, HTTP upgrades; external authorization/processing hooks can approve and mutate headers. | Build secure token-to-conversation authorization, injection and auditing integration. CONNECT tunnel support alone does not inspect inner TLS or mint dynamic MITM certificates. A compatible intercepting frontend/certificate layer is additional work. |
| CyberArk Secretless | Apache-2.0 broker and credential-provider/HTTP connector plugins. | Supply client authentication and tenant/session isolation: README explicitly says any client able to connect receives an authenticated backend session. This is the wrong default for a shared public-facing broker. |

Sources: [Agent Vault README](https://github.com/Infisical/agent-vault/tree/872578e4cdf9e03d5e3bcb5512023a70bf90ed65), [Infisical proxy behavior](https://infisical.com/docs/documentation/platform/agent-vault/proxies), [Envoy external authorization](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_authz_filter), [Envoy external processing](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_proc_filter), [Envoy CONNECT/upgrades](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/http/upgrades), [Secretless README](https://github.com/cyberark/secretless-broker).

Current standalone Agent Vault source gives more useful detail than its marketing:

- It uses Go `http.Transport` with pooled idle connections, 90-second idle timeout, 100 maximum idle connections, and HTTP/2 disabled. Plain absolute-form HTTP and intercepted CONNECT share forwarding logic. [proxy.go](https://github.com/Infisical/agent-vault/blob/872578e4cdf9e03d5e3bcb5512023a70bf90ed65/internal/mitm/proxy.go).
- CONNECT resolves session identity once and closes over that scope. The inner request handler calls credential injection each request but does not repeat `ResolveForProxy`. This is a **source-inspected revocation/expiry compatibility risk**, not a tested exploit. The source still has an IP-keyed auth-failure pre-gate, relevant to Managoat's earlier shared-NAT limiter problem. [connect.go](https://github.com/Infisical/agent-vault/blob/872578e4cdf9e03d5e3bcb5512023a70bf90ed65/internal/mitm/connect.go), [forward.go](https://github.com/Infisical/agent-vault/blob/872578e4cdf9e03d5e3bcb5512023a70bf90ed65/internal/mitm/forward.go).
- Known-length requests without body substitutions stream. Unknown-length requests enter materialization capped at 64 MiB. WebSocket handling exists in OSS, unlike the platform's documented limitation. `RoundTrip` passes redirects through; there is an explicit OAuth 401 retry. This needs compatibility tests for large chunked uploads and non-replayable requests. [forward.go](https://github.com/Infisical/agent-vault/blob/872578e4cdf9e03d5e3bcb5512023a70bf90ed65/internal/mitm/forward.go), [body limits](https://github.com/Infisical/agent-vault/blob/872578e4cdf9e03d5e3bcb5512023a70bf90ed65/internal/brokercore/session.go).
- Its safe dialer validates actual dial addresses against private/reserved ranges. Services support host/path/port scoping and named credential injection; method is absent from the inspected `Inject` interface, so do not assume platform method restrictions exist in OSS. [netguard.go](https://github.com/Infisical/agent-vault/blob/872578e4cdf9e03d5e3bcb5512023a70bf90ed65/internal/netguard/netguard.go), [credential.go](https://github.com/Infisical/agent-vault/blob/872578e4cdf9e03d5e3bcb5512023a70bf90ed65/internal/brokercore/credential.go), [services documentation](https://github.com/Infisical/agent-vault/blob/872578e4cdf9e03d5e3bcb5512023a70bf90ed65/docs/learn/services.mdx).
- Platform proxies cache session state between polls (default 60 seconds), tolerate five missed intervals, and still intercept exception hosts. These reduce control-path work; exceptions do not remove payload forwarding. [Infisical proxy settings](https://infisical.com/docs/documentation/platform/agent-vault/proxies).
- Envoy explicitly warns dynamic forward proxies need network restrictions against private-address and DNS-based confused-deputy attacks. Authorization configuration is not a substitute for safe egress. [Envoy dynamic forward proxy](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/dynamic_forward_proxy_filter).
- mitmproxy offers configurable streaming, but buffers full messages by default; a credential addon, session authorization, event persistence and production tuning remain custom integration. Squid supplies SSL bump and ICAP request adaptation, but its current docs say those directives are unavailable in v8. Neither is a zero-effort migration. [mitmproxy streaming](https://docs.mitmproxy.org/stable/overview/features/#streaming), [Squid SSL bump](https://www.squid-cache.org/Doc/config/ssl_bump/), [Squid ICAP](https://www.squid-cache.org/Doc/config/icap_service/).

### Inferences

Use Finch now; consider a bounded standalone Agent Vault bake-off only if the goal becomes outsourcing the whole credential service. An Envoy replacement makes more sense if operating a separate proxy data plane is already accepted. Returning to a fork of Agent Vault merely to retrofit Store callbacks and revocation would preserve much of our ownership burden while adding another language/service.

### Gaps

No comparative throughput benchmark was run. Commercial Agent Vault entitlement/pricing and exact self-host license requirements need vendor confirmation before selection. Envoy's dynamic certificate interception feasibility was not prototyped; do not call the `ext_authz` integration “small” until that frontend exists. Source review does not prove either product's complete security posture.

## Can provider-side brokering or direct egress remove the bandwidth problem?

### Takeaway

Provider-side credential injection can remove Managoat from the payload path, but it changes the credential custodian and adapter contract. Broad direct-host exceptions cannot currently be presented as equivalent tenant destination enforcement on Sprites.

### Cited Findings

- Vercel provides host-bound header injection with live policy changes; request filtering/forwarding can select traffic. This is a sandbox-provider capability, not a standalone drop-in proxy. [Vercel injection](https://vercel.com/changelog/safely-inject-credentials-in-http-headers-with-vercel-sandbox), [filtering and forwarding](https://vercel.com/changelog/vercel-sandbox-firewall-now-supports-request-proxying-and-filtering).
- E2B announced Secrets on October 7, 2026: secrets stored outside the sandbox and injected at matching HTTPS destinations; rotations affect subsequent resolutions and paused sandboxes resume with current values. BYOC support is described as forthcoming. Evaluating this for E2B is viable, but does not cover Sprites or retain exclusive Managoat custody. [E2B announcement](https://e2b.dev/resources/introducing-e2b-secrets).
- Sprites documents DNS allowlisting, permission for addresses resolved from an allowed domain, and live tightening that drops connections. This is not a claim of HTTP Host/SNI isolation on shared IPs. [Sprites networking](https://docs.fly.io/sprites/concepts/networking).

### Inferences

An isolated live qualification on 2026-10-17 confirmed the distinction. Disposable Sprite `issue2889-direct-cf072649`, configured through the current adapter with only `registry.npmjs.org` allowed:

| Probe | Result |
|---|---|
| Ordinary registry HTTPS | exit 0; HTTP 200; verified TLS; 0.040 s |
| Ordinary `www.npmjs.com` HTTPS | exit 6; DNS refused |
| `curl --connect-to www.npmjs.com:443:registry.npmjs.org:443 https://www.npmjs.com/` | exit 0; HTTP 403; verified TLS; reached `2606:4700::6810:322`; 0.018 s |
| Ordinary `example.com` HTTPS | exit 6; DNS refused |
| Registry after deny-all policy | exit 6 |

The 403 was an upstream HTTP response reached over successfully verified TLS, not provider DNS refusal: the blocked hostname was reachable through an allowed hostname's shared address. No credentials or sensitive data were sent. Sandbox destruction succeeded. This is enough to reject a claim that adding registry domains preserves the broker's host boundary; it does not prove all alternate hosts or operations work. It is not a download benchmark.

The [qualification record](selective-egress-qualification.md) preserves the commands, results and cleanup outcome. Keep direct egress disabled until a design explicitly addresses this boundary. Pinned artifact preloading/image reuse remains a way to avoid repeated bytes without widening tenant networking.

### Gaps

E2B and Vercel injection were not exercised. Existing direct-connection revocation was not separately tested. No claim about a historical hung install follows from this test.
