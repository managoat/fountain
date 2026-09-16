### Changed

- **An exhausted ChatGPT account no longer blocks Codex** (#2362). When a
  codex turn on the deployment's ChatGPT account fails with the account's
  usage limit, that turn still fails, and Fountain asks ChatGPT for the
  account's usage with the account's own token (at most once every five
  minutes). Only when ChatGPT confirms the limit do new codex conversations
  run on `PLATFORM_OPENAI_API_KEY` until ChatGPT's reset time, billed per
  token under the daily ceiling. An error reported from a sandbox alone
  changes nothing. `/admin/inference` shows the limit and its reset time,
  and an `admin.platform_chatgpt.exhausted` event is recorded. Reconnecting
  the same account keeps the reset time; a different account clears it.
