# Hermes Agent

[Hermes Agent](https://github.com/NousResearch/hermes-agent) is Nous
Research's self-hosted agent. It is a CLI, a TUI, and a gateway that fronts
Telegram, Discord, Slack and the rest. It has a plugin system for new tools.

Fountain ships a Hermes plugin. It turns each Fountain agent on your account
into something Hermes can delegate to. Hermes calls `fountain_run`, Fountain
provisions a sandbox for that agent, the work runs there, and the answer comes
back as the tool result.

```
  Hermes (CLI / TUI / gateway)  ──HTTPS──▶  Fountain  ──▶  sandbox: the Fountain agent
    fountain_run(agent, prompt)              /api/*         (its environment, vault, runtime)
```

It is **delegation, and not a model provider.** Hermes keeps its own model and
its own loop. A Fountain agent is a contractor that Hermes hands a task to,
then hears back from.

Hermes's `copilot-acp` provider uses an ACP agent *as the LLM*, and it would
also accept `fountain acp`. But it opens a fresh session for each model call,
which for Fountain means one sandbox for each Hermes turn. The plugin is the
path we intend.

Four reasons to reach for it.

- **The work runs off the Hermes host**, in a sandbox with the agent's own
  environment. That is its packages, cloned repos and network policy, and
  secrets that never touch the machine Hermes runs on.
- **The unit is a Fountain agent** that the user already named and configured.
  The Hermes model picks one by name.
- **A conversation takes many turns and lasts.** Hermes gets a
  `conversation_id`, and it can follow up in the same sandbox. The same
  conversation is open in the Fountain conversations app while it runs.
- **Fan-out is a loop of tool calls**, and not orchestration code.

## Summary

| | |
|---|---|
| Direction | Inbound. Hermes delegates to Fountain. |
| Talks over | The HTTP API, through a plugin. |
| Configured on | The Hermes host. |
| Plugin | Ships in this repo, under `integrations/hermes/`. |
| Credential | An API key, or the CLI's saved login. |
| Operator setup | None. |

## Setup

1. Credentials. On the Hermes host, export a key.

    ```bash
    export FOUNTAIN_API_KEY=ftn_…                       # from Settings → API keys, or the CLI
    export FOUNTAIN_BASE_URL=https://fountain.example  # only for a self-hosted instance
    ```

    Or install the CLI and log in. The plugin reads `~/.fountain/credentials`
    exactly as the CLI does, and `FOUNTAIN_PROFILE` chooses a profile.

    ```bash
    brew install managoat/tap/fountain
    fountain auth login
    ```

    In a Fountain sandbox you need nothing. The plugin picks up the
    `FOUNTAIN_TOKEN` scoped to that conversation, and marks the conversations
    it starts as children of the one it runs in.

2. Install the plugin, and turn it on.

    ```bash
    hermes plugins install managoat/fountain/integrations/hermes/fountain --enable
    ```

    From a checkout of this repo, a symlink does the same. Run
    `ln -s "$PWD/integrations/hermes/fountain" ~/.hermes/plugins/fountain`,
    then `hermes plugins enable fountain`.

3. Check it.

    ```
    hermes plugins doctor ~/.hermes/plugins/fountain    # 7 tool(s) registered
    hermes                                              # then, in the session:
    /fountain whoami
    /fountain agents
    ```

    The tools are on for the CLI and the TUI by default. If you saved an
    explicit toolset list with `hermes tools`, tick **Fountain** there.

Optional settings live under `plugins.entries.fountain.settings` in Hermes's
`config.yaml`, and they win over the environment. They are `base_url`,
`api_key`, `profile` and `default_timeout_seconds`. Read Long turns below.

## What Hermes gets

| Tool | Does |
|---|---|
| `fountain_agents` | Lists the account's agents, with name, runtime and model. |
| `fountain_run` | Starts a conversation with an agent, on a fresh sandbox. It waits for the answer. `vault` and `environment` choose the overrides for that run. `wait: false` returns the id at once. |
| `fountain_send` | Runs a follow-up turn in the same conversation. The agent remembers the earlier turns, and the sandbox keeps its files. |
| `fountain_wait` | Waits longer on the current turn, and collects what arrived since the last look. |
| `fountain_status` | Returns lifecycle status and turns, and waits for nothing. |
| `fountain_conversations` | Lists the live conversations on the account. |
| `fountain_terminate` | Ends a conversation and destroys its sandbox. |

Each result carries the conversation's `url`, so the transcript is one click
away in the Fountain UI. The answer itself is the agent's text.

Fountain serves the log feed already parsed into blocks, with `?blocks=true`,
from ADR 0014. So the plugin never learns a runtime's dialect. A claude,
codex, gemini or opencode agent all come back the same way.

Two extras come with it. A `fountain` skill, at
`skill_view("fountain:fountain")`, tells the Hermes model *when* to delegate
and how to brief an agent. A `/fountain` slash command drives it by hand from
any Hermes surface, with `agents`, `run <agent> <prompt>`, `send`, `wait`,
`status`, `conversations`, `terminate` and `whoami`.

## Long turns

A Fountain turn can run for many minutes. Hermes puts a deadline of 420 s on a
tool call by default, in `timeouts.tools.sequential_call`.

The plugin never sits inside one call for the life of a turn. `fountain_run`,
`fountain_send` and `fountain_wait` return after `timeout_seconds`.
`default_timeout_seconds` sets that, and it is 300 by default.

They return `done: false` and the output so far. The model then calls
`fountain_wait` to continue. The plugin remembers the cursor, so each call
returns the new text alone.

The skill spells this out. A turn ends when `done` is `true` and `turn_state`
says `done`, `failed`, with a `reason`, or `interrupted`.

The provision happens inside the first wait. A cold sandbox usually takes 20
to 90 s before the agent's first token. It depends on the sandbox provider and
on the environment's setup script.

## Limits

- **No permission prompts.** A Fountain agent runs under the sandbox's own
  policy, so there is nothing for Hermes to approve. Fountain forwards a
  permission request to an ACP client, and the API answers one at
  `POST /api/conversations/:id/requests/:request_id`. This plugin polls the
  log feed and answers none, so an `ask` policy waits until the server's
  timeout refuses it. Read [Conversations](../api.md#conversations).
- **Text only, and one direction.** The plugin returns the agent's text and
  the names of the tools it used. A file the agent wrote stays in the sandbox.
  Push it from the environment's repo, or ask the agent to print it. A prompt
  cannot carry an image through the plugin.
- **You choose an agent, and you do not manage one here.** To create or edit
  an agent, an environment or a vault, use Fountain's console, the
  [API](../api.md), the CLI or `fountain apply`. The plugin lists what
  exists, and runs it.

The plugin's source and its tests are at
[`integrations/hermes/`](https://github.com/managoat/fountain/tree/main/integrations/hermes)
in the Fountain repo.

## Related

- [API reference](../api.md), which is everything the plugin wraps.
- [TypeScript SDK](../sdk.md), if you build the same thing in TS.
- [Plug into Fountain](clients.md).
