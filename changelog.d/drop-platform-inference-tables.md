### Upgrade notes

- **The deployment's inference keys and ChatGPT subscription are deleted**
  (#2728, ADR 0075). A migration drops `platform_inference_keys` and deletes
  the `chatgpt_subscriptions` row that had no user. Upgrade through the
  release that removed them first, because that release stopped reading
  both. After this migration they can only be recovered from a backup.
