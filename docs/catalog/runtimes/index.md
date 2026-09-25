# Runtimes

A runtime is what a sandbox runs. For four of the five it is a coding-agent
CLI. It is one field on an [Agent](../../concepts/agent.md). It decides which
provider's credential that agent needs, how skills land on disk, and where
Fountain writes the system prompt.

## The five

| Runtime | Provider | Transport | Multi-provider |
|---|---|---|---|
| [claude](claude.md) | `anthropic` | ACP | No |
| [codex](codex.md) | `openai` | ACP | No |
| [opencode](opencode.md) | Any of the three | ACP | **Yes** |
| [gemini](gemini.md) | `google` | ACP, through `gemini --acp` | No |
| `acp` | None | ACP, through the command you name | Not applicable |

## How to choose

**Choose the runtime whose provider you hold a key for.** That constraint
decides it most of the time. Inference credentials belong to one user, who
enters them in the app, and Fountain can export keys for exactly three
providers. Read
[Services Fountain uses](../../integrations/index.md).

**Choose `opencode` to make one agent definition work across providers.** It
is the only multi-provider runtime. It takes the canonical `provider/model-id`
string word for word, then reads the prefix to decide which key to export.

**Choose `acp` to run a program instead of a model.** The agent names a
command in `runtime_command`, Fountain launches it inside the sandbox, and it
speaks the protocol back. There is no model, no inference credential and no
adapter to install. A deterministic operation that wants a warm machine, a
vault, a thread and a schedule is what this is for. Read
[Running a program as an agent](#running-a-program-as-an-agent).

**Every runtime speaks ACP.** Gemini was the last CLI onto it, and it joined
on 2026-08-22. So editor integration, the permission flow and the shared block
format reach every runtime. The choice is about the provider and the program
rather than about the transport.

## Running a program as an agent

The `acp` runtime takes one extra field. Set it in the console, in a manifest
you send with `fountain apply`, or on `POST /api/agents`.

```yaml
apiVersion: fountain.dev/v1
kind: Agent
metadata:
  name: converger
spec:
  runtime: acp
  runtime_command: exec chant acp --env prod
  environment: chant-toolchain
```

Five things follow from that.

- **The command is a shell line.** Fountain runs it inside the sandbox with
  the login shell, so the sandbox's own `PATH` resolves it and
  `cd /srv/app && exec ./bin/agent acp` is a legal value. Write `exec` before
  the program. Without it the shell stays as the parent, and an interrupt
  stops the shell and can leave the program running on a persistent sandbox.
- **Nothing may print on stdout before the program starts.** The login shell
  reads your profiles first. A profile that writes a banner puts those bytes
  in front of the first protocol message, and the turn fails on a line the
  client cannot read. Send that output to stderr, or guard it on an
  interactive shell.
- **You install the program.** Name it in the environment's packages, or in
  the environment's setup script. Fountain installs no adapter for this
  runtime.
- **`model` is optional, and it does nothing.** Fountain resolves no inference
  credential, so a turn runs on an account that holds no API key at all.
- **`runtime_command` is a 422 on each other runtime.** Those resolve their
  own executable from a pinned table, and a command there would never run.
- **Everything else is unchanged.** Skills mount, MCP servers reach the
  session, `session/cancel` reaches the process on an interrupt, and the
  permission policy holds for each `session/request_permission` that arrives.

The field is a free string rather than an entry in a catalog. It runs inside
the sandbox, under the same isolation as an environment's setup script, so a
catalog would restrict a self-hoster and protect nobody.

**Know what that isolation is on a runner.** On a hosted sandbox provider it
is a machine of its own. On `sandbox_provider: runner` with the default
backend it is a directory, and the command runs as the daemon's user with the
host's `PATH` and network. Read
[trusted mode](../../integrations/runners.md#read-this-first-trusted-mode)
before you name a command there.

With credits on, a turn on this runtime is priced by sandbox time. There is no
token count to record, so `usage` on the turn is null.

## The rule that catches people

Fountain stores `model` as `provider/model-id`. **It validates the provider
half, and it does not validate the model id.**

The provider must match the runtime. Fountain rejects a mismatch when you save
the agent. It holds no credential for the wrong provider, and the sandbox
would start with no inference key at all.

Fountain passes the model id to the CLI unchanged. A model that ships after
your Fountain version still works, and a typo reaches the CLI and fails there.

## Suggested models

The agent form offers these as suggestions. They are not an allowlist.

| Provider | Suggested |
|---|---|
| `anthropic` | `claude-fable-5-1`, `claude-opus-5-5`, `claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5` |
| `openai` | `gpt-6-astra`, `gpt-5.5` |
| `google` | `gemini-3.1-pro-preview`, `gemini-3.7-flash` |

`GET /api/catalog` returns this list for each runtime. A client can then
render the current set, and it does not hard-code one.

## Where skills and prompts land

Each runtime has its own layout on disk. That is why one skill list produces
different paths.

| Runtime | Skills root | skills.sh agent | System prompt |
|---|---|---|---|
| `claude` | `/home/sprite/.claude/skills` | `claude-code` | `~/.claude/CLAUDE.md` |
| `codex` | `/home/sprite/.codex/skills` | `codex` | `~/.codex/AGENTS.md` |
| `opencode` | `/tmp/.config/opencode/skills` | `opencode` | `~/.config/opencode/AGENTS.md` |
| `gemini` | `/tmp/.gemini/skills` | `gemini-cli` | `~/.gemini/GEMINI.md` |
| `acp` | `/home/sprite/.claude/skills` | `claude-code` | None |

The `acp` runtime has no CLI of its own, so it borrows claude-code's layout
for skills and gets the path as `FOUNTAIN_SKILLS_DIR` in its environment. It
reads no system prompt file, because the command owns its own configuration.

## Related

- [About agents](../../concepts/agent.md), where you set `runtime`.
- [Skills](../skills/index.md).
- [`fountain acp`](../../integrations/acp.md), the adapter that drives each of
  them from an editor or a chat surface.
