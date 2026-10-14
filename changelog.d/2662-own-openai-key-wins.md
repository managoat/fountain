### Upgrade notes

- **A codex conversation that ran on the deployment's ChatGPT subscription
  while its account held an OpenAI API key now gets
  `409 inference_source_changed` on its next prompt** (#2662). The account's
  own key now outranks the deployment's subscription, and a conversation never
  moves to another credential. Start a new conversation, which runs on the
  account's key. An account that wants the deployment's subscription removes
  its own key.

### Fixed

- The deployment's ChatGPT subscription no longer beats an account's own
  OpenAI API key for codex (#2662). The order is now the account's own
  subscription, then its own key (saved on Inference credentials, or
  `OPENAI_API_KEY` in the conversation's environment or vault), then the
  deployment's subscription, then `PLATFORM_OPENAI_API_KEY`. See
  [Run Codex on a ChatGPT subscription](https://managoat.com/docs/guides/chatgpt-subscription).
- A conversation on a ChatGPT subscription that is still linked is no longer
  told `chatgpt_reconnect_required` when it is refused because the account's
  own key now outranks the subscription. It gets `inference_source_changed`
  (#2662).
