### Added

- **A ChatGPT subscription that has spent its Codex usage says so, and
  nothing takes its place** (#2453). The codex turn that reaches the limit
  fails with codex's own message. Fountain then asks OpenAI with that
  subscription's token, because the report comes from the sandbox, and
  records the limit only when OpenAI confirms it. From then the
  subscription reports `exhausted_until`, and every launch and turn on it is
  `409 chatgpt_grant_unusable` with `reason: "exhausted"` and the reset time
  in `until`, until that time passes. The account's other subscriptions, the
  set's own key, the default set, an `OPENAI_API_KEY` in an environment or a
  vault and platform inference are not used instead (ADR 0060 decision 4).
  The `admission_refused` stage event carries `until` too, and the audit
  trail gains `chatgpt_grant.exhausted`. Usage is not polled: the limit is
  seen only after a turn fails on it. See
  https://managoat.com/docs/api#chatgpt-subscriptions.

- **A turn says which inference source served it** (#2453).
  `GET /api/conversations/:id/turns` gives each turn a read-only `inference`
  object: `origin` (`own` or `platform`), `scope`, and `chatgpt_grant_id`
  when a ChatGPT subscription served it. It is written when the turn starts
  and never rewritten, so repointing a credential set or reconnecting a
  subscription changes later turns only; it is null on turns from before it
  was recorded. The data export's turns carry the same object. A turn on
  the account's own subscription debits no credits and does not count toward
  the platform inference ceiling. The TypeScript and Swift SDKs' generated
  `Turn` types gain the field. See
  https://managoat.com/docs/api#conversations.
