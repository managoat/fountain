### Upgrade notes

- **The deployment no longer pays for inference** (#2728, ADR 0075). The
  platform keys (`PLATFORM_ANTHROPIC_API_KEY`, `PLATFORM_OPENAI_API_KEY`,
  `PLATFORM_GEMINI_API_KEY` and keys set at `/admin/inference`) and the
  deployment's ChatGPT subscription are removed. Each account runs on its own
  credentials: codex on the account's own ChatGPT subscription, else its own
  OpenAI key; every other runtime on its own credential. Unset the
  `PLATFORM_*_API_KEY` variables; boot warns while one is set. A
  conversation that was running on a deployment credential gets
  `409 inference_source_changed` at its next prompt: start a new one on your
  own credential.
- **A turn's `inference` object loses `origin`, and `scope` loses
  `platform`** (#2728). A turn that ran on a deployment credential now reports
  `inference: null`. The TypeScript SDK's generated types follow in its next
  major version.

### Removed

- `/admin/inference`, its tab, and the `admin.platform_inference_key.*` and
  `admin.platform_chatgpt.*` audit events (#2728).
