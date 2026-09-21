### Added

- **A ChatGPT subscription that has spent its Codex usage says so, and
  nothing takes its place** (#2461). The codex turn that reaches the limit
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
  seen only after a turn fails on it, and OpenAI is asked at most once in
  five minutes for each subscription, so a request that fails delays the
  detection by up to five minutes. The **ChatGPT subscriptions** card and the
  set's picker change to **Usage spent** with the reset time on an open page,
  and back to **Connected** when the time passes. No email or webhook says a
  plan is spent. See https://managoat.com/docs/api#chatgpt-subscriptions.

- **A turn says which inference source served it** (#2461).
  `GET /api/conversations/:id/turns` gives each turn a read-only `inference`
  object: `origin` (`own` or `platform`), `scope`, and `chatgpt_grant_id`
  when a ChatGPT subscription served it. It is written when the turn starts
  and never rewritten, so repointing a credential set, reconnecting a
  subscription or a restart changes later turns only; it is null on turns from before it
  was recorded. The data export's turns carry the same object. A turn on
  the account's own subscription debits no credits and does not count toward
  the platform inference ceiling. The TypeScript and Swift SDKs' generated
  `Turn` types gain the field. See
  https://managoat.com/docs/api#conversations.

### Fixed

- **`/start`, the agent form and the credential set's picker say when a named
  ChatGPT subscription is spent** (#2461). They already said when it was
  disconnected, revoked or expired. A spent plan was not among those states,
  because nothing recorded a usage limit on an account's own subscription.
  Now they read it from the same resolution that refuses the run, with the
  reset time that the `409` gives.

- **A conversation server that cannot start on its ChatGPT subscription says
  which one and why** (#2461). A server that starts without a prompt in
  front of it, such as one that reattaches a running turn after a restart,
  published `tenant_credential_load_failed` with an internal term when its
  named subscription could not serve. The stage event now carries
  `reason: "chatgpt_grant_unusable"`, `grant_reason`, `grant_id`, the
  sentence the `409` uses and, at a usage limit, `until`.
