# Managoat

Managoat runs an agent on a cloud sandbox, and gives you a conversation with
it. You send a prompt. You read the reply. Managoat operates the sandbox, and
you do not.

It is an API first. Your app reaches it over a protocol you already speak, or
through an SDK. The person who uses your app need never learn that an agent
is there.

The whole product fits in one request. It gets a reply from an agent in its
own sandbox. It needs an API key from the console and the id of an agent
you created.

```sh
--8<-- "apps/fountain/priv/first_request/first-request.sh"
```

The [quickstart](quickstart.md) is the key, the request and the reply in
full.

<!-- The snippet include above must start a line: an admonition indents its
     body, and an indented include is left unexpanded. -->

## The problem

An agent is only useful with a sandbox behind it. That sandbox is the part
nobody set out to build.

The agent needs a filesystem, a shell, a package manager and a network. It
needs real credentials, and those must never reach the prompt or the
transcript. It needs to remember the last time, so the second message costs a
sentence and not an explanation of the first.

The sandbox also needs an owner. Something must start it, park it while
nobody speaks, and wake it when somebody does. One account must never see
another's work. A sandbox that nobody stops costs money for as long as it
runs.

You can build all of that. It is weeks of infrastructure, and it is not your
product.

## What Managoat does

Managoat keeps the sandbox, and gives you the conversation.

Send a prompt. A sandbox starts, with whatever packages, files and secrets you
configured, and runs the agent. It parks when the talk stops, and it costs
little while parked. The next message wakes it, and the agent's work is still
there.

Your secrets arrive at spawn as environment variables, so they never enter the
prompt or the model's context. Managoat scrubs them out of the output it
stores.

Managoat is one instance that you run for yourself. Accounts still own their
data: each account reaches its own agents and its own sandboxes, because
Managoat scopes each query to the caller. Anyone you let sign in stays apart
from you, and you write no code for it.

Reach it the way you already work.

- [**ACP**](integrations/acp.md), for an editor or a chat surface.
- [**REST and SSE**](api.md), for your own code, with
  the [TypeScript SDK](sdk.md) and a [CLI](cli.md) over them.

What you build on top is yours. It can be a chat client whose contacts are
bots, or a tool that makes an engineer faster. Your own user need not know
which. [Why a bot needs more than a chat UI](build/index.md) makes that case
in full.

## Start here

The tutorials are lessons. Each one ends with something that works.

- **[Run your first agent](quickstart.md)** is a key and one request. It
  needs no repository, no GitHub token and no install. Start here if Managoat
  is new to you.
- **[The guided tour](tour.md)** builds an agent that clones a repo, changes it
  and opens a pull request. A second turn then lands a revision on the same PR.
  The tour is about forty lines. It is the step after the quickstart.
- **[Your first app on the SDK](tutorials/first-app.md)** is a chat in your
  terminal, on the TypeScript SDK. It streams each reply, and sends every
  follow-up to the same conversation.

## Build with it

How-to guides for one job each, from your own code or your own tools.

- [Use the TypeScript SDK](sdk.md), the client for your own code, and
  [Use the CLI](cli.md), the `fountain` command
- [Run Claude Code as an API](catalog/runtimes/claude.md), and the same for
  Codex and Gemini CLI
- [Manage resources as YAML](guides/manifests.md), agents and their machines
  in one `fountain.yml`
- [Connect an editor](integrations/editors.md) over ACP, or
  [point an AI coding tool at Managoat](llm-integration.md) through `/skill`

## Run it

How-to guides for the operator of an instance.

- [Self-host Managoat](self-hosting.md), what you must have, which guide
  to read, and the licence
- [Deploy an instance](guides/operate/deploy.md), the first one to read
- [Connect services](integrations/index.md), the sandboxes, mail, OAuth and
  errors an instance uses
- [Troubleshoot a problem](troubleshooting/index.md), which starts from the
  symptom

## Understand it

Explanation, for when you want to know why.

- [The four primitives](primitives.md), and one page each for
  [Environment](concepts/environment.md),
  [Vault](concepts/vault.md),
  [Agent](concepts/agent.md) and
  [Conversation](concepts/conversation.md)
- [Architecture](architecture.md), what runs, what it talks to, and what breaks
  when a dependency is down. [About sandboxes](concepts/sandboxes.md) and
  [Where a secret comes from](concepts/secrets.md) go one level down.
- [The shape everyone clones](build/index.md), why a bot needs more than a chat
  UI, and [Ways to drive Managoat](integrations/clients.md), every client that
  talks to an instance

## Look it up

Reference, to check a fact.

- [API reference](api.md), REST endpoints and auth, and
  [All CLI commands](cli/commands.md), every command and flag
- [Catalog](catalog/index.md), runtimes, skills, MCP servers and agents
- [Configuration reference](configuration.md), each environment variable
- [Glossary](reference/glossary.md), with the five overloaded words
- [The sandbox contract](integrations/sandbox-contract.md), what a sandbox
  provider must do

## Which version this is

This manual describes the `main` branch of
[the repository](https://github.com/managoat/managoat). It is published at
[managoat.com/docs](https://managoat.com/docs) from each merge to `main`, so
it can be ahead of the release that your instance runs. The
[releases](https://github.com/managoat/managoat/releases) say what each version
changed. An instance does not serve the manual itself: its `/docs` redirects
here (`DOCS_URL` in the [configuration reference](configuration.md#manual)).
For the manual as of your version, read `docs/` at that release's tag.
