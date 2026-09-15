# Run Codex as an API

> OpenAI's Codex CLI, headless in the sandbox.

Run Codex on a sandbox with your repositories, packages and credentials.
Send a prompt over HTTP, follow the transcript, and send the next prompt to
the same conversation. Fountain manages the machine between turns.

To use a chat interface, [open Conversations](https://fountain-conversations.demo.managoat.com/).
To call it from your own code, follow the [quickstart](../../quickstart.md),
then use the agent definition below.

## Summary

| | |
|---|---|
| Provider | `openai` |
| Multi-provider | No |
| Transport | ACP, through the pinned `codex-acp` adapter |
| Skills root | `/home/sprite/.codex/skills` |
| skills.sh agent | `codex` |
| System prompt | `~/.codex/AGENTS.md` |
| Credential | An OpenAI API key |

## Why you would choose this one

You want an OpenAI model to do the work. Or you compare two runtimes on the
same task.

## Set it up

```yaml
apiVersion: fountain.dev/v1
kind: Agent
metadata:
  name: reviewer
spec:
  runtime: codex
  model: openai/gpt-6-astra
```

The model must carry the `openai/` prefix.

Add your OpenAI key at `/account/inference-credentials` in the app.

## Call it over HTTP

After you apply the agent definition, set `FOUNTAIN_AGENT_ID` to the returned
agent id, `FOUNTAIN_BASE_URL` to your instance URL, and `FOUNTAIN_API_KEY` to
your Fountain account key. The account key is separate from the model credential.

```sh
--8<-- "docs/snippets/first-request.sh"
```

Use the returned conversation id to [follow events and send another prompt](../../api.md).
A self-hosted instance uses the same request at its own base URL.

## Verify

Check the turn's `model_selection` in `GET /api/conversations/:id/turns`.
The same fields appear in the `model` stream stage:

- `requested_model`: the ID sent to the runtime.
- `effective_model`: the runtime's selected ID, or `null` on selection failure.
- `source`: `runtime` for a returned model field, or `selection_ack` when the
  runtime accepted the setter without returning a model field.
- `status` and `error`: whether selection succeeded and the failure message.

Selection evidence is separate from the agent's saved model. To verify actual
execution, inspect Codex's session JSONL `turn_context.payload.model`. An
assistant's answer about its model is not execution evidence.

An explicit model that the runtime rejects stops the turn before inference.
Fountain does not substitute another model. An unavailable ID in the runtime
catalog does not, by itself, prove that your provider account lacks access.
Check the bundled Codex version, its refreshed `model/list` response, and the
provider response with the same credentials.

Fountain checks the pinned adapter version before opening a new connection,
including on a persistent sandbox. An existing connection keeps its process
until it closes. If an old runtime rejects the model, the failed connection
closes; retrying opens the updated adapter against the same session and disk.
The sandbox must allow registry access through its configured network path.

A saved agent model change takes effect on the next user turn, including on
an existing ACP connection. The conversation, session, transcript and worktree
remain in place. A change during a running turn applies to the next turn.

## The sandbox codex builds for itself

Codex applies a sandbox policy of its own **inside** the Fountain sandbox. The
pinned `codex-acp` adapter sends that policy with each session, and its default
is a writable workspace and nothing else.

| What the adapter sends | Default |
|---|---|
| The mode | `workspaceWrite` |
| `writableRoots` | `[]` |
| `networkAccess` | `false` |

Two things a first turn often does are refused by that default. A write
outside the workspace fails, which includes the `.git` of a clone that lives
elsewhere, so a command that cuts a worktree from a shared clone cannot write
its entry. And every network call fails, so `git fetch`, a package install and
a `curl` the agent runs itself all fail.

`~/.codex/config.toml` does not widen it. The adapter sends an explicit
per-session policy, and that policy wins over the file, in the same way the
`CODEX_CONFIG` overlay wins over a `model_provider` written into it.

### Give codex full access

Set `INITIAL_AGENT_MODE` to `agent-full-access` in the
[environment's](../../concepts/environment.md) `env_vars`. The adapter reads it
from the process environment when it opens the session.

```yaml
apiVersion: fountain.dev/v1
kind: Environment
metadata:
  name: codex-full-access
spec:
  env_vars:
    INITIAL_AGENT_MODE: agent-full-access
```

Six things follow from that.

- **It is all or nothing.** The value names a mode, not a list. There is no way
  today to say "the workspace, plus this one root, plus the network". Neither
  an Agent nor an Environment carries a writable-roots field, and Fountain
  renders nothing into the adapter's policy on your behalf.
  [#1684](https://github.com/managoat/fountain/issues/1684) tracks the general
  version. The policy will live on the Environment when it is built, beside
  the repositories and the network policy it belongs with.
- **It is not a permission policy.** The agent's
  [permission policy](../../concepts/permissions.md) answers each
  `session/request_permission` while a turn runs. This is the sandbox codex
  builds before it asks anything. Full access does not loosen a policy of
  `ask` or `auto_deny`, and a policy of `auto_allow` does not widen this
  sandbox.
- **It does not widen Fountain's own egress.** An environment with
  `networking_type: limited`, and the credential broker where it is on, still
  decide which hosts a request reaches. Full access lets codex attempt the
  call. The
  [network policy](../../concepts/environment.md#the-network-policy-is-not-symmetric)
  decides whether it lands, and a host that is not allowed still gets a 403
  that names it.
- **Every conversation on that environment gets it.** Give the agents that
  need full access an environment of their own. A launch can then name it with
  `environment_id`, within the agent's `allowed_environment_ids`, rather than
  widening the environment everything else shares.
- **The value is scrubbed from the logs.** It is longer than the 8-byte
  redaction floor, so an agent that prints its environment shows
  `INITIAL_AGENT_MODE=[REDACTED]`. That is the scrubber working, and not a
  variable that failed to arrive. Read
  [Where a secret comes from](../../concepts/secrets.md#hop-5-a-hop-back-fountain-scrubs-the-output).
- **It is codex only.** claude, gemini and opencode do not express a sandbox
  this way. The variable reaches them and means nothing to them.

## Limits

The CLI takes the bare model id, so Fountain removes the `openai/` prefix
before it calls the CLI. You never see that in normal use. It matters when you
read a spawn command in the logs.

On a deployment with the egress broker on, Fountain moves the conversation
onto a model provider of its own. The provider is the same endpoint with the
WebSocket transport off. Codex's WebSocket dialer cannot use the broker's
https-scheme proxy. It waits out the full connect timeout before it falls back
to HTTP, which was about 300 seconds on every turn. Fountain
carries across `OPENAI_BASE_URL`, the OpenAI-Organization and OpenAI-Project
header mappings, and standalone web search. A conversation with no
`OPENAI_API_KEY` keeps the built-in provider, which reads `~/.codex/auth.json`.

Fountain reads only the `CODEX_CONFIG` overlay when it does this. A
`model_provider` that your setup script writes into `~/.codex/config.toml` is
not read, and the overlay wins over the file. An agent that reached a gateway
that way now reaches the endpoint above instead. To keep your own provider,
name it in `CODEX_CONFIG`, which Fountain leaves alone.

The sandbox images do not pin the Codex CLI. The field that turns the
transport off is `supports_websockets`, which Codex 0.153.3 accepts. A later
Codex that ignores the field brings the 300-second wait back, and nothing in
Fountain reports it. The symptom is the gap between the `model` stream stage
and the first agent output. See
[openai/codex#13103](https://github.com/openai/codex/issues/13103).

## Related

- [About agents](../../concepts/agent.md)
- [`fountain acp`](../../integrations/acp.md)
- [Runtimes](index.md)
