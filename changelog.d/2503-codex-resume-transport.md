### Fixed

- **A resumed Codex conversation no longer tries the WebSocket transport first**
  (#2503). Fountain runs Codex on a provider with the WebSocket transport off.
  The ACP adapter did not pass that provider to Codex when it resumed a
  conversation, so every resumed turn went back to Codex's built-in provider,
  and waited up to the full connect timeout of about 300 seconds before it
  used HTTPS. Fountain now also
  sets `MODEL_PROVIDER`, which the adapter passes on resume. An existing
  `MODEL_PROVIDER` counts as your own choice of provider, like `model_provider`
  in `CODEX_CONFIG`.
