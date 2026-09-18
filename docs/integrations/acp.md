# `fountain acp`, the ACP agent reference

`fountain acp` is the one process that each ACP client of Fountain spawns.
[Editors](editors.md) such as Zed, [OpenClaw](openclaw.md), and the
Buzz harness all speak the
[Agent Client Protocol](https://agentclientprotocol.com) to it over stdio. It
then drives a conversation in a Fountain sandbox.

Those three pages cover how to configure *the client*. This page is the
reference for the adapter itself. It says what the adapter accepts, what it
does with that, and what it deliberately ignores. The three pages then do not
each state it again.

**What it is, and is not.** It is a control surface for a conversation on your
Fountain instance. Open it, prompt it, watch it, interrupt it, reopen it
tomorrow. It reaches nothing on the machine it runs on, beyond its own stdio
and the CLI's credentials. Each path it reports is inside the sandbox.

## Invocation

```bash
fountain acp --agent <name-or-id> [--vault <name-or-id>] [--environment <name-or-id>] [--sandbox-mode persistent] [--sandbox <id>] [--permission ask] [--log-level debug]
```

| Flag | Meaning |
|---|---|
| `--agent` | **Required, in practice.** The Fountain agent that each session runs. ACP has no field for it, so you configure it for each process. Use one client entry for each agent you want to reach. |
| `--vault` | A vault that attaches to each conversation this process opens. Vault values override the agent's environment, so a secret for one entry belongs here. An identity the agent posts under is the example. Two entries on the same agent with different vaults stay apart. |
| `--environment` | Provisions each conversation from this environment, and not from the agent's own. One agent config then runs under several environments, with one entry for each. The vault still wins on a key collision. When the agent sets `allowed_environment_ids`, the environment must be on that list. |
| `--sandbox-mode` | Where each conversation this process opens runs. `ephemeral` gives each conversation a sandbox of its own. `persistent` puts each one on the agent's own machine. Without the flag, the agent's default applies. See [Sandboxes](../concepts/sandboxes.md). |
| `--sandbox` | A sandbox id to attach each conversation to, instead of a new one. It must be yours, and it must have the same agent, environment and vault. |
| `--permission` | What happens before the agent runs a tool. `ask` sends the question to your client, as an approval prompt. `auto_deny` refuses. The default, `auto_allow`, runs the tool. To narrow it for one kind of tool, give `key=verdict` pairs, such as `execute=ask`. See [Permission prompts](#permission-prompts). |
| `--log-level` | The verbosity on stderr. One of `debug`, `info`, which is the default, `warn` and `error`. |
| `--profile` | Which saved CLI credentials to use. It is a global flag. |

**The credentials are the CLI's.** They come from `FOUNTAIN_API_KEY` and
`FOUNTAIN_BASE_URL` in the environment, or from the profile that
`fountain auth login` saved. There is no login inside the protocol.
`authenticate` verifies what the CLI already holds, and its one advertised
method says only "run `fountain auth login`". A hosted Buzz harness gets a
freshly minted, sprite-scoped key in its environment for exactly this reason.

**stdout carries the protocol and nothing else. Diagnostics go to stderr.**
Your client's agent-server log shows them, and that is the first place to look
when something is wrong.

## The protocol surface

The protocol version is **1**, and Fountain negotiates down to the client's
version when that is lower. `agentInfo` is `fountain`, with the CLI's version.

| Method | What Fountain does |
|---|---|
| `initialize` | The capability handshake. Fountain logs the client's own capabilities, which are `fs` and terminals, and uses neither. This agent works on a sandbox filesystem, and not on yours. |
| `authenticate` | Verifies the CLI's saved credentials against the instance. Fountain advertises it only when it holds none. |
| `session/new` | Resolves `--agent`. It refuses an agent whose runtime has no ACP adapter, which today is no runtime at all. Then it opens a conversation. **The ACP session id *is* the conversation id**, as below. It responds with the agent's model, as the one model available. |
| `session/prompt` | Sends the turn, as text and images. It drops another block with a warning, and refuses a prompt where it can use nothing. It then streams the conversation's ACP output back as `session/update` notifications, until the turn ends. |
| `session/cancel` | Interrupts the turn that runs. |
| `session/load` | Reopens a conversation that this process did not start. It replays the stored `session/update` history **before** the response, as the spec demands. |
| `session/set_model` | Not implemented. The model belongs to the Fountain agent. A change here would change each conversation on that agent. |
| `session/request_permission` (agent → client) | Goes to your client when the policy for that tool is `ask` ([#708](https://github.com/managoat/fountain/issues/708)). It carries the agent's own options. Your answer goes back to the agent. See [Permission prompts](#permission-prompts). |

Fountain advertises `loadSession: true`. On prompts it advertises
`image: true`, `audio: false` and `embeddedContext: false`. A client cannot
inline a local file, which would be context about a machine the agent cannot
see.

Fountain logs `cwd` and `mcpServers` on `session/new`, and ignores both. The
sandbox clones its own checkout, and a Fountain agent carries its own MCP
configuration to the sandbox. Fountain can *add* MCP servers of its own to a
session, and it injects the Buzz publish tools this way. It never adds the
client's.

### The session id is the conversation id

`session/new` returns the Fountain conversation id as the ACP `sessionId`
([ADR 0015](https://github.com/managoat/fountain/blob/main/decisions/0015-fountain-as-an-acp-agent.md),
[#699](https://github.com/managoat/fountain/issues/699)).

That is what makes `session/load` work across processes and across days. An
editor hands back an id from last week, and it resolves to a real
conversation. It does not resolve to a map that died with the process that
minted it. It is also why the same id appears in the web UI, in
`fountain conv`, and in the audit trail.

### What streams back

The sandbox runtime already speaks ACP to Fountain
([ADR 0014](https://github.com/managoat/fountain/blob/main/decisions/0014-agent-client-protocol.md)).
So the adapter is a proxy, and not a translator. It forwards
`agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`
and their siblings as they arrive, and rewrites the `sessionId` to yours.

Two adjustments follow, and both are about the machine boundary.

- **Fountain moves `tool_call.locations` to
  `_meta["fountain.sandboxLocations"]`.** They name files in the sandbox.
  Leave them in place, and an editor opens a path on your machine, or fails to
  open one.
- **A stop reason comes from the sandbox**, such as `end_turn`, `refusal` or
  `cancelled`. Some things have no vocabulary in the sandbox. A sandbox that
  never provisioned, one that Fountain reclaimed mid-turn, and a conversation
  that somebody terminated are the three. Fountain reports each of those as a
  JSON-RPC error, and does not dress it up as "the agent finished".

A dropped SSE connection is not a lost turn. The server closes an idle stream
after 60 s, and the adapter reconnects and continues from where it stopped.

### Conversation titles from the harness

Fountain uses the sandbox harness's standard ACP
[`session_info_update`](https://agentclientprotocol.com/protocol/v1/session-list#updating-session-metadata)
to name conversations. It makes no separate inference request for a title.
The harness can send this notification during a turn or after the prompt
response:

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "the-harness-session-id",
    "update": {
      "sessionUpdate": "session_info_update",
      "title": "Fix login redirect"
    }
  }
}
```

The title is saved on the conversation and refreshes the sidebar. A later
notification can revise a harness title; an omitted `title` leaves it alone,
and `null` clears it. Fountain redacts registered secrets before normalizing
or shortening the title. It collapses whitespace, removes NUL characters,
and limits titles to 120 characters. Complex emoji and combining characters
may shorten this further to fit storage, without splitting a character.
A blank title also clears it. A failed title update leaves the turn running.

Explicit titles, including existing titles whose origin is unknown, stay
unchanged. Renaming a conversation claims its title, even when the name is
unchanged. Teammate names are never changed by these notifications. If a
harness supplies no title, the existing untitled display fallback applies.
Metadata arriving after a turn ends updates the title without opening a new
turn or extending a background turn's quiet timer. The notification is stored
in the transcript only while a turn is open.

For other harness-created values, ACP supports custom data in
[`_meta`](https://agentclientprotocol.com/protocol/v1/extensibility#the-_meta-field).
Fountain does not map arbitrary `_meta` values to conversation fields.

## `_meta` extensions on `session/new`

These are out-of-band fields that a chat harness sends. Fountain ignores each
other field in `_meta`.

| Field | Meaning |
|---|---|
| `channelId` | Names the external channel that this session serves. With it, `session/new` **resumes** the conversation already bound to that channel, for this user, agent and vault. That is the same conversation, the same sandbox and the same runtime session, with a fresh ACP id on the client's side. A harness that forgets its sessions on restart therefore lands back where it was ([#774](https://github.com/managoat/fountain/issues/774)). A destroyed sandbox also stops the resume. The workspace does not survive it, so Fountain opens a new conversation on a new sandbox ([#779](https://github.com/managoat/fountain/issues/779)). Without it, each `session/new` is a new conversation. |
| `sandboxMode` | Where this one session's conversation runs, `ephemeral` or `persistent`. It replaces `--sandbox-mode` for the session. See [Sandboxes](../concepts/sandboxes.md). |
| `sandboxId` | A sandbox id to attach this one session's conversation to. It replaces `--sandbox` for the session. |
| `freshSession` | With `channelId`, it skips the resume this one time. It unbinds the current conversation, which continues and then retires like any other idle one. It opens a new conversation, and binds the channel to that. A Buzz owner's `!rotate` turns into this ([#788](https://github.com/managoat/fountain/pull/788)). Fountain ignores it without `channelId`. |

The same knobs exist on the API, as `channel_id`, `fresh`, `sandbox_mode` and
`sandbox_id` on `POST /api/conversations`. Read
[Conversations](../api.md#conversations), and
[Sandboxes](../api.md#sandboxes) for the list a `sandboxId` comes from.

## `_meta` extensions on `session/prompt`

Send `_meta.clientRequestId` to name one prompt submission:

```json
{
  "sessionId": "<conversation-id>",
  "prompt": [{"type": "text", "text": "Run the approved plan."}],
  "_meta": {"clientRequestId": "plan-7-step-3"}
}
```

The bridge sends it as `client_request_id` on the prompts API route, for both
the first prompt and later prompts, including in resumed sessions. It belongs
to that submission; the bridge does not reuse it for the next prompt or derive
it from the JSON-RPC request ID. Omit it, or send null, to send no correlation
field. Other `_meta` keys are ignored.

The server validates the value: a string of 1 to 200 characters without a null
character. Fountain stores it on the resulting turn. It is not an idempotency
key. See [prompt correlation](../api.md#find-the-turn-your-prompt-opened) for
how to find that turn and the limits of the contract.

## Permission prompts

With `--permission ask`, the agent stops before it runs a tool and asks. The
request starts in the sandbox. It goes to Fountain, then to your client, as an
ACP `session/request_permission`. Your client shows its approval prompt. Your
answer goes back the same way. The tool then runs, or it does not.

Your client gets the agent's own options, and only those. Fountain adds none.
A client that answers with an option that the agent did not offer gets a
refusal, and Fountain denies the call.

**Each other outcome is also a denial.** These are the outcomes.

- Your client dismisses the prompt, or closes, or fails.
- Nobody answers before the server's timeout, which is 5 minutes.
- Another client answers first, and the first answer wins. Your client then
  sees a request that no longer waits.

A denial does not stop the turn. The agent reads that it has no permission for
that tool, and continues.

**A key matches the tool card's title first, and then ACP's kind.** The kinds
are `execute`, `edit`, `read`, `delete`, `move`, `search`, `fetch`, `think`
and `other`. Prefer a kind. The claude runtime puts the command itself in the
title, so a title matches one command and nothing else.

**A launch can only narrow what the agent permits.** A `--permission` that
makes the agent's own policy less strict gets a 422, at `session/new`, that
names the tool. To set the agent's own policy, use the API or the console.

**The opencode runtime never asks.** It decides permission in its own server,
and sends no request. Fountain refuses a policy stricter than `auto_allow` on
that runtime, and says so, and does not pretend to protect you
([#959](https://github.com/managoat/fountain/issues/959)).

## Lifecycle, sandboxes, and what survives

- **A turn ends when the conversation says so.** That is the terminal `turn`
  stage event, with its stop reason. It is not the moment the output goes
  quiet.
- **An idle sandbox suspends, and is not lost.** The next prompt resumes it. A
  sandbox that Fountain reclaimed at its maximum lifetime, or one that fails
  to reattach, comes back as an error on the turn that met it. Prompt again to
  provision a fresh one. Fountain keeps the transcript either way, and
  `session/load` replays it. The agent's own memory in the sandbox does not
  survive ([#649](https://github.com/managoat/fountain/issues/649)).
- **To close the client stops nothing.** The conversation is on the server,
  and the process is a window onto it. Reopen it with `session/load`, from the
  conversations app, or with `fountain conv`.

## When something goes wrong

Start with stderr. Add `--log-level debug` when the default is not enough.
Fountain words an error for a reader inside an editor, and not for one at a
terminal.

| Message | Meaning |
|---|---|
| `no Fountain agent configured` | The entry has no `--agent`. |
| `agent "x" runs the … runtime, which does not speak ACP` | Every runtime Fountain ships speaks ACP. This names a conversation whose runtime column holds a name that no adapter covers. Use that agent from the conversations app, or with `fountain run`. |
| `credentials for … were rejected` | Run `fountain auth login`. The message names the instance it tried, and that is usually the surprise. |
| `could not resolve agent "x" on …` | The wrong name, or the right name on a different instance. |
| `the sandbox never started: …` | The provision failed, and the reason belongs to the sandbox provider. |
| `could not reattach to the sandbox, prompt again to provision a fresh one` | Fountain reclaimed the sandbox. The transcript survives. |

To run the binary by hand is a fair diagnostic. It sits and waits for JSON-RPC
on stdin, which proves that the process starts and finds its credentials.

## Who spawns it

| Client | Who spawns it | Page |
|---|---|---|
| Zed and other ACP editors | The editor, from its agent-server config. | [Editors](editors.md) |
| OpenClaw, on Telegram, Discord or Slack | The `acpx` plugin on the OpenClaw host. | [OpenClaw](openclaw.md) |
| Buzz, on Nostr | `buzz-acp`, which **Fountain itself** supervises on the gateway, one for each hosted identity. | Buzz |

## Test the deployed ACP path

An isolated test instance can enable the fixed `fountain-fixture` runtime with
`DEPLOYED_ACP_FIXTURE_ENABLED=true` and `DEPLOYED_ACP_FIXTURE_USER_ID` set to
one dedicated verified account. It stays absent by default and rejects other
accounts. The four built-in runtimes keep their existing installation paths.
This is a testing seam for #1611 and #1007, not a custom-harness registry.

It is not in the published contract, so no generated SDK offers it as a
runtime. A deployment that names `DEPLOYED_ACP_FIXTURE_USER_ID` names it in
the OpenAPI document that deployment serves at `/api/openapi.json` — including
after the flag goes false, because the agents it created and their
conversations outlive it — and
`runtimes` on `GET /api/catalog` reports what the instance currently admits.

The external `deterministic` profile provisions a real sandbox, verifies the
installed fixture program's digest through the file API, and submits seven
structured prompts over the public conversation API. It checks incremental
SSE, nonce file bytes, permission approval and denial, cancellation, explicit
failure, replay and resume. Cleanup must leave no active turn or sandbox.
The fixture bypasses inference and built-in CLI installation; keep a separate
real-model canary for those guarantees.

See the [deployed suite instructions](https://github.com/managoat/fountain/blob/main/deployed/README.md#deterministic-acp-fixture)
for the target configuration and account/provider requirements. Run this
profile only on a test deployment; it is excluded from production canaries.
