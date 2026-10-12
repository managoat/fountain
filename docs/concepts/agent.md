# About agents

This page explains what an Agent is, and which of its fields carry a decision
and not a setting. For each field, read the
[API reference](../api.md).

## What an agent is

An Agent is a named configuration for a coding agent that you can run again
and again. It is config, and not a process. Nothing runs until a
[Conversation](conversation.md) runs it.

An Agent carries these choices.

- **`model`**, as `provider/model-id`. An example is
  `anthropic/claude-sonnet-5`.
- **`runtime`**, one of `claude`, `codex`, `gemini` or `acp`.
- **`environment`**, an optional [Environment](environment.md) to start from.
- **`inference_credential_id`**, an optional [credential set](secrets.md#credential-sets)
  to use instead of the account default.
- **`allowed_inference_credential_ids`**, which credential sets a launch may
  request. `null` allows any set in the account, `[]` forbids a different set,
  and a list permits those IDs. The agent's own set remains allowed.
- **`system`** and **`description`**, the system prompt and a summary that a
  person reads.
- **`skills`**, either inline or from GitHub.
- **`mcp_servers`**, the MCP server definitions, with `${VAR}` substitution in
  their env.
- **`metadata`**, a free-form map for your own records.
- **`sandbox_mode`**, `ephemeral` or `persistent`. Read
  [About sandboxes](sandboxes.md).
- **`runtime_command`**, the command that the `acp` runtime launches. It is
  null on each other runtime.

## Why it exists

An Agent is the thing you name and hand to somebody else.

Without it, each run would carry its own model choice, prompt and tool
configuration. Two people would ask the same agent for the same thing and get
different behavior. The Agent is the unit that makes a run repeatable, and a
teammate starts from one. Read [agents as teammates](teammates.md).

## Why Fountain checks the provider and not the model id

This asymmetry surprises people, and it is deliberate.

The provider must match the runtime. Use `anthropic` for `claude`, `openai`
for `codex`, and `google` for `gemini`. The `acp` runtime takes none. It
runs a program rather than a model.

Fountain rejects a provider outside that set at write time. It holds no
credential for such a provider. A sandbox from that config would start with no
inference key at all. It would fail on the first turn, and the error would
point nowhere useful. The write-time rejection turns an unclear runtime
failure into a clear form error.

Fountain does not check the model id against a list. The agent form suggests
current models. Fountain passes what you type to the runtime's CLI unchanged,
so a model that ships after your Fountain version still works.

To validate the id, Fountain would have to ship a list. That list would go
stale between releases, and a stale allowlist costs more than a typo does.

## How the system prompt reaches the machine

Fountain writes the system prompt into the runtime's user-level instructions
file on the agent's sandbox. It writes it at provision, and again at each
reattach.

| Runtime | File |
|---|---|
| `claude` | `~/.claude/CLAUDE.md` |
| `codex` | `~/.codex/AGENTS.md` |
| `gemini` | `~/.gemini/GEMINI.md` |

The `acp` runtime has no such file, and Fountain writes none. The command owns
its own configuration.

Fountain rewrites the file on reattach. An edit to an Agent's system prompt
therefore reaches a sandbox that already exists, the next time that sandbox
wakes. It does not reach a turn that is already in flight.

## Skills and MCP servers

Each `skills` entry is inline or it comes from GitHub. An inline entry is
`{name, content}`, and Fountain writes a full `SKILL.md` into the sandbox. A
GitHub entry is `{source: "owner/repo"}`, and the skills.sh CLI installs it.

Each sandbox also gets two skills, whatever the Agent asks for.

- **`fountain`** gives the agent Fountain's own API, so the agent can start
  sub-conversations.
- **`create-team`** is a question and answer flow that sets up the user's team.
  A first teammate runs it when somebody answers `/create-team`.

An `mcp_servers` entry takes `${VAR}` substitution in its `env`. Fountain
resolves the reference from the merged environment and vault secrets at spawn
time.

```yaml
apiVersion: fountain.dev/v1
kind: Agent
metadata:
  name: researcher
spec:
  model: anthropic/claude-sonnet-5
  runtime: claude
  environment: python-data-env
  skills:
    - source: anthropics/skills
      name: brainstorming
  mcp_servers:
    github:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-github"]
      env:
        GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PAT}"
```

`${GITHUB_PAT}` resolves from the merged environment and vault secrets. Read
[substitution](../api.md).

Substitution applies to the whole entry, and not to `env` alone. A header, a
URL or an argument takes a reference too.

Write `$$` for a literal `$`. Use it when the value must reach the runtime
unresolved. Fountain turns `"Bearer $${FOUNTAIN_TOKEN}"` into
`"Bearer ${FOUNTAIN_TOKEN}"`, and the runtime then reads `FOUNTAIN_TOKEN` from
the sandbox environment. Fountain resolves each reference one time, and does
not scan the result again.

The runtime receives one configuration. Fountain resolves it at spawn time,
and the project file in the sandbox and the agent session both carry the same
document.

## What an agent is not

**Not a process that runs.** An Agent that nobody has run has no sandbox, no
memory and no cost.

**Not a hard scope.** `allowed_environment_ids`, `allowed_vault_ids` and
`allowed_inference_credential_ids` bound which environments, vaults and
credential sets a launch can name. They are the Agent's own
allowlists, and not a tenancy boundary. Fountain enforces tenancy separately,
on each query.

**Not the ACP sense of "agent".** In the Agent Client Protocol, "agent" means
the process that an editor spawns. Read
[`fountain acp`](../integrations/acp.md).

## Config history and rollback

Fountain writes a version each time an agent's config changes. Open the
History page from the agent's edit page to see them. Each version shows what
changed, field by field, against the version before it.

Deleting an environment or vault also writes a version for each agent whose
configuration changes. The deleted environment stops being the default, and
the deleted resource leaves the agent's allowlist. An emptied allowlist stays
empty; it does not become unrestricted. Older versions keep their original
configuration.

A rollback applies an old version's config as a new edit. Fountain does not
rewrite history: the rollback itself becomes the newest version. Fountain
checks the old config again on the way back in, and refuses a version that
names removed infrastructure with an error.

Each conversation records the version it launched under. Its inference source
also has a durable binding, including the selected model and runtime. A later
agent edit or default-set change does not silently replace that source on
wake or resume. See [credential sets](secrets.md#credential-sets) for how
replacement and deletion affect an existing conversation.

## Where to go next

- [About conversations](conversation.md), which run an Agent.
- [Agents as teammates](teammates.md), which is one Conversation for each
  Agent.
- [About environments](environment.md), which an Agent names.
- [Runtimes](../catalog/runtimes/index.md), compared.
- [Skills](../catalog/skills/index.md), and the two that each sandbox gets.
- [Glossary](../reference/glossary.md), for the three senses of "agent".
