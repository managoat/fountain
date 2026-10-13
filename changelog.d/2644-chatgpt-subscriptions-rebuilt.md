### Upgrade notes

- **Link ChatGPT subscriptions again after deploying** (#2644). None of the
  subscriptions removed in #2642 carries over. Each account links its own
  again at `/account/inference-credentials`, and an admin links the
  deployment's at `/admin/inference`. A subscription is used only when the
  egress broker is configured (`BROKER_LISTEN_PORT`).

### Added

- **Codex on a ChatGPT subscription, rebuilt small** (#2644, ADR 0070). Each
  account can link one ChatGPT subscription, by a device code or by pasting
  the `auth.json` from `codex login`, and an admin can link one for the
  deployment. A codex run on an `openai/` model uses the account's own,
  else the deployment's, before any OpenAI API key. The broker substitutes
  the access token on `chatgpt.com`, and the sandbox holds a placeholder. A
  daily job at 04:29 UTC refreshes any subscription idle for six days. A
  turn only re-reads the stored token, unless that token has expired or
  expires within ten minutes. A turn on the account's subscription reports
  `inference.scope: "grant"`. A conversation whose subscription was
  disconnected, refused by OpenAI or linked to another account gets
  `409 chatgpt_reconnect_required`. See
  https://managoat.com/docs/guides/chatgpt-subscription.
