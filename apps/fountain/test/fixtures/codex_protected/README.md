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
Content-Length. ExUnit replays the captured request shape through broker 0.14's
protected policy and header preparation. This makes new required headers visible
without requiring a downloaded Codex executable during ordinary CI runs.

The observed POST is zstd-compressed JSON with Content-Length, not a chunked
request. Preserve `content-encoding` along with `content-type`; the broker forwards
the compressed body unchanged. SSE responses remain supported. The fixed policy
allows only `POST https://chatgpt.com:443/backend-api/codex/responses`, including
unchanged queries. It does not grant a subtree or additional methods.

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

ProtectedCompiler is not called by session issuance. Before adoption, implement
durable owner/generation/session fencing and per-request authorization, preserve
source-specific runtime auth homes, preflight existing reserved configuration,
drain legacy sockets on every serving node, and verify the deployed CLI version.
Migrate the existing platform path before enabling user linking. Until then the
legacy platform compiler remains in service; this PR does not claim to secure
existing managed sessions.
