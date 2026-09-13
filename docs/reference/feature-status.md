# Feature status

Most of Fountain is on for every account. Three features are not. This page
lists them. Each row says who has the feature on the hosted platform, and
how to turn it on.

A note with the same title as the row sits at the top of each page that
describes one of these features.

| Feature | Status | On the hosted platform | On your own instance |
|---|---|---|---|
| [Teammate email and phone](../catalog/mcp-servers/fountain-comms.md) | Alpha | Off by default. Behind the `team_comms` flag. [Ask us](../api.md#support) to turn it on for your account. | Set the AgentMail and AgentPhone keys, and add `team_comms` to `FEATURE_FLAGS_ON`. Read the [configuration reference](../configuration.md#teammate-email-and-phone). |
| [OpenAI-compatible API](../integrations/openai-compatible.md) | Alpha | Off by default. Behind the `openai_compat` flag. [Ask us](../api.md#support) to turn it on for your account. | Add `openai_compat` to `FEATURE_FLAGS_ON`. Read the [configuration reference](../configuration.md). |
| [Connections](../catalog/connections/index.md) | Alpha | Off by default. Behind the `connections` flag, separately from the credential broker. [Ask us](../api.md#support) to turn it on for your account. | Configure the credential broker and your provider apps, then add `connections` to `FEATURE_FLAGS_ON`. This also enables the credential bindings page. |

## What each status means

**Alpha.** The feature works end to end, and we have not yet decided its final
shape. Its API and its tools can change between releases without an upgrade
note. Fountain refuses API calls when the flag is off: `404` for management routes,
and `403` for the conversation-authenticated Gmail MCP endpoint.

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
- [fountain-comms](../catalog/mcp-servers/fountain-comms.md), for the tools a
  contact adds.
- [OpenAI-compatible API](../integrations/openai-compatible.md), for the
  chat-completions endpoint where the model is an agent.
