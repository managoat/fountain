### Fixed

- Streaming output is no longer delayed by a conversation's own identifiers.
  The redaction registry now holds the conversation's secrets alone — the
  environment and vault values, the inference credential, the callback token,
  the brokered credentials and the broker session token — instead of the whole
  sandbox environment, so a reply chunk waits only when it could begin a
  secret. A conversation id, a sandbox id, a sandbox URL or a broker
  placeholder printed by an agent is no longer shown as `[REDACTED]` (#2366).
