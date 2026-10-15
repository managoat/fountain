---
type: ADR
title: "One ChatGPT subscription per user, on the ordinary broker path"
description: "Codex runs on the user's own ChatGPT subscription, else the user's own OpenAI key; the broker substitutes the access token, refreshed only near expiry or in a daily keepalive, and revoked whenever Managoat lets go of it."
tags: [inference, codex, oauth, broker, security]
status: stable
adr: "0070"
adr_status: "Accepted"
date: 2026-10-13
---

# 0070 — One ChatGPT subscription per user, on the ordinary broker path

**Status:** Accepted, 2026-10-13. Built in #2644 and shipped in v0.22.0. The
deployment's subscription that the title names was removed on 2026-10-15 by
[0075](0075-no-deployment-paid-inference.md); each user has at most one.

## Context

Managoat ran codex on ChatGPT plans twice before.
[0047](0047-codex-platform-chatgpt-account.md) put the deployment's own
ChatGPT account behind the broker. [0052](0052-user-owned-chatgpt-grants.md)
and [0060](0060-many-user-chatgpt-subscriptions.md) let each user link several
subscriptions. All three were built for a hosted service with many tenants:
platform-lent grants, several grants per user with selection and generations,
a refresh coordinator, a circuit breaker, two keepalives and a sweep, durable
link attempts as jobs with abuse limits, server-confirmed usage exhaustion, a
protected broker path that hid the bearer even from its owner, and a feature
flag. That came to about 7,700 lines of server code and 15,500 of tests.
#2642 removed it all and retired the three ADRs.

Managoat is a self-hosted application with a couple of users. The maintainer
decided on 2026-10-13 to keep the feature in a small form, with the rule from
before that the bearer never enters the sandbox.

## Decision

1. **One row per user.** `chatgpt_subscriptions` holds at most one row per
   user (`user_id` not null). The row has the account id, the ChatGPT user id
   and plan type (the three claims codex reads from an `id_token`), both
   tokens as ciphertext under the user's DEK with an AAD that names the owner,
   the row and the field, the access token's expiry, when it was last
   refreshed, a refresh lease, and a status of `active` or `revoked`. Linking
   again replaces the tokens on the same row. Disconnecting deletes the row,
   and deleting the account deletes it by cascade.

