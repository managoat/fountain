# Ways to drive Fountain

Fountain is a server. This page covers everything that drives it from the
outside. That is an editor, a chat surface, or your own
code.

The operator configures none of it. There is no env var, no server-side
switch, and nothing to run.

Each of these authenticates as an ordinary user, with an API key or with the
CLI's saved login. Each works against any instance it can reach.

If you want the services that Fountain itself needs, which are sandboxes,
mail, OAuth and error reports, read
[Services Fountain uses](index.md).

| Client | Talks over | Configured on |
|---|---|---|
| [Editors](editors.md) | [`fountain acp`](acp.md) | The developer's machine. |
| [OpenClaw](openclaw.md) | [`fountain acp`](acp.md) | The OpenClaw host. |
| [Agentic IDEs](../llm-integration.md) | `/skill` and the discovery endpoints. | The IDE. |
| Your own code | The [HTTP API](../api.md), the [TypeScript SDK](../sdk.md), the [CLI](../cli.md). | Wherever you want. |

## Over ACP

The first two of those spawn the same adapter. One page holds its protocol
surface, its `_meta` extensions and its failure modes,
[**`fountain acp` (reference)**](acp.md). So the client pages below cover the
setup alone.

[**Editors**](editors.md). An ACP-capable editor, such as Zed, spawns
`fountain acp` locally. It then talks to your instance with the credentials
the developer already has.

[**OpenClaw**](openclaw.md) reaches the same adapter from a chat surface, such
as Telegram, Discord or Slack. Register Fountain as a custom ACP agent in its
`acpx` plugin. That configuration is client-side, on the OpenClaw host.

## Over the API

Any other client, your own code included, talks to the HTTP API directly.
Read the [API reference](../api.md), the [TypeScript SDK](../sdk.md) and the
[CLI reference](../cli.md).

## Retired: the compatibility dialects

Fountain used to speak AG-UI and an OpenAI-compatible API, so a client that
already spoke one needed no code. Both are retired
([ADR 0057](https://github.com/managoat/fountain/blob/main/decisions/0057-retire-public-compatibility-protocols.md)),
along with the tool bridge that let a *request* define tools for the agent to
call back on. Their paths now answer like any `/api` path that never
existed. A client that speaks somebody else's protocol needs an adapter,
because Fountain speaks only its own.

Do you build a chat surface of your own, the roster-and-threads app that
everybody clones? [**Build a chat app**](../build/index.md) walks the whole
thing through in SDK calls. [LLM integration](../llm-integration.md) covers
the discovery endpoints, which let an agentic IDE learn the whole surface from
one fetch.
