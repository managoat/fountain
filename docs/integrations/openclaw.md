# OpenClaw (Agent Client Protocol)

[OpenClaw](https://docs.openclaw.ai) is a self-hosted personal assistant. It
fronts a set of chat surfaces, which include Telegram, Discord, Slack, Signal
and iMessage. It routes them to coding harnesses over the
[Agent Client Protocol](https://agentclientprotocol.com), ACP.

Fountain already speaks ACP as an *agent*, through `fountain acp`. Read
[Editors](editors.md). So OpenClaw can drive a Fountain agent the same way it
drives Claude Code or Codex. You talk to it from a chat channel, and the turn
runs in a Fountain sandbox.

There is nothing new to build. OpenClaw is an ACP *client*, and `fountain acp`
is an ACP *agent*. Its `acpx` plugin can point at any custom command that
speaks ACP over stdio. So the integration is a config block, and not code.

```
  OpenClaw (acpx)  ──spawns──▶  fountain acp  ──HTTPS──▶  Fountain  ──ACP──▶  sandbox
   (a chat channel)   (ACP over stdio)                                        (the agent)
```

## Summary

| | |
|---|---|
| Direction | Inbound. OpenClaw drives Fountain. |
| Talks over | [`fountain acp`](acp.md), through OpenClaw's `acpx` plugin. |
| Configured on | The OpenClaw host. |
| Credential | Whatever `fountain auth login` saved there. |
| Needs | Node 22.22.3 or newer. Also 24.15+ or 25.9+. |
| Operator setup | None. The configuration is client-side. |

## What this is, and is not

It is a **chat front-end for a remote conversation.** OpenClaw handles the
channel, which is a Telegram thread or a Discord room. Fountain runs the agent
in a sandbox, on a checkout that the sandbox made, on a machine that is not
the one OpenClaw runs on.

The reply streams back to the channel over ACP. OpenClaw delivers the agent's
message chunks to the chat as they arrive, so there is no publish tool and no
extra wiring.

It is **not** a way for the agent to touch OpenClaw's host, or the files on
it. The adapter declares no filesystem access and no terminal access. The
paths a tool call reports are paths *in the sandbox*, and they travel under
`_meta.fountain.sandboxLocations`, and not as locations you can click. For a
chat surface that is a clean fit and not a caveat. There is no local project
to confuse them with.

Three reasons to reach for this, and not for a harness that OpenClaw hosts
locally.

- **The work outlives the channel.** Close the chat mid-turn, and the turn
  continues. Reopen it, and the server replays the transcript.
- **The unit is a Fountain agent.** That is an environment, vault overrides,
  skills, MCP servers and inference credentials, none of which touch the
  OpenClaw host.
- **The same conversation is open in the Fountain conversations app**, for you
  or for a teammate, while it runs from the channel.

## Setup

OpenClaw runs on Node, and needs **Node ≥ 22.22.3**, or ≥ 24.15, or ≥ 25.9.

1. Install the Fountain CLI on the OpenClaw host, and log in.

    ```bash
    brew install managoat/tap/fountain
    fountain auth login
    ```

    For a self-hosted instance, point at it first. The CLI defaults to the
    hosted one.

    ```bash
    FOUNTAIN_BASE_URL=https://fountain.example.com fountain auth login
    ```

    OpenClaw spawns `fountain acp` as a child process, and that process
    inherits the environment. So the session authenticates with the
    credentials that `fountain auth login` saved. No key goes into OpenClaw's
    config.

2. Install the ACP backend plugin, and turn it on.

    ```bash
    openclaw plugins install @openclaw/acpx
    openclaw config set plugins.entries.acpx.enabled true
    ```

3. Register Fountain as a custom ACP agent. Choose an agent, and
   `fountain agent list` shows yours. One entry names one agent, so add one
   entry for each agent you want to reach.

    ```json5
    plugins: {
      entries: {
        acpx: {
          enabled: true,
          config: {
            agents: {
              // the id you spawn/bind, mapped to the command OpenClaw runs
              fountain: { command: "fountain", args: ["acp", "--agent", "researcher"] }
            },
            // the agent's own policy runs the turn; nobody has measured an
            // `ask` policy through acpx yet (see Limits)
            permissionMode: "approve-all"
          }
        }
      }
    }
    ```

4. Give OpenClaw an agent of its own that runs on that entry. The block above
   is acpx's *harness alias*. OpenClaw's routes, its `sessions_spawn` and its
   channel bindings address an **OpenClaw agent id**. `runtime.type: "acp"`
   ties the two together. The same name in both places keeps it readable.

    ```json5
    acp: { enabled: true, backend: "acpx" },
    agents: {
      list: [
        { id: "fountain",
          runtime: { type: "acp",
                     acp: { agent: "fountain", backend: "acpx", mode: "persistent" } } }
      ]
    }
    ```

    `mode: "persistent"` matters on OpenClaw ≤ 2026.7.1. Read the
    two-conversations note under Limits. If you set `acp.allowedAgents`, add
    `"fountain"` to it. An empty list means no restriction.

    The 2026.8 beta keys agents by id, as
    `agents.entries.fountain = { runtime: … }`, and not by `agents.list[]`.
    `openclaw doctor --fix` migrates a config in the list style.

5. Spawn it from a channel, or bind a channel to it.

    ```
    /acp spawn fountain
    ```

    ```json5
    // pin a Discord channel to this agent
    bindings: [
      { type: "acp", agentId: "fountain",
        match: { channel: "discord", peer: { kind: "channel", id: "…" } } }
    ]
    ```

    A bound channel goes straight to the harness, and no OpenClaw model takes
    part. The other two front doors go through OpenClaw's own
    model first, which then delegates. Those are
    `sessions_spawn(runtime: "acp", agentId: "fountain")` from a turn, and
    `openclaw agent --agent fountain`. Both need OpenClaw's model provider
    configured, and the harness never does.

    To bind a thread, you also need the channel's thread bindings on. That is
    `session.threadBindings`, and the setting for each adapter, such as
    `channels.discord.threadBindings.spawnSessions`. OpenClaw's
    [ACP agents](https://docs.openclaw.ai/tools/acp-agents) page holds the
    detail for each channel.

### A secret for one entry

`--vault <name-or-id>` attaches a [vault](../concepts/vault.md) to each
conversation the entry opens. Vault values override the agent's environment.
So a secret that belongs to *this entry* goes here. An identity the agent
posts under is one example, and a token scoped to one channel is another.

```json5
fountain: { command: "fountain", args: ["acp", "--agent", "researcher", "--vault", "researcher-identity"] }
```

The difference matters as soon as you have two entries. Each agent attached to
an environment shares it. A vault attaches to one conversation, so two entries
stay apart even when they point at the same agent.

### An environment for one entry

`--environment <name-or-id>` provisions each conversation the entry opens from
that [environment](../concepts/environment.md), and not from the agent's own.

Use it when one agent config must run under several baselines. The same
"engineer" then runs against a `fountain` environment in one entry and a
`buzz` environment in another, and you duplicate no agent. The vault, if there
is one, still wins on a key collision. An agent can also restrict which
environments can stand in for its own, with `allowed_environment_ids`.

## What you get

| ACP | What happens |
|---|---|
| `initialize` | The capability handshake. Protocol version 1. |
| `authenticate` | Uses the credentials that `fountain auth login` saved on the host. Fountain skips it when you are already logged in. |
| `session/new` | Creates a conversation for the agent you configured. |
| `session/prompt` | Runs a turn. Messages, thoughts and tool calls stream back to the channel as they happen. |
| `session/cancel` | `/acp cancel` interrupts the turn that runs. |
| `session/load` | Replays the conversation when you resume a session. |
| `session/set_config_option` | Accepted, and not applied. At each spawn OpenClaw pushes the model its brain chose, and a `thinking` level it derives from that. We verified this on 2026.7.1 and on 2026.8.1-beta.2. A Fountain agent carries its model on the agent, so Fountain acknowledges the push and ignores it. The reply's `_meta.fountain.applied: false` says so. |

## Limits, stated rather than discovered

- **No access to the files on the OpenClaw host**, as above.
- **One identity for each host.** OpenClaw is single-user and self-hosted, so
  each session authenticates as the host's Fountain login. This integration
  gives you no Fountain identity for each channel user.
- **We have not measured a permission prompt in a channel.** Fountain forwards
  `session/request_permission` to an ACP client
  ([#708](https://github.com/managoat/fountain/issues/708)), and the setup
  above keeps `permissionMode: "approve-all"` because nobody has driven an
  `ask` policy through OpenClaw yet. An unanswered prompt blocks the tool for 5
  minutes, and Fountain then refuses it. Leave the default until somebody
  measures it.
- **OpenClaw cannot choose the model, or the thinking level.**
  Fountain accepts and ignores OpenClaw's `--model`, the `model` and
  `thinking` on `sessions_spawn`, and the `/acp` model controls. A
  conversation runs its Fountain agent's model, or a model of its own that the
  API sets ([Change the model](../api.md#change-the-model)). ACP has no way to
  set it yet. OpenClaw's own docs say the same for any harness without
  `session/set_model`.
- **On OpenClaw ≤ 2026.7.1, with acpx 0.11, a one-shot spawn opens two
  conversations and uses one.** OpenClaw ensured the acpx session twice, once
  when it initialised the spawn and again when the turn ran. In `oneshot` mode
  acpx answered each with a fresh `session/new`. On Fountain that was two
  conversations for each spawn, each with a sandbox. Nobody prompted the
  first, and it sat `pending` until the idle reaper parked it.

    We re-ran it on 2026.8.1-beta.2, with acpx 0.13, and it no longer happens.
    There is one `session/new` for each spawn. We reported it upstream as
    [openclaw#124852](https://github.com/openclaw/openclaw/issues/124852) and
    [acpx#504](https://github.com/openclaw/acpx/issues/504). On the older
    versions, `mode: "persistent"`, as in Setup, reuses its record. It then
    pays that cost once for each channel thread, and not once for each
    message.
- **A reclaimed sandbox loses the agent's memory.** If Fountain reclaimed a
  conversation's sandbox while you were away, a resume still replays the full
  transcript. The agent itself does not remember it
  ([#649](https://github.com/managoat/fountain/issues/649)).

## Verification

The ACP path here is the one that the [Editors](editors.md) integration uses.
We proved it from start to finish against production.

The spawn was identical to acpx's, `fountain acp --agent <id>`. It inherited
the host environment, and spoke line-delimited JSON-RPC 2.0 over stdio.

It completed `initialize`, then `session/new`, then `session/prompt`. It ran
the turn in a real sandbox. It streamed the agent's reply back as
`agent_message_chunk` updates, with a real stop reason. That is exactly what
`acpx` does when it spawns the command above.

The full gateway round trip is proven too. OpenClaw's own brain runs
`openclaw agent`, which calls
`sessions_spawn(runtime: "acp", agentId: "fountain")`, which reaches acpx,
then `fountain acp`, then the sandbox. The gateway relays the reply back.

We ran that against the real acpx, at 0.11.2 and 0.13.0, and OpenClaw, at
2026.7.1 and 2026.8.1-beta.2. The brain pushed its model and a `thinking`
level at the harness on the way. That is the case that used to abort the turn
([#759](https://github.com/managoat/fountain/issues/759),
[#760](https://github.com/managoat/fountain/issues/760)).

When you test through `openclaw agent`, or with a prompt that must delegate,
check that the harness ran. OpenClaw's own model will happily answer a
"reply with X" prompt itself, and report success. The tell is a
`sessions_spawn` call in the tool summary, and a new conversation on the
Fountain agent. From the Fountain side, `fountain conv list` shows it, with
the turn.

If a session does not start, look at stderr. `fountain acp` writes the
protocol to stdout and **everything else to stderr**. OpenClaw's `acpx` log
shows that. `/acp doctor` reports the backend's health.

To run the command by hand is a fair diagnostic. It waits for JSON-RPC on
stdin, which tells you that the process starts and finds its credentials.

```bash
fountain acp --agent researcher --log-level debug
```

| Message | Meaning |
|---|---|
| `no Fountain agent configured` | The entry has no `--agent`. |
| `agent "x" runs the … runtime, which does not speak ACP` | Every runtime Fountain ships speaks ACP. This names a conversation whose runtime column holds a name that no adapter covers. |
| `credentials for … were rejected` | Run `fountain auth login` on the host. The message names the instance it tried. |
| `could not resolve agent "x" on …` | The wrong name, or the right name on a different instance. |

## How it works

Two ADRs cover the design.
[0014](https://github.com/managoat/fountain/blob/main/decisions/0014-agent-client-protocol.md)
made Fountain an ACP *client* of the coding agents it runs in sandboxes.
[0015](https://github.com/managoat/fountain/blob/main/decisions/0015-fountain-as-an-acp-agent.md)
makes it an ACP *agent* for any ACP client, such as an editor,
[Buzz](https://github.com/block/buzz), or OpenClaw.

Together they make Fountain a proxy. The same block vocabulary arrives from a
sandbox on one side and leaves for the client on the other. So the adapter
forwards an update and translates nothing. OpenClaw is one more client on that
far side. Read the
[2026-08-16 addendum to 0015](https://github.com/managoat/fountain/blob/main/decisions/0015-fountain-as-an-acp-agent.md#addendum--2026-08-16-openclaw-is-another-acp-client-spike-verified).

## Related

- [`fountain acp`](acp.md), the protocol surface in full.
- [Editors](editors.md), the same adapter from an editor.
- [Plug into Fountain](clients.md).
