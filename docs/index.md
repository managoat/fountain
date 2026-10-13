# Fountain

Fountain runs an agent on a cloud sandbox, and gives you a conversation with
it. You send a prompt. You read the reply. Fountain operates the sandbox, and
you do not.

It is an API first. Your app reaches it over a protocol you already speak, or
through an SDK. The person who uses your app need never learn that an agent
is there.

The whole product fits in one request. It gets a reply from an agent in its
own sandbox. It needs an API key from the console and the id of your
`starter` agent.

```sh
--8<-- "docs/snippets/first-request.sh"
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

## What Fountain does

Fountain keeps the sandbox, and gives you the conversation.

Send a prompt. A sandbox starts, with whatever packages, files and secrets you
configured, and runs the agent. It parks when the talk stops, and it costs
little while parked. The next message wakes it, and the agent's work is still
there.

Your secrets arrive at spawn as environment variables, so they never enter the
prompt or the model's context. Fountain scrubs them out of the output it
stores.

Fountain is multi-tenant. Each account reaches its own agents and its own
sandboxes, because Fountain scopes each query to the caller. Your own users
therefore stay apart, and you write no code for it.

Reach it the way you already work.

- [**ACP**](integrations/acp.md), for an editor or a chat surface.
- [**REST and SSE**](api.md), for your own code, with
  the [TypeScript SDK](sdk.md) and a [CLI](cli.md) over them.

What you build on top is yours. It can be a chat client whose contacts are
bots, or a tool that makes an engineer faster. Your own user need not know
which. [Why a bot needs more than a chat UI](build/index.md) makes that case
in full.

## Start here

- **[Run your first agent](quickstart.md)** is a key and one request. It
  needs no repository, no GitHub token and no install. Start here if Fountain
  is new to you.
- **[The guided tour](tour.md)** builds an agent that clones a repo, changes it
  and opens a pull request. A second turn then lands a revision on the same PR.
  The tour is about forty lines. It is the step after the quickstart.
- **[The four primitives](primitives.md)** explains the data model, and why
  Fountain divides it four ways.

## Understand it

- [The four primitives](primitives.md), and one page each for
  [Environment](concepts/environment.md),
  [Vault](concepts/vault.md),
  [Agent](concepts/agent.md) and
  [Conversation](concepts/conversation.md)
- [Agents as teammates](concepts/teammates.md), and why a teammate is not a
  fifth primitive
- [Where a secret comes from](concepts/secrets.md), the chain from the master
  key to the agent's process
- [About sandboxes](concepts/sandboxes.md), the machine a conversation runs on
- [The console, the apps, and the API](concepts/surfaces.md), and why you watch
  an agent somewhere else
- [Architecture](architecture.md), what runs, what it talks to, and what breaks
  when a dependency is down
- [Why a bot needs more than a chat UI](build/index.md), and why the API below
  it exists

## Build with it

- [The guided tour](tour.md), an agent that opens a pull request
- [Build a chat app](build/team-chat.md), a roster-and-threads app from start
  to finish
- [Plug into Fountain](integrations/clients.md), editors, chat surfaces,
  plugins and SDKs
- [LLM integration](llm-integration.md), how to connect an agentic IDE through
  `/skill`

## Run it

- [Local setup](setup.md), how to bootstrap a workstation in about ten minutes
- [Self-host Fountain](self-hosting.md), what you must have and which guide
  to read
- [Deploy an instance](guides/operate/deploy.md), the first one to read
- [Troubleshoot a problem](troubleshooting/index.md), which starts from the
  symptom
- [Operations](operations.md), how to run an instance day to day
- [Services Fountain uses](integrations/index.md), sandboxes, mail, OAuth
  and errors

## Look it up

- [Catalog](catalog/index.md), runtimes and skills
- [CLI reference](cli.md), the `fountain` command surface
- [API reference](api.md), REST endpoints and auth
- [TypeScript SDK](sdk.md)
- [Configuration reference](configuration.md), each environment variable
- [Conversation states](reference/conversation-states.md)
- [Glossary](reference/glossary.md), with the five overloaded words
- [Feature status](reference/feature-status.md), where the features that were not on for every account went
