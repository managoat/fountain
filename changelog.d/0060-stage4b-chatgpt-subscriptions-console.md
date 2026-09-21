### Added

- **The ChatGPT subscriptions card** (#2453) on
  `/account/inference-credentials`: link a subscription with a device code,
  see each one's state, plan and email, and rename, reconnect, disconnect
  and remove it. A reload shows the same pending code, the page updates
  by itself when the sign-in completes, and for half an hour the card says
  how a sign-in ended, also on a page that was not open when it did. A **ChatGPT subscription** row names
  the subscription a credential set's `codex` runs use. The feature is in
  development and off for every account: the card appears only where the
  `chatgpt_subscriptions` flag and the credential broker are on, or for an
  account that already holds a subscription, which can always rename,
  reconnect, disconnect and remove it. See
  https://managoat.com/docs/guides/chatgpt-subscriptions.

### Fixed

- **`/start` and the agent form say when a named ChatGPT subscription
  cannot serve** (#2453). For a `codex` agent on a credential set whose
  subscription is disconnected, revoked or expired, on a
  deployment with no credential broker, or for an account that is suspended, `/start` no longer implies the
  launch will work, and the agent form shows the reason instead of asking
  for an OpenAI key that the run would not use.

- **The dashboard's provider checklist counts a credential set that names a
  connected ChatGPT subscription** (#2453), as it counts a stored key.
