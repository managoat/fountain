# AI gateways (retired)

Fountain used to sit behind an AI gateway — [LiteLLM](https://github.com/BerriAI/litellm),
Portkey, Kong AI Gateway, Cloudflare AI Gateway — as just another
OpenAI-compatible upstream: point the gateway's `api_base` at
`https://your-fountain/v1`, name a Fountain agent as the model, and every
client already behind that gateway could reach it. **The endpoints that made
that work are gone**, removed in the release that carries
[ADR 0057](https://github.com/managoat/fountain/blob/main/decisions/0057-retire-public-compatibility-protocols.md).
The `examples/litellm-gateway` example went with them.

This page stays because the URL is in other people's notes.

## What a gateway sees now

A `404` from `https://your-fountain/v1/chat/completions`, with the ordinary
body `{"errors": {"detail": "Not Found"}}` — not a gateway-shaped error, and
not a model that has stopped responding. A gateway configured this way will
report the upstream as failing; remove the Fountain entry from its config.

## What has no replacement

Putting Fountain behind a gateway **with no code**. Gateways speak the OpenAI
dialect by definition, Fountain no longer does, and the native conversation
API is not a chat-completions endpoint — a conversation is created, prompted
and followed over several calls rather than answered in one. No gateway can
be configured into that shape.

If the gateway was giving you key management, spend tracking or rate limiting
across teams, Fountain has its own: [API keys](../api.md), per-account
sandbox caps and per-key rate limits.

## What you can still do

Call the [conversation API](../api.md) from your own code, or through the
[TypeScript](../sdk.md), [Python](../python-sdk.md), [Elixir](../elixir-sdk.md)
or [Swift](../swift-sdk.md) SDK. Read [Plug into Fountain](clients.md) for the
routes in.

Gateways in the *other* direction are unaffected: Fountain still runs agents
against OpenAI, Anthropic and the rest, and a deployment can still put its own
egress through a proxy. That is the egress credential broker
([secrets](../concepts/secrets.md)), and it shares nothing with the retired
inbound dialect.
