### Security

- **The deployment's ChatGPT account is no longer exportable through the
  egress broker** (#2458, ADR 0052 decisions 5 and 6). A codex conversation
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

- **Release gate, not yet passed, and the measurement is still owed: this
  change has not run against a real codex client** (#2458). It was written
  not to merge or deploy until `scripts/probe-codex-protected.py` had been
  run against the codex-acp and Codex CLI the sandbox image installs and one
  real hosted codex turn on the deployment's account had succeeded, with the
  result recorded in ADR 0047. That measurement was not taken before the
  merge; merging without it was the maintainer's decision on 2026-09-21. If
  the installed client needs a second `chatgpt.com` route, or does not read
  `CODEX_HOME`, every codex turn on the account fails, with a 403 from the
  broker or with codex finding no auth file, and the fallback to
  `PLATFORM_OPENAI_API_KEY` does not happen, because the account is still
  active and not out of usage. Disconnecting the account at
  `/admin/inference` is the quick way out; the rollback is to revert this
  change, whose migration has nothing to undo, after which a conversation
  mints a session of the old kind when its server next starts. Remove this
  note when the measurement is recorded.

- **A codex conversation on the deployment's ChatGPT account cannot open a
  WebSocket through the broker any more, to any host** (#2458). The session
  is HTTP only, which is what stops a raw client in the sandbox from
  upgrading its way past the per-request check. Plain HTTP and streamed
  responses are unchanged. Codex itself is already configured without
  WebSockets on this path. Conversations on an API key are not affected.

- **`chatgpt.com` is reachable from such a conversation on one route only**,
  `POST /backend-api/codex/responses` (#2458). Anything else on that host is
  refused with a 403. The route list was captured against codex-acp 1.10.0
  and Codex CLI 0.153.4. Re-run `scripts/probe-codex-protected.py` against
  the client your sandbox image installs before upgrading a deployment that
  relies on the account.

- **A secret binding that matches that route now fails the provision**
  (#2458) with `managed_destination_conflict`, where it used to be silently
  shadowed. Wildcards count: a binding for `*.com` matches. A binding or a
  secret that names `CODEX_CHATGPT_ACCESS_TOKEN` is already refused when it
  is written; a row that predates that check now fails the provision with
  `managed_credential_conflict`. Remove the binding.

- **A `CODEX_HOME` of your own is ignored in a codex conversation on the
  deployment's ChatGPT account** (#2458). Fountain sets `CODEX_HOME` for such
  a conversation, to the directory that holds the account's `auth.json`, and
  drops one named in the environment's variables, its secrets or a vault,
  without an error. It used to be passed through. Conversations on an API
  key keep theirs.

- **Migration `20260921025746` deletes the broker sessions of codex
  conversations on the account** (#2458), because they hold the token as a
  rule. A turn on the account that is in flight across the upgrade fails at
  its next request with a 407. Every conversation mints a new session when
  its server starts on the new release, so the next turn runs.

- **Expect codex turns on the deployment's account to fail until every
  replica runs this release** (#2458). Roll quickly, or stop every replica
  and start the new release. Any replica's broker can serve any sandbox, and
  the two releases disagree about these sessions in both directions:
  - *A session from the previous release, served by this one.* The
    migration runs once. A replica still on the previous release can write
    a session of the old kind after it, by minting one, or, when the
    account's token rotates, by rewriting the rules of a conversation's live
    sessions with the new token. A replica on this release refuses such a
    session with a 407 and deletes it the first time a request presents it.
    A replica on the previous release still serves it in full, WebSockets
    and header templates included, so the exposure this release closes stays
    open until the last old replica is gone.
  - *A session from this release, served by the previous one.* The old
    broker does not know the session records a grant. It treats it as an
    ordinary session, forwards the sandbox's placeholder to `chatgpt.com` as
    the bearer, and the provider answers 401. It does not enforce HTTP only
    either. No token leaks, because the session holds none, and the turn
    fails.
  - *No recovery on an old replica.* A conversation whose server is still on
    the previous release and whose session was deleted gets no working
    session until that replica is rolled: the previous release replaces a
    session only when a secret changes or the session is near its expiry,
    not after a 407, and what it mints is a session of the old kind again.
