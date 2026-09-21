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
  not passed: the maintainer chose to merge without the measurement**, and
  it is still owed, under (c) and as ADR 0047's measurement 6. If
  platform-codex turns fail with a 403 from the broker or with no auth file
  (the #2362 fallback stays silent, because the grant still reads
  `active`), revert the squash commit of #2458; ADR 0060, "The platform move
  is gated on a measurement", has the rest.
- [ ] **(b) A `managoat_broker` hex release with Gate A and Gate B**, the pin
  bumped in `apps/fountain/mix.exs`, and `ProtectedCompiler.policy/1` setting
  the option. Gate A scrubs or refuses a protected response that contains the
  bearer its request was sent with. Gate B refuses a non-empty query string on
  a protected route. Both are library code, not Fountain's (ADR 0060, "Stage
  3 as built"). Neither exists yet.
- [ ] **(c) Both real-client measurements pass**: the protected-path probe
  against the pinned client (which is also the measurement stage 3b merged
  without, and covers the deployment's account as well as a user's), and a symlinked `CODEX_HOME` across a reattach
  and a `thread/resume`. Steps 1 and 5 of the runbook.
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
   beside it. The fixture in the tree is from codex-acp 1.10.0 and CLI
   0.153.4, before the current `managoat_runtimes` pin.
2. **Staging with `FEATURE_FLAGS_ON=chatgpt_subscriptions`.** Link A and B.
   Make two credential sets, one naming each, and two agents, one on each
   set, in **one shared sandbox**.
3. **A turn on each agent.** From `broker_requests`, record the hosts, the
   routes, the `injected` counts and any refused request. A refused request
   that codex needed is a finding; so is a host nobody expected.
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
taken before #2458 merged, goes in ADR 0047's table too, row 6. A gate that fails is recorded as failed, with what was
seen; it is not left blank.
