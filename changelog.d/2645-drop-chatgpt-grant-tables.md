### Upgrade notes

- **A migration drops the ChatGPT grant tables and columns** (#2645).
  Migration `20261013160000` drops `platform_chatgpt_account`,
  `chatgpt_link_attempts`, `inference_credentials.chatgpt_grant_id` and the
  `managed_*` columns of `broker_sessions`, which the release that removed
  ChatGPT subscriptions (#2642) left in place, unread, for one release. It
  also deletes any unfinished job of the removed ChatGPT workers. Take it only
  once that release is fully rolled out: a rolling deploy straight from an
  older release would fail its old replicas' provisions until they are
  replaced. The stored ChatGPT sign-ins are deleted with the table; nothing
  revokes them at OpenAI.
