### Changed

- **Codex on a ChatGPT subscription sends no analytics by default, and the
  broker allows analytics when it is on** (#2503). When Fountain prepares a
  subscription's `CODEX_HOME` and it has no `config.toml`, Fountain now writes
  one with `[analytics] enabled = false`. Fountain does not change a
  `config.toml` that exists, and that includes one linked from
  `~/.codex/config.toml`. The broker now also allows
  `POST https://chatgpt.com/backend-api/codex/analytics-events/events` for a
  subscription. Before this change the broker refused each of those
  requests, and each refusal closed a connection: several hundred an hour on
  a busy sandbox.
