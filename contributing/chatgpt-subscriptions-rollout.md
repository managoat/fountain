# ChatGPT subscriptions: the rollout checklist and the controlled run

Contributor material, not published. The decision is
[ADR 0060](../decisions/0060-many-user-chatgpt-subscriptions.md); the user
guide is [docs/guides/chatgpt-subscriptions.md](../docs/guides/chatgpt-subscriptions.md).
This page is what stands between "all five stages are built" and the
`chatgpt_subscriptions` flag being on for anyone: a checklist, and the
runbook for the one item on it that only a maintainer with two real ChatGPT
subscriptions can do.

Until every item is ticked, **the flag stays off and stays out of
`@on_without_posthog`** (`Fountain.FeatureFlags`). `FEATURE_FLAGS_ON` can
force it on where the credential broker is configured; do that only on the
staging instance of the run below, never on an instance that serves people
you do not trust.

## The rollout checklist

- [x] **(a) The platform grant is on the protected path, and
  `Egress`'s token comparison is deleted.** Stage 3b, #2458, merged
  2026-09-21. It is the only piece of the stack that changes what a running
  deployment does. It carried a gate of its own, a run of
  `scripts/probe-codex-protected.py` against the image's client and one real
  hosted turn, recorded in ADR 0047, before it might merge. **That gate was
  not passed: the maintainer chose to merge without the measurement.** The
  probe was run later that day, 2026-09-21, against codex-acp 1.10.0 and
  codex-cli 0.153.4, and passed (ADR 0047, measurement 6). **The hosted
  turn is still owed**, under (c) and in #2479. It cannot run until the
  maintainer reconnects the deployment's ChatGPT account at
  `/admin/inference`: the account has been disconnected since 2026-09-16,
  so nothing has used the protected path in production, and the failure
  below cannot happen until it is reconnected. If platform-codex turns then
  fail with a 403 from the broker or with no auth file (the #2362 fallback
  stays silent, because the grant still reads `active`), revert the squash
  commit of #2458; ADR 0060, "The platform move is gated on a measurement",
  has the rest.
