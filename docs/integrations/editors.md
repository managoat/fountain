# Editors (Agent Client Protocol)

Fountain speaks the [Agent Client Protocol](https://agentclientprotocol.com),
ACP. So an ACP-capable editor can drive a conversation on a Fountain agent.
Prompt it, watch it think and call tools, cancel it, close the editor, and
reopen the conversation later.

The editor spawns `fountain acp` as a subprocess and talks JSON-RPC to it over
the pipe. That process talks HTTP and SSE to your Fountain instance.

```
  editor  ──spawns──▶  fountain acp  ──HTTPS──▶  Fountain  ──ACP──▶  sandbox
   (ACP over stdio)                                                  (the agent)
```

## Summary

| | |
|---|---|
| Direction | Inbound. The editor drives Fountain. |
| Talks over | [`fountain acp`](acp.md), spawned locally. |
| Configured on | The developer's machine. |
| Credential | Whatever `fountain auth login` already saved. |
| Configured for | One agent. Use one editor entry for each agent you want to reach. |
| Operator setup | None. |

## What this is, and is not

It is a **control surface for a remote conversation**. The agent runs in a
Fountain sandbox, on a checkout that the sandbox made, on a machine that is
not yours.

It is **not** a way for the agent to edit the files open in your editor. The
integration declares no filesystem access and no terminal access. The file
paths a tool call reports are paths in the sandbox, and Fountain deliberately
does not send them as locations you can click. A click would open the wrong
file on your machine, or open nothing. They travel under
`_meta.fountain.sandboxLocations` instead.

Three reasons to reach for this, and not for a local agent.

- **The work outlives the editor.** Close the laptop mid-turn, and the turn
  continues. Reopen it, and the server replays the transcript.
- **The unit is a Fountain agent.** That is an environment, vault overrides,
  skills, MCP servers and inference credentials, none of which touch your
  machine.
- **The same conversation is open in the conversations app**, for you or for a
  teammate, while it runs.

## Setup

1. Install the CLI and log in.

    ```bash
    brew install managoat/tap/fountain
    fountain auth login
    ```

    For a self-hosted instance, point at it first. The CLI defaults to the
    hosted one.

    ```bash
    FOUNTAIN_BASE_URL=https://fountain.example.com fountain auth login
    ```

2. Choose an agent. `fountain agent list` shows yours. The editor entry names
   one agent, so add one entry for each agent you want to reach.

3. Configure your editor, as below, then start a new thread with it.

### Zed

In `settings.json`, which `zed: open settings` opens:

```json
{
  "agent_servers": {
    "Fountain: researcher": {
      "type": "custom",
      "command": "fountain",
      "args": ["acp", "--agent", "researcher"],
      "env": {}
    }
  }
}
```

Use the agent's name or its id in `--args`. To reach an instance or profile
that is not the default, add `"--profile", "staging"` to `args`, or set
`FOUNTAIN_BASE_URL` in `env`.

### A secret for one entry

`--vault <name-or-id>` attaches a [vault](../concepts/vault.md) to each
conversation the entry opens. Vault values override the agent's environment.
So a secret that belongs to *this entry* goes here. An identity the agent
posts under is one example, and a token scoped to one workspace is another.

```json
"args": ["acp", "--agent", "researcher", "--vault", "researcher-identity"]
```

The difference matters as soon as you have two entries. Each agent attached to
an environment shares it, so each of them uses a credential you put there. A
vault attaches to one conversation, so two entries stay apart even when they
point at the same agent.

### An environment for one entry

`--environment <name-or-id>` provisions each conversation the entry opens from
that [environment](../concepts/environment.md), and not from the agent's own.

Use it when one agent config must run under several baselines. The same
"engineer" then runs against a `fountain` environment in one entry and a
`website` environment in another, and you duplicate no agent. The vault, if there
is one, still wins on a key collision. An agent can also restrict which
environments can stand in for its own, with `allowed_environment_ids`.

### Approve a tool before it runs

By default the agent runs a tool without a question. `--permission ask` puts
the question in your editor instead, as its own approval prompt. The tool waits
for your answer.

```json
"args": ["acp", "--agent", "researcher", "--permission", "ask"]
```

To ask about one kind of tool only, name the kind. `--permission execute=ask`
asks before a shell command, and permits the rest. An entry can only narrow
what the agent itself permits. [Before a tool runs](../concepts/permissions.md)
holds the policy, the keys and the three verdicts.

No answer is an answer. Fountain refuses a prompt that you dismiss. It refuses
one that your editor never answers, and one that waits 5 minutes. The turn
continues either way, and the agent reads that it has no permission.

### Any other ACP client

Nothing in the adapter is specific to Zed. Whatever your client calls it, the
agent command is this, spoken over stdin and stdout.

```bash
fountain acp --agent <name-or-id>
```

[Buzz](https://github.com/block/buzz) is ACP-native and must work the same
way. We have not verified its configuration format for a custom agent. If you
make it work, a note in an issue is welcome.

## What you get

The [`fountain acp` reference](acp.md) holds the adapter's full protocol
surface. It covers each method, the `_meta` extensions that a chat harness
uses, and what Fountain forwards or deliberately ignores. Here is the short
version.

| ACP | What happens |
|---|---|
| `initialize` | The capability handshake. Protocol version 1. |
| `authenticate` | Uses the credentials that `fountain auth login` saved. There is no second login. |
| `session/new` | Creates a conversation for the agent you configured. |
| `session/prompt` | Runs a turn. Messages, thoughts and tool calls stream back as they happen. |
| `session/cancel` | Interrupts the turn that runs. |
| `session/load` | Replays the conversation into an editor you just opened. |
| `session/request_permission` (agent → editor) | Asks you before the agent runs a tool, when the policy says `ask`. Your answer goes back to the agent. |

A prompt can carry images. A dropped connection is not a lost turn. The server
closes an idle stream after 60 seconds, and the adapter reconnects and
continues from where it stopped.

## Limits, stated rather than discovered

- **No access to your local files**, as above.
- **A reclaimed sandbox loses the agent's memory.** If Fountain reclaimed a
  conversation's sandbox while you were away, `session/load` still replays the
  full transcript. The agent itself does not remember it
  ([#649](https://github.com/managoat/fountain/issues/649)).

## When something goes wrong

`fountain acp` writes the protocol to stdout, and **everything else to
stderr**. Your editor's agent-server log shows that. Start there.

```bash
# what the editor runs, with more detail
fountain acp --agent researcher --log-level debug
```

Fountain words an error for a reader inside an editor, and not for one at a
terminal.

| Message | Meaning |
|---|---|
| `no Fountain agent configured` | The entry has no `--agent`. |
| `agent "x" runs the … runtime, which does not speak ACP` | Every runtime Fountain ships speaks ACP. This names a conversation whose runtime column holds a name that no adapter covers. |
| `credentials for … were rejected` | Run `fountain auth login`. The message names the instance it tried, and that is usually the surprise. |
| `could not resolve agent "x" on …` | The wrong name, or the right name on a different instance. |

To run the binary by hand is a fair diagnostic. It sits and waits for JSON-RPC
on stdin, which tells you that the process starts and finds its credentials.

## How it works

Two ADRs cover the design.
[0014](https://github.com/managoat/fountain/blob/main/decisions/0014-agent-client-protocol.md)
made Fountain an ACP *client* of the coding agents it runs in sandboxes.
[0015](https://github.com/managoat/fountain/blob/main/decisions/0015-fountain-as-an-acp-agent.md)
makes it an ACP *agent* for editors.

Together they make Fountain a proxy. The same block vocabulary arrives from a
sandbox on one side and leaves for an editor on the other. So the adapter
forwards an update and translates nothing, and nobody parses a runtime's
output format twice.

## Related

- [`fountain acp`](acp.md), the protocol surface in full.
- [OpenClaw](openclaw.md), the same adapter from a chat surface.
- [Plug into Fountain](clients.md).
