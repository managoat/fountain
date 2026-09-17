# Feature status

Most of Fountain is on for every account. One feature is not. This page
lists it. The row says who has the feature on the hosted platform, and how to
turn it on.

A note with the same title as the row sits at the top of each page that
describes one of these features.

| Feature | Status | On the hosted platform | On your own instance |
|---|---|---|---|
| [Connections](../catalog/connections/index.md) | Alpha | Off by default. Behind the `connections` flag, separately from the credential broker. [Ask us](../api.md#support) to turn it on for your account. | Configure the credential broker and your provider apps, then add `connections` to `FEATURE_FLAGS_ON`. This also enables the credential bindings page. |

## What each status means

**Alpha.** The feature works end to end, and we have not yet decided its final
shape. Its API and its tools can change between releases without an upgrade
note. Fountain refuses API calls when the flag is off: `404` for management
routes. The Gmail MCP endpoint, which the Google extension serves, answers
`403` only on a deployment without the egress broker. A connection that
exists keeps its tools when the flag goes off.

Only the routes that **create** something are refused. Listing, revoking and
deleting stay open, because an account whose flag goes off keeps every
credential already brokered into its sandboxes and has to be able to take one
away. So an account that never had the feature reads an empty list from
`GET /api/connections` and `GET /api/secret-bindings` rather than a `404`,
while `POST` to either answers `404 brokerage_not_enabled`. An empty list is
therefore not by itself proof that the feature is on. Ask
[`GET /api/auth/me`](../api.md), whose `connections_enabled` says so directly.

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
