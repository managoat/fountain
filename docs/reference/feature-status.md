# Feature status

Most of Fountain is on for every account and finished. Two features are
not. This page lists them. Each row says who has the feature on the hosted
platform, and how to turn it on.

A note with the same title as the row sits at the top of each page that
describes one of these features.

| Feature | Status | On the hosted platform | On your own instance |
|---|---|---|---|
| [Connections](../catalog/connections/index.md) | Alpha | Off by default. Behind the `connections` flag, separately from the credential broker. [Ask us](../api.md#support) to turn it on for your account. | Configure the credential broker and your provider apps, then add `connections` to `FEATURE_FLAGS_ON`. This also enables the credential bindings page. |
| [ChatGPT subscriptions](../guides/chatgpt-subscriptions.md) | In development | On for every account since 2026-09-21, behind the `chatgpt_subscriptions` flag. We opened it before we had tested it with a user's subscription on the real service: see below. We can turn it off again. | Off. The flag reads off on an instance with no PostHog too. `FEATURE_FLAGS_ON=chatgpt_subscriptions` forces it on where the credential broker is configured. Do not do that on an instance that serves people you do not trust: see below. |

## What each status means

**In development.** The feature is not complete. It is off on your own
instance until you force its flag on. We do not say that it works end to
end, because we have not shown that it does.

On 2026-09-21 we turned ChatGPT subscriptions on for every account on the
hosted platform. We did that early, because the parts that we have not
tested fail in a way that you can recover from. When we turned it on, a
user's subscription had not done these things against the real service:

- A sign-in with a code at `auth.openai.com`, and the job that waits for the
  approval.
- The **ChatGPT subscriptions** card in a real browser.
- A turn in a sandbox that two subscriptions share.
- The daily renewal of an idle subscription.
- The check of the plan's usage with a user's token.

We have not measured how long an idle sign-in lasts, so the 6 days below are
an estimate. We have not measured how `auth.openai.com` limits the rate of
sign-ins and renewals. The deployment's own ChatGPT account has completed
two turns through the same broker path. A turn after a sandbox reattaches
is not measured. The first subscriptions that people link on the hosted
platform are the test. If the feature fails, reconnect the subscription or
use an OpenAI key. We can turn the flag off, and then nobody can link a new
subscription. Do not rely on this feature for work that must not stop.

For ChatGPT subscriptions, the console and the
[API](../api.md#chatgpt-subscriptions) can link a subscription and a
credential set can name one. Each turn records which subscription served it.
Fountain detects a subscription that has spent its plan's Codex allowance
after a turn fails on it, and refuses the subscription until the reset time.
A daily job renews a subscription that nobody used for 6 days, so that its
sign-in does not end. An account export lists the subscriptions, and an
account deletion removes them. The credential broker refuses a response that
repeats the subscription's token. It refuses a query string on the Responses
route, and allows only `client_version` on the model list route. The broker finds only an exact
copy of the token. It does not find an encoded copy or a partial copy. These
parts are not built: a check of the usage before a turn fails, an email or a
webhook about a spent plan, and a way to revoke a sign-in at OpenAI. The flag
holds
only the door that links a new subscription. An account that holds one can
always list, rename, disconnect and remove it, and keeps the **ChatGPT
subscriptions** card in the console. It can reconnect it on a deployment that
has the credential broker. With the flag off, the console also does not offer
a credential set a subscription that it does not name already.

**Alpha.** The feature works end to end, and we have not yet decided its final
shape. Its API and its tools can change between releases without an upgrade
note. Fountain refuses API calls when the flag is off: `404` for management
routes. The Gmail MCP endpoint, which the Google extension serves, answers
`403` only on a deployment without the egress broker. A connection that
exists keeps its tools when the flag goes off.

What the flag refuses is **adding or repointing** a way to reach a credential.
Reading and removing stay open, because an account whose flag goes off keeps
every credential already brokered into its sandboxes and has to be able to
take one away.

| Gated when the flag is off | Open either way |
|---|---|
| `POST /api/connection-providers`, `PATCH` on one, and its `discover` — `404 connections_not_enabled` | `GET` and `DELETE` on connections, providers and bindings |
| `POST /api/secret-bindings`, and a `PATCH` that retargets one or sets `enabled: true` — `404 brokerage_not_enabled` | A `PATCH` that only sets `enabled: false`, which takes a credential off a host |

A connection itself is never created through the API at all: signing in to a
provider needs a browser, so it is the `/connections/:provider/start` flow, and
`GET /api/connections/providers` says where to send the owner.

So an account that never had the feature reads an empty list rather than a
closed door, and an empty list is not by itself proof that the feature is on.
Ask [`GET /api/auth/me`](../api.md), whose `connections_enabled` says so
directly.

## Brokered credentials are on for every account

[Brokered credentials](../concepts/secrets.md#bindings-when-the-broker-is-on)
are now on for every account on the hosted platform, so this page no longer
lists them. Until 2026-09-04 we enrolled each account by hand.

On your own instance they stay off until you turn them on. Set
`BROKER_LISTEN_PORT` and its siblings. Every account on the deployment is
then brokered. Read the [configuration reference](../configuration.md).

## Where to go next

- [Where a secret comes from](../concepts/secrets.md), for what the broker
  changes.
- [Plug into Fountain](../integrations/clients.md), for the ways in.

The OpenAI-compatible API was the other feature on this page. It is retired
([ADR 0057](https://github.com/managoat/fountain/blob/main/decisions/0057-retire-public-compatibility-protocols.md)),
and its flag is gone rather than switched off; the
[page for it](../integrations/openai-compatible.md) says what a call gets
now.
