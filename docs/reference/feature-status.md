# Feature status

Every feature of Fountain is on for every account, and none is in
development behind a flag. This page used to list the ones that were not, and
it says here where each of them went.

ChatGPT subscriptions, the feature this page listed last, were rebuilt on
2026-10-13 without a feature flag. Each account can link one subscription,
and an admin can link one for the whole deployment. A codex conversation runs
on the account's own subscription, else the deployment's, else an OpenAI API
key, and only on a deployment that runs the egress broker. Read
[Run Codex on a ChatGPT subscription](../guides/chatgpt-subscription.md). A
conversation that ran on a subscription linked before the rebuild keeps its
history and cannot take another turn. Link again and start a new
conversation.

Connections, the one Alpha feature this page used to list, were removed from
Fountain. A credential reaches a sandbox from an environment
or a vault, through the broker where it runs.

## Brokered credentials are on for every account

[Brokered credentials](../concepts/secrets.md#bindings-when-the-broker-is-on)
are no longer enrolled account by account, so this page no longer lists
them. They stay off until you turn them on for the deployment. Set
`BROKER_LISTEN_PORT` and its siblings. Every account on the deployment is
then brokered, and the credential bindings page and API are open to it. Read the [configuration reference](../configuration.md).

## Where to go next

- [Where a secret comes from](../concepts/secrets.md), for what the broker
  changes.
- [Plug into Fountain](../integrations/clients.md), for the ways in.

The OpenAI-compatible API was the other feature on this page. It is retired
([ADR 0057](https://github.com/managoat/fountain/blob/main/decisions/0057-retire-public-compatibility-protocols.md)),
and its flag is gone rather than switched off; the
[page for it](../integrations/openai-compatible.md) says what a call gets
now.