2. **Which credential codex uses.** For a codex run on an `openai/` model the
   resolver takes the user's own active subscription, then the user's own
   OpenAI key (the credential record's, or `OPENAI_API_KEY` in the
   conversation's environment or vault). The subscription wins because the
   user linked it to be used. Subscriptions are used only when the egress
   broker is configured ([0019](0019-egress-credential-brokerage.md)), since
   without it the token would have to enter the sandbox. An empty or unusable
   key is `inference_credential_unusable`, as for every other provider.

3. **The ordinary broker path.** The access token is an inference credential
   under the broker key `CODEX_CHATGPT_ACCESS_TOKEN`, with an implicit
   substitute rule on `chatgpt.com`, like every other inference credential on
   its provider's host. The sandbox gets the placeholder. Managoat writes the
   conversation's own `~/.codex/auth.json`
   ([0073](0073-one-sandbox-per-conversation.md)) in `chatgptAuthTokens` mode
   (codex treats the tokens as externally managed and never refreshes them)
   with the placeholder as the access token, the real account id, an empty
   refresh token, and an `id_token` synthesised from the three stored claims.
   The real `id_token`, which carries the account's email, never leaves the
   server. Codex is given a provider of Managoat's own that points at the
   Codex backend with WebSockets off, `MODEL_PROVIDER` pins it for
   `thread/resume`, and the ACP peer does not use codex-acp's api-key
   `authenticate` method. Those three transport points are kept from #2503.

4. **When Managoat talks to auth.openai.com.** Before each turn it only
   re-reads the stored access token and puts it in the broker's rule
   (`Egress.refresh_before_turn/1`), a database read, not a token exchange.
   It exchanges tokens in three cases only: when a user links a subscription;
   in the daily keepalive, `Fountain.Workers.ChatGPTKeepalive` at 04:29 UTC,
   which refreshes each active subscription last refreshed more than six days
   ago (an access token lives about ten); and, as a safety net before a turn,
   only when the stored access token has expired or expires within ten
   minutes.

5. **Refreshing takes a lease, not a transaction.** One conditional `UPDATE`
   sets `refresh_lease_until` to sixty seconds from the database's `now()`,
   only when the row is active, has not been refreshed since the caller read
   it, and holds no live lease; no row updated means another process is
   refreshing, or the row was already refreshed and is returned as it is.
   The call to auth.openai.com then runs with no transaction open and no
   connection held, bounded at about eighteen seconds. The rotated pair is
   written, and the lease cleared, by compare-and-swap on the lease and the
   spent refresh token; a failed write is retried twice (after 200 ms and
   1 s) on a fresh connection, a write whose reply was lost is recognised by
   the row holding the new access token, and if every attempt fails an error
   is logged saying the owner will have to link again (nothing secret is
   logged). A refusal the auth server names as terminal
   (`refresh_token_reused` and the rest) marks the row `revoked` through the
   same write-back and is audited after it. A transient failure clears the
   lease at once, and the keepalive tries again the next day. A lease whose
   process died lapses after sixty seconds. Linking clears the lease and
   replaces the refresh token, so an in-flight refresh's write-back matches
   nothing and its tokens are discarded (`:superseded`); the owner's
   inference source lock serialises links and disconnects.

6. **Linking.** Two ways, on `/account/inference-credentials` only. The
   device-code flow is started and polled by the page's own LiveView process;
   the code lives in that process's assigns, so there is no attempt table, no
   job and no abuse limit, and leaving the page abandons it. Or the user
   pastes the `auth.json` that `codex login` wrote. There are no API routes;
   the CLI and the SDK have no use for them.

7. **The source a conversation is bound to.** Kind
   `codex_chatgpt_access_token`, scope `grant`, identity `chatgpt:<user id>`,
   revision the account id. A refresh keeps the source, and so does linking
   the same account again, so a conversation carries on. Linking another
   account changes it. A conversation whose subscription was disconnected,
   revoked or moved to another account is refused with
   `409 chatgpt_reconnect_required`, decided by asking the pinned
   subscription whether it still serves. A conversation bound to a source
   that no longer exists (the deployment's `platform:chatgpt`, or rows of the
   retired implementation carrying `grant_id` and `generation`) is refused
   with `inference_source_changed`.

8. **Ending the sign-in at OpenAI.** Whenever Managoat lets go of a refresh
   token, `Fountain.ChatGPT.OAuth.revoke/1` POSTs it to auth.openai.com's
   revocation endpoint as Codex's logout does, with the refresh's bounds,
   after the local write commits and outside any transaction or lock: on
   disconnect; on a relink, for the replaced token unless it is the same; for
   a device-code sign-in that could not be stored; for a rotated token a
   relink or disconnect overtook; and on account deletion
   (`Accounts.Deletion` reads the token before the cascade takes the DEK).
   A pasted `auth.json` that fails to link is left alone, as it is the
   sign-in of the machine it came from. A row already `revoked` is not
   revoked again. Only a `2xx` counts; any failure leaves the local write as
   it is and is logged with a status and a code, never the token. The call is
   synchronous, so a disconnect can take up to the bound when OpenAI is slow.

9. **The usage limit.** A turn that hits the plan's limit fails with the error
   OpenAI returns. Managoat does not check the limit, record it, or fall back
   to another credential.

10. **No feature flag.** A deployment with the broker shows the card to every
    account.

Audit, on the user's trail and always after the commit:
`chatgpt_subscription.connected`, `.disconnected`, `.revoked`,
`.revoked_at_openai` and `.not_revoked_at_openai`, the last two carrying
`trigger` (`disconnected`, `replaced`, `discarded`, `account_deleted`); after
account deletion the event has no `user_id` and names the user in its
metadata, as `account.deleted` does. A successful refresh is not audited,
because it changes nothing an owner chose.

## Consequences

- About 1,000 lines of server code replace about 7,700. The parts kept from
  the old code are the OAuth client and token parsing, the per-user DEK
  convention, and the codex transport points.
- **The bearer is protected from the sandbox, not from its owner's
  requests.** 0052's protected path refused every `chatgpt.com` route but
  three and would not substitute into a response. The ordinary rule
  substitutes on every request to `chatgpt.com`, so a route that reflected
  the bearer back would hand the sandbox the user's own token. That is
  accepted. Codex's analytics and remote plugin catalog, turned off only
  because the protected path refused them, now succeed like any other
  request.
- **A pasted `auth.json` shares one refresh chain with the machine it came
  from.** Whichever side refreshes second can be signed out, and revoking it
  also signs out that machine if it still holds the same refresh token. The
  console and the guide say so and prefer the code.
- **A refresh survives a database blip.** The lease is a column, so it
  survives a reconnect, and the write-back can retry on any connection; a
  crashed refresh needs only the lease to lapse.
- Upgrading from the retired implementation kept nothing: each user linked
  again (`docs/guides/operate/upgrade.md`).

## What has been observed

The tests run against a stubbed auth server. On the hosted deployment on
2026-10-14, after v0.22.0, a user's subscription was linked by device code
(`pro` plan), and a codex conversation on it completed two turns through the
broker's substitute rule.

On 2026-10-15, auth.openai.com's OpenID configuration listed
`https://auth.openai.com/api/accounts/oauth/revoke` as its
`revocation_endpoint`, with auth method `none` supported, so a public client
can call it. Codex's `codex logout` (openai/codex at `3ee47c10`) POSTs
`{token, token_type_hint: "refresh_token", client_id}` to
`https://auth.openai.com/oauth/revoke` before deleting the local `auth.json`,
and `codex login` does the same to the sign-in it replaces. One probe of each
path with an obviously invalid token and Codex's client id
(`app_EMoamEEZ73f0CkXaXp7hrann`) answered `401 invalid_refresh_token`: the
endpoint exists and validates the token, and an unknown token is an error,
not RFC 7009's `200`. No real token was sent.

Not yet observed: linking by a pasted `auth.json`, a resumed thread after a
park, a refresh against the real server, disconnect with the `409` that
follows, a real token revoked, and whether revoking the refresh token also
ends access tokens already issued under it.

## Alternatives considered

- **Keep the retired design (0047, 0052, 0060).** Built for a hosted service
  with many tenants; about 7,700 lines for a couple of users.
- **A session-level advisory lock for the refresh.** It must be held on one
  checked-out connection for the whole exchange, keeping a pool connection
  idle across the network call, and it is lost with that connection in the
  database blip the refresh has to survive. The first build held
  `pg_try_advisory_xact_lock` inside a transaction of up to 30 seconds: when
  the commit failed after OpenAI had already rotated the refresh token, the
  new one was rolled back, the next refresh was refused as
  `refresh_token_reused`, and the owner had to link again because of an
  outage.

## History

- 2026-10-13 — Decided and built (#2644, on #2642's removal): one subscription
  per user and one for the deployment, on the ordinary broker path; shipped
  in v0.22.0.
- 2026-10-14 — The user's own OpenAI key ranks ahead of the deployment's
  subscription (#2662), restoring the rule that the tenant's own credential
  wins ([0008](0008-byo-inference-credentials.md)) once named credential sets
  ([0053](0053-inference-credential-sets.md)) no longer offered a way out.
- 2026-10-14 — One sandbox per conversation
  ([0073](0073-one-sandbox-per-conversation.md)) removed the machine's shared
  Codex binding; each conversation's `auth.json` is its own.
- 2026-10-15 — The refresh leaves the transaction for a lease and
  compare-and-swap write-back (#2661).
- 2026-10-15 — [0075](0075-no-deployment-paid-inference.md) removed the
  deployment's subscription, `/admin/inference` and the
  `admin.platform_chatgpt.*` events; migration
  `20261015220000_drop_platform_inference` deleted its row and made
  `user_id` not null.
- 2026-10-15 — Managoat revokes the sign-in at OpenAI whenever it lets go of a
  refresh token (#2466).
