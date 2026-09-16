### Changed

- **An exhausted ChatGPT account no longer blocks Codex** (#2362). When a
  codex turn on the deployment's ChatGPT account fails with the account's
  usage limit, that turn still fails, but new codex conversations run on
  `PLATFORM_OPENAI_API_KEY` until the provider's reset time, billed per token
  under the daily ceiling. `/admin/inference` shows the limit and its reset
  time, and an `admin.platform_chatgpt.exhausted` event is recorded.
  Reconnecting the same account keeps the reset time; a different account
  clears it.
