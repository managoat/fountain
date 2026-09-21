### Security

- **The deployment's ChatGPT account is no longer exportable through the
  egress broker** (#2453, ADR 0052 decisions 5 and 6). A codex conversation
  on the account (`/admin/inference`) used to carry the account's access
  token inside its broker session as a substitution rule. A custom header
  template could name it, nothing checked it again after the session was
  minted, and a disconnect reached a running conversation only at its next
  turn. The broker session now records which grant it may use and holds no
  token. The broker asks Fountain for the token on every request, including
  inside a tunnel that is already open, and only for `POST
  https://chatgpt.com/backend-api/codex/responses`. The token is never in a
  conversation's process, in a stored rule, or available to a binding. A
  disconnect, a reconnect or a revocation takes effect on the next request,
  on every node. Each grant writes its `auth.json` into a `CODEX_HOME` of
  its own in the sandbox instead of the shared `~/.codex/auth.json`.

### Upgrade notes

- **A codex conversation on the deployment's ChatGPT account cannot open a
  WebSocket through the broker any more, to any host** (#2453). The session
  is HTTP only, which is what stops a raw client in the sandbox from
  upgrading its way past the per-request check. Plain HTTP and streamed
  responses are unchanged. Codex itself is already configured without
  WebSockets on this path. Conversations on an API key are not affected.

- **`chatgpt.com` is reachable from such a conversation on one route only**,
  `POST /backend-api/codex/responses` (#2453). Anything else on that host is
  refused with a 403. The route list was captured against codex-acp 1.10.0
  and Codex CLI 0.153.4. Re-run `scripts/probe-codex-protected.py` against
  the client your sandbox image installs before upgrading a deployment that
  relies on the account.

- **A secret binding that matches that route now fails the provision**
  (#2453) with `managed_destination_conflict`, where it used to be silently
  shadowed. Wildcards count: a binding for `*.com` matches. A binding or a
  secret that names `CODEX_CHATGPT_ACCESS_TOKEN` is already refused when it
  is written; a row that predates that check now fails the provision with
  `managed_credential_conflict`. Remove the binding.

- **Migration `20260921025746` deletes the broker sessions of codex
  conversations on the account** (#2453), because they hold the token as a
  rule. A turn on the account that is in flight across the upgrade fails at
  its next request with a 407. Every conversation mints a new session when
  its server starts on the new release, so the next turn runs. Roll every
  replica: a replica still on the previous release can mint one more session
  of the old kind, which lasts until it expires (six hours at most) and is
  never renewed.
