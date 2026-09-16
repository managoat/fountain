### Fixed

- **A brokered credential no longer appears in conversation output.** A secret
  bound to an egress binding is deliberately kept out of the sandbox: the
  broker swaps it for a placeholder and injects the real value at the proxy
  (ADR 0019). Output redaction is built from what the sandbox environment
  holds, so the one credential the sandbox never holds was the one value never
  scrubbed. An upstream that echoed the header back — a debug endpoint, a
  verbose error, a request mirror — returned it as ordinary tool output, and
  that was persisted verbatim in the conversation's log events and served on
  its stream. Brokered values are now registered for redaction alongside the
  sandbox environment, so an echoed credential reads `[REDACTED]` like any
  other secret.

  That holds after a rotation too. Editing a bound vault secret or refreshing
  a connection token takes effect on a running conversation's next turn, and
  that refresh now registers the new value before the broker can inject it.
  A conversation also keeps redacting every credential it has held until it
  ends, so output produced under the old value is still scrubbed if it
  arrives after the rotation.

  This affects any deployment with brokered egress and at least one secret
  binding, and was found by the deployed-instance suite's `secrets` profile
  running against production (#1614). It is not a cross-tenant disclosure: the
  conversation, its events and its stream are scoped to the account that owns
  the credential. What it fixes is the credential sitting in plaintext in
  `log_events` — a table without the envelope encryption the secret itself
  has — and being served through the conversation's history and stream, to
  the Conversations app and to anything else reading output through Fountain.

  **What it does not change:** the agent itself still sees an echoed
  credential. The echo arrives inside the sandbox, where the runtime reads the
  tool's output and hands it to the model before Fountain persists anything,
  and redaction applies only at that later point. Brokering keeps a credential
  out of the sandbox's environment and files; it cannot stop an upstream from
  handing that credential back to the agent in a response. Bind a secret only
  to hosts that do not return it.
