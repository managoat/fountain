# For LLMs

If you're pointing Claude Code, Cursor, Continue, Aider, or any other agentic IDE at Fountain, three plain-text endpoints get you (and it) from zero to operating the API in one fetch.

## The endpoints

- **[`/llms.txt`](/llms.txt)** — short, machine-readable index following the [llms.txt convention](https://llmstxt.org/). Points at the docs, the OpenAPI spec, and the SKILL.md.
- **[`/llms-full.txt`](/llms-full.txt)** — the full doc set inlined as one document. Useful for one-shot uploads or for tools that don't follow links.
- **[`/skill`](/skill)** — a drop-in `SKILL.md` that teaches Claude Code (and anything that loads SKILL.md frontmatter) how to use Fountain. Different from the in-sprite `fountain` skill: this one is for **external** callers driving the API/CLI/manifest.

## Install the skill

Point your agent at Fountain in one command:

```sh
mkdir -p ~/.claude/skills/fountain
curl -fsSL https://managoat.com/skill > ~/.claude/skills/fountain/SKILL.md
```

Self-hosted instance? Substitute your base URL. The skill text itself reads `$FOUNTAIN_BASE_URL` and `$FOUNTAIN_API_KEY` from the agent's environment, so it's not pinned to one host.

For Codex (`~/.codex/AGENTS.md`) or Gemini (`~/.gemini/GEMINI.md`), concatenate the same content into the equivalent agent-instruction file.

## How the two skills differ

| Skill | Where it lives | Used when |
|---|---|---|
| In-sprite `fountain` skill | bundled into every Fountain-provisioned sprite at `~/.claude/skills/fountain/` | the agent is running **inside** a Fountain conversation and wants to spawn sub-conversations — uses `$FOUNTAIN_TOKEN` (per-conversation, auto-injected) and the `X-Fountain-Parent-Conversation-Id` provenance header |
| External SKILL.md (this page) | served at `/skill`, you install it locally | you're an LLM in someone's IDE/CI/shell driving Fountain as an external client — uses `$FOUNTAIN_API_KEY` |

If your environment has `$FOUNTAIN_CONVERSATION_ID` set, you're inside a sprite — use the in-sprite skill (it's already mounted for you).

## State of the standard

llms.txt is a convention, not an enforced standard. Adoption across the major LLM vendors is uneven, but agentic IDEs (Cursor, Continue, Cline, Aider) and documentation-loading MCP servers consume it directly. We serve both because the cost is one controller and the benefit is "an LLM you've never met can figure out how to drive Fountain in 200 lines of text."
