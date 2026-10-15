---
type: ADR
title: "One ChatGPT subscription per user, and one for the deployment, on the ordinary broker path"
description: "Codex runs on the user's own ChatGPT subscription, else the user's own OpenAI key, else the deployment's subscription, else the platform key (amended 2026-10-14, #2662; until then the deployment's subscription came before every key). One table, one context, one daily keepalive; the broker substitutes the access token on chatgpt.com like any other credential. Before a turn Fountain only re-reads the stored token; it exchanges tokens with auth.openai.com when linking, in the daily keepalive, and before a turn only if the stored token has expired or expires within ten minutes. Rebuilds, much smaller, what 0047, 0052 and 0060 did."
tags: [inference, codex, oauth, broker, security]
status: stable
adr: "0070"
adr_status: "Accepted"
date: 2026-10-13
---

# 0070 — One ChatGPT subscription per user, and one for the deployment, on the ordinary broker path

**Status:** Accepted, 2026-10-13. Built in #2644, stacked on the removal of
the old implementation (#2642), and shipped in v0.22.0. No run against the
real auth server or a real codex client is recorded here: see
[Not yet measured](#not-yet-measured).

## Context

Fountain ran codex on ChatGPT plans twice before. [0047](0047-codex-platform-chatgpt-account.md)
put the deployment's own ChatGPT account behind the broker.
[0052](0052-user-owned-chatgpt-grants.md) and [0060](0060-many-user-chatgpt-subscriptions.md)
let each user link several subscriptions. All three were built for a hosted
service with many tenants: platform-lent grants, several grants per user with
selection and generations, a refresh coordinator, a circuit breaker, two
keepalives and a sweep, durable link attempts as jobs with abuse limits,
server-confirmed usage exhaustion, a protected broker path that hid the bearer
even from its owner, and a feature flag. That came to about 7,700 lines of
server code and 15,500 of tests. #2642 removed it all, and retired the three
ADRs.

Fountain is now a self-hosted application with a couple of users. The
maintainer decided on 2026-10-13 to keep the feature in a small form: one
subscription per user, one the operator links for the whole deployment, and
the rule from before that the bearer never enters the sandbox.

## Decision

1. **One row per owner.** `chatgpt_subscriptions` holds at most one row per
   user and at most one with no user, which is the deployment's. The row has
   the account id, the ChatGPT user id and plan type (the three claims codex
   reads from an `id_token`), both tokens as ciphertext, the access token's
   expiry, when it was last refreshed, and a status of `active` or `revoked`.
   A user's tokens are encrypted under their DEK with an AAD that names the
   owner, the row and the field. The deployment's are encrypted under the
   master key, as its API keys are. Linking again replaces the tokens on the
   same row. Disconnecting deletes the row, and deleting the account deletes
   it by cascade. The tables of the retired design are not reused.

2. **Which credential codex uses.** *Amended 2026-10-14 (#2662), see the
   addendum below.* For a codex run on an `openai/` model the resolver takes
   the user's own active subscription, then the user's own OpenAI key (the
   record's, an environment's or a vault's), then the deployment's
   subscription, then the platform key. The user's subscription wins over
   every API key because the user linked it to be used. The user's own key
   wins over the deployment's subscription because the user's own credential
   wins over anything the deployment provides
   ([0008](0008-byo-inference-credentials.md)). Subscriptions are used only
   when the egress broker is configured
   ([0019](0019-egress-credential-brokerage.md)); without it the token would
   have to enter the sandbox, so resolution falls through to an API key.

3. **The ordinary broker path.** The access token is an inference credential
   under the broker key `CODEX_CHATGPT_ACCESS_TOKEN`, with an implicit
   substitute rule on `chatgpt.com`, like every other inference credential on
   its provider's host. The sandbox gets the placeholder. Fountain writes
   `~/.codex/auth.json` in `chatgptAuthTokens` mode (codex treats the tokens
   as externally managed and never refreshes them) with the placeholder as
   the access token, the real account id, an empty refresh token, and an
   `id_token` synthesised from the three stored claims. The real `id_token`,
   which carries the account's email, never leaves the server. Codex is given
   a provider of Fountain's own that points at the Codex backend with
   WebSockets off, `MODEL_PROVIDER` pins it for `thread/resume`, and the ACP
   peer does not use codex-acp's api-key `authenticate` method. Those three
   transport points are kept from #2503. The file is the machine's one shared
   `~/.codex/auth.json`, so the machine's Codex binding
   ([0023](0023-persistent-agent-sandbox.md), `Machines.Binding`) keeps every
   codex conversation on a persistent sandbox on one source.

4. **When Fountain talks to auth.openai.com.** Before each turn Fountain only
   re-reads the stored access token from the database and puts it in the
   broker's rule (`Egress.refresh_before_turn/1`). That is a database read, not
   a token exchange. Fountain exchanges tokens with `auth.openai.com` in three
   cases only:
   - when an owner links a subscription (the device-code legs, or none for a
     pasted `auth.json`);
   - in the daily keepalive, `Fountain.Workers.ChatGPTKeepalive` at 04:29 UTC,
     which refreshes each active subscription last refreshed more than six
     days ago (an access token lives about ten);
   - as a safety net before a turn, and only when the stored access token has
     already expired or expires within ten minutes. If the keepalive runs,
     this never happens.

5. **Refreshing.** A refresh runs inside a transaction that holds a Postgres
   advisory try-lock on the row. Production runs two replicas, and they must
   never spend one refresh token twice. A replica that finds the lock taken
   skips the refresh. The rotated refresh token is written in the same
   transaction, and the new access token is used only after that commit. A
   refusal the auth server names as terminal (`refresh_token_reused` and the
   rest) marks the row `revoked` with the code and audits it. Any other
   failure leaves the row alone, and the keepalive tries again the next day.
   Linking takes the same lock, so a relink never interleaves with a refresh
   of the old chain.
   *Amended 2026-10-15 (#2661): the lock is now a lease on the row and the
   call to auth.openai.com runs outside any transaction; see the addendum
   below.*

6. **Linking.** Two ways, in the console only. The first is the device-code
   flow, started and polled by the page's own LiveView process. The code lives
   in that process's assigns, so there is no attempt table, no job and no
   abuse limit, and leaving the page abandons it. The second is pasting the
   `auth.json` that `codex login` wrote. `/account/inference-credentials`
   shows the user's card and `/admin/inference` shows the deployment's.
   There are no API routes. The CLI and the SDK have no use for them.

7. **The source a conversation is bound to.** Kind
   `codex_chatgpt_access_token`; scope `grant` for the user's own (the API's
   existing word for it) and `platform` for the deployment's; identity
   `chatgpt:<user id>` or `platform:chatgpt`; revision the account id. A
   refresh keeps the source. Linking the same account again keeps it, so a
   conversation carries on. Linking another account changes it. A
   conversation whose subscription was disconnected, revoked or moved to
   another account is refused with `409 chatgpt_reconnect_required`. Rows the
   retired implementation wrote carry `grant_id` and `generation` as well:
   they render as a subscription, and they never validate again
   (`inference_source_changed`).

8. **The usage limit.** A turn that hits the plan's limit fails with the error
   OpenAI returns. Fountain does not check the limit on the server, record it,
   or fall back to another credential.

9. **No feature flag.** A deployment with the broker shows the card to every
   account.

Audit: a user's link, disconnect and revocation are
`chatgpt_subscription.connected`, `.disconnected` and `.revoked` on the
user's trail. The deployment's are `admin.platform_chatgpt.*`. All are
recorded after the transaction commits, never inside it. A successful
refresh is not audited, because it changes nothing an owner chose.

## Consequences

- About 1,000 lines of server code replace about 7,700. The parts kept from
  the old code are the OAuth client and token parsing, the per-user DEK
  convention, and the codex transport points.
- **The bearer is protected from the sandbox, not from its owner's
  requests.** The protected path of 0052 refused every `chatgpt.com` route but
  three, and would not substitute into a response. The ordinary rule
  substitutes on every request to `chatgpt.com`. A route that reflected the
  bearer back would hand it to the sandbox. On a user's own subscription that
  is the user's own token. On the deployment's subscription it would let
  any account's agent read the deployment's token. That is accepted for a
  self-hosted deployment whose operator links its own plan for people they
  trust. It is said on the docs page, and it is the reason to prefer users'
  own subscriptions on a deployment with strangers.
- Codex's analytics and remote plugin catalog are no longer turned off. They
  were turned off because the protected path refused them. On the ordinary
  path they succeed like any other request.
- A pasted `auth.json` shares one refresh chain with the machine it came
  from. Whichever side refreshes second can be signed out. The console says
  so and prefers the code.
- Nothing revokes a sign-in at OpenAI. Disconnecting deletes Fountain's copy
  only.
- Upgrading from the retired implementation keeps nothing. Each user links
  again after the deploy, and the admin links the deployment's again
  (`docs/guides/operate/upgrade.md`).

## Not yet measured

The tests run against a stubbed auth server. None of the following has been
observed against the real `auth.openai.com` or a real codex client, and each
is still to be checked on a deployment:

- linking by device code, and by a pasted `auth.json`;
- a codex turn on a user's subscription and on the deployment's, through the
  broker's substitute rule, including a resumed thread;
- a forced refresh: the rotated refresh token is stored, and the next turn
  carries the new access token;
- disconnect, and the `409 chatgpt_reconnect_required` that follows.

Observed on the hosted deployment on 2026-10-14, after v0.22.0 (read from its
database and audit log):

- a user's subscription linked by device code (`pro` plan), and the
  deployment's subscription linked;
- a codex conversation on the user's subscription, through the broker's
  substitute rule, completed two turns.

Still unobserved: pasting an `auth.json`, a turn on the deployment's
subscription, a resumed thread after a park, a refresh (the first keepalive is due six days after linking), and
disconnect with the `409` that follows. Disconnecting deletes the live
subscription, so that check waits for someone willing to link again.

## Addendum — 2026-10-14: the user's own key before the deployment's subscription (#2662)

Decision 2 put the deployment's subscription ahead of every API key, the
user's own included, with one way out: a run that named its credential set
skipped the deployment's subscription. Named sets were retired the same day
([0053](0053-inference-credential-sets.md)), so nothing replaced that skip,
and a user who had linked no subscription of their own had no way to run
codex on their own `OPENAI_API_KEY` once the admin linked the deployment's.
Their spend, rate limits, model access and data-handling terms silently
became the deployment's ChatGPT account's. That breaks the rule
[0008](0008-byo-inference-credentials.md) and
[0038](0038-onboarding-first-reply.md) decision 3 state: the tenant's own
credential wins over anything the platform provides.

The order is now:

1. the user's own ChatGPT subscription;
2. the user's own OpenAI key: the credential record's, or `OPENAI_API_KEY`
   in the conversation's environment or vault, by the ordinary selection;
3. the deployment's ChatGPT subscription;
4. the platform OpenAI key, on a brokered deployment only (0038, addendum of
   the same date).

Both subscriptions still need the broker. An empty or unusable key of the
user's own is `inference_credential_unusable`, as for every other provider,
not a fall through to the deployment's subscription. A user who wants the
deployment's subscription removes their key.

**Conversations already bound** keep the existing rules for a source
change. A conversation on the deployment's subscription is never moved to a
key. When the user adds one it carries on if the key cannot reach it (a key
saved to a credential record the conversation was not bound to, because the
account had none when it started) and is otherwise refused with
`inference_source_changed`. A conversation that ran on the deployment's
subscription while its user already held a key re-resolves to that key after
this change, and is refused the same way at its next turn.

`chatgpt_reconnect_required` now asks the pinned subscription itself whether
it still serves. Before, any fresh source that was not a subscription also
counted as "reconnect", which was right only while a subscription outranked
every key. A conversation on a deployment's subscription that the user's own
key now outranks would have been told to reconnect a subscription that was
still linked.

## Addendum — 2026-10-14: one sandbox per conversation

[0073](0073-one-sandbox-per-conversation.md) (#2676) supersedes
[0023](0023-persistent-agent-sandbox.md). No two codex conversations share a
machine any more, so the machine's Codex binding that point 3 relies on is
removed, and each conversation's `~/.codex/auth.json` is its own.

## Addendum — 2026-10-15: the refresh leaves the transaction (#2661)

Point 5 held the advisory lock with `pg_try_advisory_xact_lock`, so the
exchange with auth.openai.com ran inside a transaction of up to 30 seconds,
holding a pool connection across the network call. OpenAI rotates the
refresh token as soon as it answers. When the commit then failed (the
timeout after a slow answer, a database blip, a killed node), the new
refresh token was rolled back with it and the stored one had been spent.
The next refresh was refused as `refresh_token_reused`, the row was marked
`revoked`, and the owner had to link again because of an outage.

A refresh now:

1. **Takes a lease.** One conditional `UPDATE` sets
   `chatgpt_subscriptions.refresh_lease_until` to sixty seconds from the
   database's `now()`, only when the row is active, has not been refreshed
   since the caller read it, and holds no live lease. No row updated means
   another process is refreshing (`:locked`), or someone already refreshed
   it, which is returned as it is.
2. **Calls auth.openai.com** with no transaction open and no connection
   held. The call is bounded at about eighteen seconds, well inside the
   lease.
3. **Writes back by compare-and-swap.** The rotated pair is written, and the
   lease cleared, only where the lease and the spent refresh token are still
   the row's. A failed write is retried twice (after 200 ms and 1 s), each on
   a fresh connection. A write whose reply was lost is recognised by the row
   holding the new access token. If every attempt fails, an error is logged
   saying the owner will have to link again. Nothing secret is logged.

A terminal refusal marks the row `revoked` through the same write-back and
is audited after it, outside any transaction. A transient failure clears the
lease at once. A lease whose process died lapses after sixty seconds.

Linking no longer waits for a refresh in flight. It clears the lease and
replaces the refresh token, so the in-flight refresh's write-back matches
nothing and the old chain's tokens are discarded (`:superseded`). The
owner's inference source lock still serialises links and disconnects.

**Why a lease, not a session-level advisory lock.** A session lock (the
other option #2661 offered) keeps the serialisation in Postgres. But it must
be held on one checked-out connection for the whole exchange, which keeps a
pool connection idle across the network call. And it is lost with that
connection in exactly the database blip this change is about, while the
write's retry then needs a different connection anyway. The lease is a
column, so it survives a reconnect, and the retries can use any connection.
It costs one nullable column, and a lapsed lease is the only recovery a
crashed refresh needs.
