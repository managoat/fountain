### Upgrade notes

- **A new daily job and a new Oban queue, no operator action** (#2453).
  `Fountain.Workers.ChatGPTKeepaliveSweep` runs at 04:37 UTC on the
  `maintenance` queue. It reads ids only, and queues one job on the new
  `chatgpt_refresh` queue for every linked ChatGPT subscription nobody has
  renewed for six days. Each of those jobs makes one call to
  `https://auth.openai.com/oauth/token`, and they are spread over a window
  sized from how many are due: five seconds a subscription, no shorter than
  five minutes, no longer than six hours. The queue runs two at a time per
  replica, below the four renewals a replica allows at once, so a running
  conversation's renewal is never crowded out. It is idle wherever nobody
  has linked a subscription, and the deployment's own grant keeps its 04:29
  job. If the auth server answers 429, or a 403 that names no reason, that
  replica's keepalive jobs wait fifteen minutes before asking again. To
  observe it: `fountain_chatgpt_keepalive_sweep_due` is what the last sweep
  found idle, `fountain_chatgpt_keepalive_grant_count` counts the jobs by
  `result` (`ok`, `cancelled`, `snoozed`, `rate_limited`, `error`), and
  `fountain_chatgpt_refresh_rate_limited_count` counts the refusals; a
  subscription the auth server refused for good shows as "Reconnect
  required" on its owner's card and as a `chatgpt_grant.reconnect_required`
  audit event. The six days are provisional on ADR 0047's measurement 5.

### Added

- **An idle ChatGPT subscription is kept alive** (#2453). A subscription its
  owner has not used for six days is renewed by a daily job, so it no longer
  lapses at OpenAI's idle window. One subscription's failure touches no
  other, including another of the same account's: a refresh token OpenAI
  refuses marks that one subscription "Reconnect required" and the rest are
  renewed as usual. Linking stays behind the `chatgpt_subscriptions` flag.

- **An account export lists ChatGPT subscriptions and sign-ins** (#2453).
  Two new sections, `chatgpt_subscriptions` and `chatgpt_link_attempts`,
  carry what the owner sees on the card: a subscription's name, state, plan,
  the email OpenAI reported, its times and the credential sets that name it,
  and what each sign-in of the last week was for and how it ended. Tokens,
  ciphertext, OpenAI's account id, a sign-in's user code and device id are
  never exported. The document's `version` is unchanged: the sections are
  additions.

### Changed

- **Deleting an account counts the ChatGPT subscriptions it removes, and the
  confirmation email says what it could not do** (#2453). The subscriptions,
  their sign-ins and their broker sessions already went with the account;
  `account.deleted` now records `chatgpt_grants_removed`. Fountain deletes
  its copy of each sign-in and has no way to revoke one at OpenAI, so for an
  account that had linked any, the email says so and tells the person to
  sign the device out in their ChatGPT account. Jobs still queued for a
  deleted account's subscriptions end without calling OpenAI.
