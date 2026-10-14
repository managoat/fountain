### Upgrade notes

- **Platform inference keys need credential brokerage** (#2674). Fountain
  offers `PLATFORM_ANTHROPIC_API_KEY`, `PLATFORM_OPENAI_API_KEY`,
  `PLATFORM_GEMINI_API_KEY` and the `/admin/inference` keys only when
  `BROKER_LISTEN_PORT` is set. On a deployment without the broker they go
  unused: an account with no credential of its own must add one. Boot logs a
  warning and `/admin/inference` shows a notice while that is the case.

### Security

- A platform inference key no longer reaches an unbrokered sandbox in
  plaintext (#2674). An account's own credentials are unchanged.
