### Security

- **The egress broker refuses a response that repeats a ChatGPT account's
  token** (#2483, ADR 0060 gate A, `managoat_broker` 0.15.0). A codex
  conversation on the deployment's ChatGPT account, or on a linked ChatGPT
  subscription, never holds the account's access token: the broker adds it
  to the one request that carries it. That left one way for a sandbox to
  get it, which was a response that repeated it, from the origin or from an
  error page in front of the origin. The broker now searches every response
  on that route for the token its request went out with, the status line
  and headers first and the body as it streams, across chunk boundaries. On
  a match it forwards nothing more and closes the connection. The sandbox
  gets a fixed `502` where none of the response had been sent, and a cut
  stream otherwise. The request's row in the egress log and at
  `/admin/broker` reads `credential_reflected`, and the server logs one
  `error` line a minute per conversation that starts `broker: the response
  to`, naming the conversation, the host and the rule and never the token.
  It raises no alert and writes no audit event. The broker finds the token's
  exact bytes, `Bearer <token>` included, and its JSON spelling with `\/`.
  It does not find a base64, hex or percent-encoded copy, a partial copy, a
  body compressed without a `Content-Encoding` header, or a copy served on
  another connection. There is no setting that turns this off. Responses on
  every other route are relayed as before.

- **A query string on that route is refused** (#2483, ADR 0060 gate B).
  `POST https://chatgpt.com/backend-api/codex/responses?<anything>` from a
  sandbox used to go out under the token, because only the path was matched.
  It is now a `403` with `protected_query` in the egress log, a bare `?`
  included, decided before the token is read and with nothing sent to
  `chatgpt.com`. The Codex client sends no query, so a turn does not meet it.

### Changed

- **Requests on that route go to `chatgpt.com` with `Accept-Encoding:
  identity`, whatever the client sent** (#2483), because the broker cannot
  search a compressed body for the token. A response that arrives in any
  other `Content-Encoding` anyway is refused unread with a `502` and
  `protected_response_encoded`. The Codex client Fountain pins (codex-acp
  1.10.0, Codex CLI 0.153.4) sends no `Accept-Encoding` and reads an
  uncompressed stream, so nothing is expected to change for it. That
  `chatgpt.com` honours `identity` on this route has not been measured
  (#2479). If it does not, codex turns on a ChatGPT account fail and their
  rows at `/admin/broker` read `502 protected_response_encoded`; turns on an
  API key are not affected. Disconnecting the account at `/admin/inference`
  moves the deployment's codex conversations back to
  `PLATFORM_OPENAI_API_KEY`.
