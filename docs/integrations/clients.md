# Overview

Fountain is a server. This section covers everything that drives it from the
outside. That is an editor, a chat surface, a plugin host, a relay, or your
own code.

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
| [Hermes Agent](hermes.md) | The HTTP API, through a plugin. | The Hermes host. |
| [OpenBot / AG-UI](openbot.md) | **Retired** (ADR 0057). | — |
| [OpenAI-compatible API](openai-compatible.md) | **Retired** (ADR 0057). | — |
| [LangChain and Deep Agents](langchain.md) | **Retired** (ADR 0057), with the API under it. | — |
| [AI gateways](gateways.md) | **Retired** (ADR 0057), with the API under it. | — |
| Buzz | A Nostr relay, hosted by Fountain. | The Buzz desktop, or `POST /api/buzz/agents`. |
| [Agentic IDEs](../llm-integration.md) | `/skill` and the discovery endpoints. | The IDE. |
| Your own code | The [HTTP API](../api.md), the [TypeScript](../sdk.md), [Python](../python-sdk.md), [Elixir](../elixir-sdk.md) or [Swift](../swift-sdk.md) SDK, the [CLI](../cli.md). | Wherever you want. |

## Over ACP

The first three of those spawn the same adapter. One page holds its protocol
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

[**Hermes Agent**](hermes.md) is a client of the HTTP API, and not of
`fountain acp`. A Hermes plugin, which this repo ships under
`integrations/hermes/`, gives Hermes `fountain_run` and its siblings. Its
model then delegates a task to a named Fountain agent and reads the answer
back. The plugin authenticates with an API key, or with the CLI's saved login.

## Retired: the compatibility dialects

Fountain used to speak two wire protocols it did not design, so that a client
which already spoke one needed no code at all: [AG-UI](openbot.md) for
coworker platforms, and the [OpenAI-compatible API](openai-compatible.md) for
anything with a base-URL field — which is what [AI gateways](gateways.md) and
the [LangChain integration](langchain.md) rode on.

All of it is retired ([ADR 0057](https://github.com/managoat/fountain/blob/main/decisions/0057-retire-public-compatibility-protocols.md)),
along with the tool bridge that let a *request* define tools for the agent to
call back on. Each page above says what a call gets now and what to use
instead. The thing with no replacement is the no-code integration itself: a
client that speaks somebody else's protocol now needs an adapter, because
Fountain speaks only its own.

Tools an **agent** is configured to call on your application are a different
mechanism and are fully supported — see below.

Everything that plugin does is available to you directly. Read the
[API reference](../api.md), the [TypeScript](../sdk.md),
[Python](../python-sdk.md), [Elixir](../elixir-sdk.md) and
[Swift](../swift-sdk.md) SDKs, and the
[CLI reference](../cli.md).

Do you build a chat surface of your own, the roster-and-threads app that
everybody clones? [**Build a chat app**](../build/index.md) walks the whole
thing through in SDK calls. [LLM integration](../llm-integration.md) covers
the discovery endpoints, which let an agentic IDE learn the whole surface from
one fetch.

## The other direction

**Buzz** inverts the arrangement. Fountain *hosts* a Buzz agent,
which is a Nostr identity that lives on a relay. Its coding agent runs in a
sandbox, and a vault holds its Nostr key. Nobody drives Fountain here.
Fountain arrives on the relay and answers.

Provision one from the Buzz desktop, or with `POST /api/buzz/agents`. It turns
itself on for any image that ships the `buzz-acp` binary.
