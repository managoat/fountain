# Skills

Skills are Markdown files that Fountain mounts into every sprite at provision time, making them available to the runtime as persistent instructional context. They are the primary mechanism for giving agents durable knowledge: how to spawn sub-agents, which tools to reach for, how to follow project conventions.

## The built-in `fountain` skill

Every conversation gets the bundled `fountain` skill automatically — you do not need to declare it, and you cannot remove it. It is always the first skill mounted regardless of what else is in the agent's `skills` list.

The skill gives the agent inside the sprite everything it needs to call back to Fountain's API:

- `FOUNTAIN_BASE_URL` — the public URL of your Fountain server
- `FOUNTAIN_TOKEN` — a per-conversation API key scoped to the owning user, rotated on every fresh provision
- `FOUNTAIN_CONVERSATION_ID` — this conversation's UUID, passed as `X-Fountain-Parent-Conversation-Id` when spawning children so the full spawn chain is recorded

With those three env vars and the skill's instructions, any agent can spawn new conversations, fan out work across multiple agents, poll for results, stream output, and tear down conversations when done. See **Spawning sub-agents** for the full patterns.

`FOUNTAIN_TOKEN` carries the same Fountain blast radius as the owning user — treat prompt injection on a sprite-bound agent as a potential account takeover for that user. The per-conversation scoping limits *how long* a leaked token stays live, not what it can do while it is live.

To inspect the exact skill text your server is running, read it from inside any sprite:

```bash
# claude
cat ~/.claude/skills/fountain/SKILL.md

# codex (concatenated into AGENTS.md)
cat ~/.codex/AGENTS.md | head -60

# gemini
cat ~/.gemini/GEMINI.md | head -60
```

## Per-runtime mounting

Where a skill lands depends on the runtime:

| Runtime | Location | How used |
| --- | --- | --- |
| `claude` | `~/.claude/skills/<name>/SKILL.md` | Auto-discovered by Claude Code at session start |
| `codex` | concatenated into `~/.codex/AGENTS.md` | Read as global agent instructions |
| `gemini` | concatenated into `~/.gemini/GEMINI.md` | Read as global instructions |

For claude, each skill lives in its own named directory and is discovered independently — Claude Code's skill loading finds them all. For codex and gemini, all skills are concatenated in declaration order into a single flat file. The `fountain` skill is always first in that concatenated output.

## Adding skills to an agent

The `skills` field is a JSON array on the agent. Each entry is one of two shapes.

### GitHub skill

Installed from a `owner/repo` source via the [skills.sh](https://skills.sh) CLI at provision time:

```json
[
  {"source": "anthropics/skills", "name": "frontend-design"},
  {"source": "anthropics/skills"}
]
```

`name` is optional — when given, Fountain passes `--skill <name>` so that one named skill is installed from the source; when omitted, skills.sh installs what the source declares. Installs run via `npx -y skills@latest add <source> --global` on the sprite **before** the network policy locks the sprite down, so they can reach npm and GitHub.

### Inline skill

Content written directly from the agent definition, no network required:

```json
[
  {
    "name": "project-conventions",
    "content": "# Conventions\n\n- All DB migrations must be reversible.\n- Never commit `.env` files."
  }
]
```

`content` is the full Markdown body written to `<skills_root>/<name>/SKILL.md`. Inline skills are written after all GitHub installs have completed.

## Injection order

1. **Bundled `fountain` skill** — always first, injected by Fountain itself
2. **GitHub skills** — installed in declaration order (concurrent), before network lockdown
3. **Inline skills** — written in declaration order, after GitHub installs finish

Runtime config files (`~/.claude.json`, `~/.codex/config.toml`, etc.) are written after all skills are mounted.

## Known good patterns

### General-purpose agent that can spawn sub-agents

The `fountain` skill is automatic — you don't need to add it. A blank `skills` array is sufficient for an agent that just needs to spawn. For one that should also be a capable coder, layer workflow skills on top:

```json
[
  {"source": "anthropics/skills", "name": "brainstorming"},
  {"source": "anthropics/skills", "name": "writing-plans"},
  {"source": "anthropics/skills", "name": "test-driven-development"}
]
```

### Code-review / quality gate agent

```json
[
  {"source": "anthropics/skills", "name": "receiving-code-review"},
  {"source": "anthropics/skills", "name": "requesting-code-review"},
  {"source": "anthropics/skills", "name": "verification-before-completion"}
]
```

### Project-specific conventions mixed with GitHub skills

Combine a shared skill bundle with an inline skill for your project's quirks — the inline skill wins on specificity because the agent reads it alongside the shared ones:

```json
[
  {"source": "anthropics/skills", "name": "test-driven-development"},
  {
    "name": "repo-conventions",
    "content": "# Repo conventions\n\n- Use `snake_case` for Elixir, `camelCase` for TypeScript.\n- All Ecto migrations must be reversible (`down/0` required).\n- `mix format` before every commit."
  }
]
```

### Specialised leaf-node worker

Leaf agents that are only ever spawned by orchestrators and never spawn themselves still get the `fountain` skill — it's harmless. Keep the skills list focused on the task:

```json
[
  {"source": "anthropics/skills", "name": "systematic-debugging"}
]
```

### Orchestrator with per-runtime awareness

If the orchestrator needs to spawn agents across different runtimes and interpret their output, include the spawning context from the `fountain` skill (already there) and add a skill with any runtime-specific interpretation notes inline:

```json
[
  {
    "name": "runtime-output-notes",
    "content": "# Runtime output shapes\n\nWhen gathering results from codex agents use `.item.text`; from gemini agents use the last `.content` message. See `$FOUNTAIN_BASE_URL/help/skills` for the full table."
  }
]
```

## Security and validation

Skill `name` and `source` values are validated against `[A-Za-z0-9._/-]` before being interpolated into shell commands on the sprite. Any value that doesn't match that allow-list causes provisioning to fail with a clear error — no silent partial substitution.

GitHub skills are installed via `npx` before the network policy engages. After that point, the sprite's egress is governed by the attached environment's policy. Inline skills bypass the network entirely — they're written via the sprite's internal filesystem HTTP API.
