# Glossary

Here are the terms Fountain uses, and the five that carry more than one
meaning. Where a word has more than one sense, this page lists the senses and
names the one the docs use.

## The overloaded words

### Agent

Three senses. The docs mean the first.

1. **The primitive.** A named configuration that you can run again and again.
   Read [About agents](../concepts/agent.md).
2. **The coding agent.** The process in the sandbox, which is Claude Code,
   Codex or Gemini CLI. The docs call this the **runtime**.
3. **The ACP role.** In the Agent Client Protocol, the process an editor
   spawns. The docs call this `fountain acp`. Read
   [`fountain acp`](../integrations/acp.md).

### Environment

Three senses. The docs mean the first.

1. **The primitive.** Read
   [About environments](../concepts/environment.md).
2. **Environment variables.** The values in a process. The docs always write
   "environment variables" in full.
3. **A deployment tier.** Dev, staging, production. The docs say
   **deployment** for this, and never "environment".

### Fountain

Three senses. The format tells you which.

1. **Fountain**, unstyled, is the product.
2. **`fountain`**, in code font, is the CLI binary.
3. **the `fountain` skill** is the skill that each sandbox gets, which gives
   an agent Fountain's own API. Always write the word "skill" with it.

### Vault

Two senses, and they are close to opposite. The docs mean the first.

1. **The primitive.** A small, static override layer for one run, which wins
   on a key collision. Read [About vaults](../concepts/vault.md).
2. **HashiCorp Vault.** A central server that issues dynamic leased
   credentials. Nothing about it relates to Fountain's Vault, except the shape
   of the encryption. The Vault page sets the collision out.

### Computer

The team and conversations apps use this word for the machine a teammate works
on. The docs say **sandbox**.

## The rest

| Term | Means |
|---|---|
| **ACP** | Agent Client Protocol. How an editor or a chat surface drives Fountain. Read [`fountain acp`](../integrations/acp.md). |
| **AG-UI** | The protocol OpenBot and other coworker hosts speak. Fountain spoke it until ADR 0057 retired the endpoint; read [OpenBot / AG-UI](../integrations/openbot.md). |
| **Conversation** | One run of an Agent in a sandbox. Read [About conversations](../concepts/conversation.md). |
| **DEK** | Data encryption key. Fountain derives one for each tenant from `MASTER_SECRETS_KEY`, then encrypts that tenant's secrets with it. |
| **Inference credentials** | A user's own model provider keys, which they enter in the app. An operator never sets them. Read [Services Fountain uses](../integrations/index.md). |
| **Log event** | One entry in a conversation's stream. It arrives over SSE, and `?blocks=true` parses it for you. |
| **MCP server** | A Model Context Protocol server that an Agent gives its runtime. You declare it in `mcp_servers`. |
| **Reaper** | The background sweep that suspends an idle sandbox, and destroys one that passed a configured ceiling. |
| **Runner** | A machine you own that runs `fountain runner` and acts as a sandbox provider. Read [Self-hosted runners](../integrations/runners.md). |
| **Runtime** | What a sandbox runs. One of `claude`, `codex`, `gemini`, which are coding-agent CLIs, or `acp`, which is a command the Agent names. |
| **Sandbox** | The isolated machine that a Conversation runs in. Several Conversations can share one. Fountain provisions it at launch and reclaims it on the lifetime rules. `GET /api/sandboxes` lists them. |
| **Sandbox provider** | A backend that Fountain provisions sandboxes on. Sprites, E2B, or a self-hosted runner. Read [the sandbox contract](../integrations/sandbox-contract.md). |
| **Skill** | A `SKILL.md` that Fountain writes into the sandbox, inline or from GitHub. |
| **Sprite** | One sandbox on the Sprites provider. Not a Fountain concept. Read [Sprites](../integrations/sprites.md). |
| **Substitution** | `${VAR}` interpolation in an Agent config, resolved from the merged secrets at spawn. |
| **Suspend** | To scale a sandbox to zero and keep its disk, so the agent's memory survives. |
| **Teammate** | An Agent with one Conversation that continues, on the reserved channel `fountain:team`. Not a primitive. Read [Agents as teammates](../concepts/teammates.md). |
| **Turn** | One prompt, and the work that comes after it, in a Conversation. |

## Two things that sound like primitives and are not

A **team** is not an object. Read
[Agents as teammates](../concepts/teammates.md).

A **sandbox** is not an object you create. Fountain provisions it when a
Conversation starts. You can list one, put a second Conversation on it with
`sandbox_id`, and reset a persistent one. Read
[Sandboxes](../api.md#sandboxes) and
[About conversations](../concepts/conversation.md).
