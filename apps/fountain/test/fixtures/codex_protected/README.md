# Protected Codex request compatibility

`capture.json` records two synthetic ACP turns using codex-acp **1.10.0** and
Codex CLI **0.153.4**. The adapter is Fountain's managoat_runtimes 0.4.1 pin;
its npm dependency is `@openai/codex ^0.153.3`, so the CLI can drift even when
the adapter version stays fixed. This fixture pins both explicitly.

The probe uses an isolated Codex configuration/auth directory, a synthetic
`chatgptAuthTokens` identity, and Fountain's custom HTTP Responses provider.
It redirects that provider's base URL to a local recording HTTP origin, which
answers with synthetic SSE events. It stores header **names**, media types,
and validation booleans, never request bodies, tokens or client identifiers.
Both prompts use the same ACP session. No real provider request is intended.

Run from the repository root (Node/npm and Python 3 required):

```sh
npm install --prefix /private/tmp/fountain-codex-fixture --ignore-scripts --no-audit --no-fund \
  @agentclientprotocol/codex-acp@1.10.0 @openai/codex@0.153.4
python3 scripts/probe-codex-protected.py \
  --adapter /private/tmp/fountain-codex-fixture/node_modules/.bin/codex-acp \
  --codex /private/tmp/fountain-codex-fixture/node_modules/.bin/codex \
  > /private/tmp/codex-protected-capture.json
```

Review the resulting metadata before replacing `capture.json`. The probe fails
if versions differ, a turn does not complete, the route/method changes, the
synthetic bearer/account pair differs, or the body lacks a matching nonzero
Content-Length. ExUnit replays the captured request shape through broker 0.15's
protected policy and header preparation. This makes new required headers visible
without requiring a downloaded Codex executable during ordinary CI runs.

The observed POST is zstd-compressed JSON with Content-Length, not a chunked
request. Preserve `content-encoding` along with `content-type`; the broker forwards
the compressed body unchanged. SSE responses remain supported. The fixed policy
allows only `POST https://chatgpt.com:443/backend-api/codex/responses`, with no
query string: since broker 0.15 a target holding a `?` is refused, and the
captured client sends none. It does not grant a subtree or additional methods.

The captured client sends no `accept-encoding`. Broker 0.15 sends `identity` on
every protected request whatever the client asked for, and refuses a response in
any other `Content-Encoding`, because it searches the response for the bearer.
The probe runs against a local origin, so whether `chatgpt.com` honours
`identity` on this route is not something this fixture measures. Two hosted
turns on 2026-09-21 measured it for this client, and it does (#2479; ADR 0047,
"Measurement 6, the hosted half").

Source audit for this exact CLI version:

- [Responses endpoint](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/codex-api/src/endpoint/responses.rs)
  selects POST `/responses`, requests `text/event-stream`, and supports zstd.
- [Session headers](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/codex-api/src/requests/headers.rs)
  supplies session/thread IDs and optional subagent metadata.
- [Provider authentication](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/model-provider/src/auth.rs)
  resolves ambient ChatGPT auth for `requires_openai_auth` custom providers.

## Remaining activation gates

This is a client request-shape check and compiler regression fixture. It does
not establish real ChatGPT acceptance, token lifetime, production TLS/proxy
compatibility, compaction or every optional Codex feature. It uses a local HTTP
origin rather than the real HTTPS provider. The broker's own transport suite
covers protected TLS, HTTP-only enforcement and streaming; a controlled hosted
client/broker/provider run is still required before activation.

`ProtectedCompiler` is called by session issuance since ADR 0060 stage 3: a
broker session that may use a managed grant carries the policy compiled here,
its issuance is fenced on the grant row, and `Sessions.authorize/2` resolves
the bearer per request. None of that changes what this fixture is: a record of
one client version's request shape. The capture was taken against the
`managoat_runtimes` 0.4.1 pin named above, and the lock file has since moved
to 0.4.5, so this file asked for the probe to be re-run against the adapter
and CLI the deployed image installs, and `capture.json` refreshed, before any
grant was served through the protected path in production. **It was re-run on
2026-09-21, against codex-acp 1.10.0 and Codex CLI 0.153.4, and its output was
byte-identical to the committed `capture.json`**, so nothing was refreshed
(#2479; ADR 0047, measurement 6). The pin's move was a non-event for this
fixture: `managoat_runtimes` 0.4.5 still pins the adapter at 1.10.0, and
0.153.4 was the newest CLI that `^0.153.3` admits, so that pair is what a
provision resolved that day. Re-run it when either version moves.

The first grant on this path is the deployment's own (ADR 0047), which ADR
0060's platform move puts there. That move was gated on this re-run and on one
hosted turn, and merged on 2026-09-21 before either. A hosted first and second
turn were taken that evening and both completed. The reattached turn is still
owed (#2479; ADR 0060, "The platform move is gated on a measurement").

**What this fixture cannot see.** A new required header shows up here as a
failing replay test. A new required *route* does not: the probe records only
the provider origin it redirects the Responses call to, and a route the client
needed would be a 403 at the proxy that no test here notices. That exposure
returns with every CLI bump. What would see it is a run with the client's
whole egress recorded, like the one in #2479, which sent it through a local
proxy that refused every `chatgpt.com` route. On 1.10.0 and 0.153.4 the client
asked `chatgpt.com` for ten routes besides the allowed one and completed both
turns without any of them. ADR 0047, "Measurement 6, the offline half", lists
them.
