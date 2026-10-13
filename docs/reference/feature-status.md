# Feature status

Every feature of Fountain is on for every account, and none is in
development behind a flag. This page used to list the ones that were not, and
it says here where each of them went.

ChatGPT subscriptions, the feature this page listed last, were removed from
Fountain on 2026-10-13, and so was the feature flag that held them. The
codex runtime runs on an OpenAI API key: a credential set's, an environment's
or a vault's, or the deployment's platform key. A conversation that ran on a
subscription keeps its history and cannot take another turn. Start a new
conversation instead.

Connections, the one Alpha feature this page used to list, were removed from
Fountain. A credential reaches a sandbox from an environment
or a vault, through the broker where it runs.

## Brokered credentials are on for every account

[Brokered credentials](../concepts/secrets.md#bindings-when-the-broker-is-on)
are now on for every account on the hosted platform, so this page no longer
lists them. Until 2026-09-04 we enrolled each account by hand.

On your own instance they stay off until you turn them on. Set
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
