# Feature status

Most of Fountain is on for every account. Two features are not. This page
lists them. Each row says who has the feature on the hosted platform, and how
to turn it on.

A note with the same title as the row sits at the top of each page that
describes one of these features.

| Feature | Status | On the hosted platform | On your own instance |
|---|---|---|---|
| [Connections](../catalog/connections/index.md) | Alpha | Off by default. Behind the `connections` flag, separately from the credential broker. [Ask us](../api.md#support) to turn it on for your account. | Configure the credential broker and your provider apps, then add `connections` to `FEATURE_FLAGS_ON`. This also enables the credential bindings page. |
| [ChatGPT subscriptions](../api.md#chatgpt-subscriptions) | In development | Off for every account. Behind the `chatgpt_subscriptions` flag, which we have turned on for nobody. | Off. The flag reads off on an instance with no PostHog too. `FEATURE_FLAGS_ON` can force it on where the credential broker is configured. Do not do that on an instance that serves people you do not trust: see below. |

## What each status means

**In development.** The feature is not complete, and it is off everywhere
until it is. For ChatGPT subscriptions, the API can link a subscription and a
credential set can name one. These parts are not built: the console page, the
schedule that keeps an idle subscription's sign-in alive, the record of which
subscription served a turn, and two protections at the credential broker for
a response or a request that carries the subscription's token. The flag holds
only the door that links a new subscription. An account that holds one can
always list, rename, disconnect and remove it. It can reconnect it on a
deployment that has the credential broker.

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
