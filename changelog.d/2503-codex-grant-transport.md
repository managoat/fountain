### Fixed

- **A resumed Codex conversation no longer tries the WebSocket transport first**
  (#2503). Fountain runs Codex on a provider with the WebSocket transport off.
  The ACP adapter did not pass that provider to Codex when it resumed a
  conversation, so every resumed turn went back to Codex's built-in provider.
  On a ChatGPT subscription each such turn made seven refused WebSocket
  attempts, about 8 seconds, before it used HTTPS. With an API key the wait
  could reach the full connect timeout of about 300 seconds. Fountain now also
  sets `MODEL_PROVIDER`, which the adapter passes on resume. An existing
  `MODEL_PROVIDER` counts as your own choice of provider, like `model_provider`
  in `CODEX_CONFIG`.

### Changed

- **Codex on a ChatGPT subscription no longer sends analytics or loads the
  remote plugin catalog** (#2503). The credential broker refuses those routes
  for a subscription, and Codex asked for them hundreds of times an hour.
  Fountain now sets `analytics.enabled` and `features.remote_plugin` to
  `false`, unless `CODEX_CONFIG` sets them. Local plugins still load.