- [x] **(b) A `managoat_broker` hex release with Gate A and Gate B**, the pin
  bumped in `apps/fountain/mix.exs`, and `ProtectedCompiler.policy/1` setting
  the option. Ticked 2026-09-21: `managoat_broker` 0.15.0
  (managoat/managoat_broker#39), adopted by #2483. Gate A refuses (it does
  not scrub) a protected response that contains the bearer its request was
  sent with, and refuses one that arrives compressed, having asked for
  `Accept-Encoding: identity`. Gate B refuses any query string on a
  protected route, a bare `?` included. Both are library code, not
  Fountain's; ADR 0060, "Gates A and B as built", says what gate A does not
  recognise. **Unmeasured, and part of (c):** whether `chatgpt.com` honours
  `identity` on the Codex route. The recorded client sends no
  `accept-encoding` and its turns completed (ADR 0047, measurement 2), so
  the route answers that uncompressed and is expected to answer `identity`
  the same way; the hosted turn (#2479) shows it.
- [ ] **(c) Both real-client measurements pass**: the protected-path probe
  against the pinned client (which is also the measurement stage 3b merged
  without, and covers the deployment's account as well as a user's), and a symlinked `CODEX_HOME` across a reattach
  and a `thread/resume`. Steps 1 and 5 of the runbook. The probe was run
  offline on 2026-09-21 against codex-acp 1.10.0 and codex-cli 0.153.4 and
  passed. Not ticked: the hosted turn on the deployment's account that stage
  3b also owed waits on the account being reconnected (#2479), and the
  symlinked home has not been tried.
- [ ] **(d) ADR 0047's measurement 5 is recorded**, the day-9 reading (due
  2026-09-17, still "Pending") and the day-30 reading (2026-10-08), and the
  keepalive interval is confirmed or changed from them. Six days is the
  platform grant's guess. The margin it leaves is thin: a first keepalive
  attempt can come 7 days 6 hours after the last renewal.
- [ ] **(e) The keepalive has been observed for 7 days with zero unexpected
  `reconnect_required`.** Watch `fountain_chatgpt_keepalive_sweep_due`,
  `fountain_chatgpt_keepalive_grant_count` by `result`,
  `fountain_chatgpt_refresh_rate_limited_count`,
  `fountain_chatgpt_refresh_breaker_opened_count` and
  `fountain_chatgpt_refresh_breaker_closed_count`, the
  `chatgpt_grant.reconnect_required` audit events, and any `error` line that
  starts `chatgpt keepalive:`.
- [ ] **(f) The PostHog release**: staff, then 5%, then everyone.
  `@on_without_posthog` only after that, if at all.
- [ ] **(g) Rollback is the flag.** Off, nobody can link a new subscription;
  the grants people hold stay listable, renamable, reconnectable,
  disconnectable and removable, and the keepalive goes on renewing them.
  Confirm that on staging before (f).

Accepting ADR 0060 is the maintainer's decision and is not an item here. Its
status stays Proposed until they change it.

## The maintainer runbook: the controlled run

ADR 0060's implementation item 5 ends: "a real link of two subscriptions, a
Codex turn on each, a forced refresh between turns, restart, and disconnect,
in a controlled environment, with pinned versions recorded." This is that
run. It needs two ChatGPT subscriptions you own, called A and B below, and a
staging instance with the credential broker configured.

**Pin and record first**, in the "Measured" table of ADR 0060: the versions
of `managoat_runtimes`, `managoat_broker`, codex-acp and the codex CLI, and
the runtime image's digest. A result with no versions beside it measures
nothing.

1. **Re-run `scripts/probe-codex-protected.py` against the pinned client.**
   Review `apps/fountain/test/fixtures/codex_protected/capture.json` against
   what it captures, replace it if the shape moved, and update the README
   beside it. **Done on 2026-09-21 for codex-acp 1.10.0 and CLI 0.153.4**,
   the pair `managoat_runtimes` 0.4.5 resolved that day: the output was
   byte-identical to the fixture in the tree, so nothing was replaced (ADR
   0047, measurement 6). Do it again only if either version has moved by
   the day of the run. The probe cannot see a route the client needs beyond
   the allowed one; step 3 can.
2. **Staging with `FEATURE_FLAGS_ON=chatgpt_subscriptions`.** Link A and B.
   Make two credential sets, one naming each, and two agents, one on each
   set, in **one shared sandbox**.
3. **A turn on each agent.** From `broker_requests`, record the hosts, the
   routes, the `injected` counts and any refused request. A refused request
   that codex needed is a finding; so is a host nobody expected. **Refused
   requests to `chatgpt.com` are expected on every codex turn.** Offline, on
   1.10.0 and 0.153.4, the client asked for ten ambient routes besides the
   allowed one, about 29 requests over two turns, GET and POST, and
   completed both turns with all of them refused (ADR 0047,
   ["Measurement 6, the offline half"](../decisions/0047-codex-platform-chatgpt-account.md#measurement-6-the-offline-half)).
   Compare `/admin/broker`'s denied rows for `chatgpt.com` against that
   table. The request log stores no path, so the comparison is by method and
   count. Only a failed turn, or refusals that do not fit the table, is
   news; to name a new route, record the client's egress as #2479 did.
   **Three endings at `/admin/broker` are news whenever they appear**, on
   this run or after it, all on `chatgpt.com` rows:
   - `502 protected_response_encoded`, under Failed: the origin answered
     the Codex route compressed although the broker asked for
     `Accept-Encoding: identity`, and the broker refused it unread because
     it cannot search a compressed body for the token. Every codex turn on a
     subscription or on the deployment's account fails while this lasts.
     There is no switch; it is a `managoat_broker` change. Record the row
     and stop the run.
   - `credential_reflected`, under Failed, with a `502` or with the status
     the origin sent: a response repeated the token its request carried, and
     the broker cut it before the sandbox got the token. This is a security
     event, not a fault of the turn. The server log has one `error` line a
     minute per conversation that starts `broker: the response to`; it names
     the conversation, the host and the rule and never the token. Find out
     what answered (the origin, or an error page in front of it), and treat
     the grant as exposed to whatever that was: disconnect it and link it
     again.
   - `403 protected_query`, under Denied: something in the sandbox put a
     query string on the Codex route. The pinned client sends none, so this
     is either a client that changed (re-run step 1) or an agent probing the
     route. Nothing was sent to the origin.
4. **Force a refresh of A.** Nothing in the product does this, so it is a
   SQL UPDATE, **on the STAGING database only, never production**: put A's
   `access_expires_at` inside the fifteen-minute refresh margin, then run a
   turn on A.

   ```sql
   -- staging only
   UPDATE platform_chatgpt_account
      SET access_expires_at = now() + interval '5 minutes'
    WHERE id = '<A''s grant id>' AND user_id = '<your user id>';
   ```

   A's `generation` is unchanged, its `lock_version` is one higher, and B's
   row is untouched.
5. **Reattach, and `thread/resume` through the symlinked home.** Do
   `sessions/` and `skills/` resolve? Did `config.toml` become a real file
   (an atomic-rename writer replacing the link)? If the symlinked home does
   not hold, the fix is a `managoat_runtimes` release that lets
   `Layout.config_root/1` take an override, and item (c) is not ticked.
6. **Restart the server**, then a turn on each.
7. **Disconnect A while a tunnel is open.** The next request on it is
   refused, and B still serves. Then sign A's device out in the ChatGPT
   account: Fountain cannot revoke a sign-in at OpenAI.
8. **Optional: exhaust a grant, or stub `/wham/usage`**, and watch the card
   turn to "Usage spent" and the next launch be refused with `until`.

**Observe, while you are there: how the auth server throttles.** Whether
`auth.openai.com` throttles by address or by account is unmeasured, and so
is what a refusal looks like. The keepalive's breaker
(`ChatGPTAccounts.RefreshBreaker`) is built on guesses about both:

- It takes a 429, or a 403 whose body is **not a JSON object** (an HTML
  page, nothing, a bare string), as evidence of a throttled address. A 403
  with a JSON object body, a code in it or not, it takes as that account's
  own failure. If the auth server throttles an address with a JSON 403, the
  breaker never opens for it; if it refuses one account with an HTML 403,
  that refusal counts as evidence it should not.
- It opens only when two different owners were refused inside ten minutes,
  lets one probe through per node per fifteen minutes, and closes on any
  renewal that succeeds.

Do not provoke a throttle on purpose against an address production shares.
If one happens, record: the status; the content type and whether the body
was a JSON object, and if so its keys (never its values); whether B was
refused while A was; and whether
`fountain_chatgpt_refresh_breaker_opened_count` and
`fountain_chatgpt_refresh_breaker_closed_count` moved. If throttling follows
the account, the two-owner rule is what keeps one account from pausing
everyone; if it follows the address, the rule costs one extra refused call
before the pause. Either reading belongs in the ADR.

**Where results go.** One row per gate in ADR 0060's
["Measured" table](../decisions/0060-many-user-chatgpt-subscriptions.md#measured),
with the pins and the date. The idle-lifetime readings and their pins go in
ADR 0047's measurement table, row 5. The 3b measurement, which was not
taken before #2458 merged, goes in ADR 0047's table too, row 6; its offline
half is there, and the hosted turn of #2479 goes beside it. A gate that fails is recorded as failed, with what was
seen; it is not left blank.
