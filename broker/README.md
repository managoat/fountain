# Remote broker on Fly

This standalone release forwards sandbox payloads directly between Fly and
origins. Home Managoat keeps the database, encrypted secrets and policy. It must
run the matching control endpoint implementation; `managoat_broker` alone does
not provide that endpoint. See [ADR 0091](../decisions/0091-remote-broker.md).

## Configure and deploy

Use a unique app name in `fly.toml`, then run from this directory:

```bash
fly apps create YOUR-BROKER-APP
fly ips allocate-v4 -a YOUR-BROKER-APP
fly ips allocate-v6 -a YOUR-BROKER-APP
```

Generate a random control token (`openssl rand -hex 32`) and CA seed
(`openssl rand -base64 32`). Store both in your secret manager. Set these on home:

| Setting | Value |
|---|---|
| `BROKER_CONTROL_TOKEN` | Shared random deployment token, at least 32 bytes |
| `BROKER_CA_SEED` | Base64 of the 32-byte broker CA seed |

Keep `BROKER_MODE=local` and the existing proxy URL during validation. For an
existing deployment, securely export `Fountain.Broker.Native.ca_seed/0` as base64
through release RPC instead of generating a new seed. This preserves the public
CA already installed in sandboxes. Never export `MASTER_SECRETS_KEY` to Fly.

Import these three Fly secrets with `fly secrets import -a YOUR-BROKER-APP` from
a secret-manager-generated environment stream (avoid putting values in shell
history or command arguments):

```text
BROKER_CONTROL_URL=https://YOUR-HOME-MANAGOAT
BROKER_CONTROL_TOKEN=<same random token>
BROKER_CA_SEED=<same base64 seed>
```

`BROKER_CONTROL_URL` is the home origin without a path. Its TLS certificate must
be publicly trusted. Allow `/internal/broker/v1/` through your HTTPS ingress;
never cache or log request/response bodies there. The endpoint authenticates
before parsing and is disabled if no control token is configured. Do not route
it through an interactive login gateway. The remote release verifies TLS and
refuses redirects. A proxy session token alone cannot call the control API.

```bash
fly deploy -a YOUR-BROKER-APP --ha=false
fly status -a YOUR-BROKER-APP
fly checks list -a YOUR-BROKER-APP
```

The default is one always-on iad Machine with two performance CPUs and 4 GiB,
matching the bounded placement experiments. Port 443 uses only Fly's `tls`
handler: Fly terminates outer TLS and forwards TCP to port 14322. Do not add an
`http` handler; it does not carry the forward proxy protocol. The private-upstream
guard remains enabled. See [Fly configuration](https://docs.fly.io/reference/configuration).

## Validate, then switch

Before changing the home proxy URL, create an isolated expiring session and a
sandbox with the ordinary broker-only network policy targeting the Fly hostname.
Verify a credentialed request, a denied destination, expiry/revocation including
another request on an existing CONNECT tunnel, home-unavailable failure, streamed
responses and terminal log rows. Verify that another session cannot retrieve the
first session's credentials. Record authorization latency under concurrent load.
Repeat the pinned archive transfers from #2886 and compare SHA-512, latency,
throughput and home WAN counters. Run a mixed-workload soak; the short archive
experiments do not prove tail reliability or audit completeness.

After validation set on home:

```text
BROKER_MODE=remote
BROKER_PROXY_URL=https://YOUR-BROKER-APP.fly.dev:443
```

Retain `BROKER_LISTEN_PORT=14322` temporarily so existing sandboxes can finish
using the old home endpoint. New sandboxes use Fly; running sandbox proxy
variables and network policy do not change in place. Recreate conversations that
must move immediately. Once old sessions are gone, unset `BROKER_LISTEN_PORT`.
The CA seed and token remain required in remote mode. Readiness for the home
console/control API does not depend on Fly; the broker gauge and provisioning
preflight probe Fly's TLS listener.

Rollback: restore `BROKER_MODE=local`, `BROKER_LISTEN_PORT=14322` and the former
`BROKER_PROXY_URL`, retaining the same CA seed. Keep Fly alive until sandboxes
still pointing there have finished or been recreated. Neither cutover nor
rollback transparently migrates existing TCP streams.

## Failures, replicas and logs

Failed session lookups log only a fixed outcome (`http_error`, `timeout`,
`transport_error`, or `invalid_response`), numeric HTTP status where available,
and elapsed milliseconds. A fixed transport subtype distinguishes closed/reset/refused
connections, DNS failure, timeout and HTTP/2 stream/connection closure; unknown
peer reasons stay `other` and HTTP/2 debug data is never retained. All lookup outcomes also emit
`[:remote_broker, :lookup]` telemetry with `count` and `elapsed_ms` measurements
and `outcome`/`status`/`detail` metadata. No tokens, session IDs, receipts, bodies, URLs,
or raw errors are included. The proxy still refuses admission on every failure.
A proxy `unknown_token` log alone cannot distinguish home rejection from a
failed control call; use the lookup classification to distinguish those cases.
These aggregate diagnostics do not attribute an unauthenticated request to an owner.

Every HTTP request consults home; there is no cached-success fallback. Already
admitted streams and upgraded connections may finish after revocation. Control
timeouts refuse new traffic. TCP health checks do not prove home authorization
works, so include a synthetic brokered request in your operational monitoring.

`fly scale count 2` adds a replica behind the same hostname. Both must have the
same token and CA seed; connections stay with a machine while new connections
can land on either. No sticky sessions are required. Machine failure and rolling
updates can interrupt streams: clients must reconnect. Keep home single-node.
The 120-second Fly shutdown timeout is best-effort, not unlimited draining.

Egress logs are best-effort terminal records, as with the local broker. A bounded
5,000-event memory queue sends batches to home. No retry means no intentional
duplicate delivery; outages, process loss, queue saturation, rejected oversized
batches, or receipts older than seven days can lose records. Watch `fly logs`
for `dropped=` messages. Records contain no raw target, headers, body or error.
The remote machine does hold scoped plaintext credentials and CA signing material;
it is part of the trusted computing base, not a credential-free relay.

## Cost and maintenance

As checked against [Fly's October 2026 pricing](https://fly.io/pricing-update/),
the selected machine is about $66/month plus $2/month for dedicated IPv4, with
North American internet egress at $0.02/GB. That is about $88/month at 1 TB egress
before taxes or other account charges; two machines add about $66/month compute.
Inbound downloads are free, but forwarding them to sandboxes is billed egress.
Confirm your region/account pricing and measure actual egress before sizing.
No volume or database is required. Preserve the CA seed and control token in
your secret manager; rotating either requires coordinating home and all replicas.

From this directory, using the repository's pinned mise toolchain:

```bash
mise exec -- mix deps.get --check-locked
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
MIX_ENV=prod mise exec -- mix release --overwrite
```

The root CI static job runs these checks. The Docker build uses only this
directory and produces a release without the Fountain server or its credentials.
