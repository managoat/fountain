# LLM integration

Fountain exists for an AI coding tool to consume. Each instance serves
discovery endpoints that a machine can read, so an agentic IDE learns the full
API from one fetch. Each one links pages on `/docs`, which needs no login.

The examples below run against your own instance. Point `FOUNTAIN_URL` at it.

```bash
FOUNTAIN_URL=http://localhost:4000
```

## A drop-in skill for Claude Code

```bash
mkdir -p ~/.claude/skills/fountain
curl -fsSL $FOUNTAIN_URL/skill > ~/.claude/skills/fountain/SKILL.md
```

After that, tell Claude to start a researcher agent on Fountain and to audit
the auth module. It works with no more setup.

## Discovery endpoints

| Endpoint | Content | Best for |
|---|---|---|
| `/llms.txt` | An index of the manual, with a summary of what Fountain is. About 2,000 tokens. | A first fetch, or a model with little context to spare. |
| `/llms-full.txt` | Every page that the index links, in one document. About 230 KB. | An agent that must not crawl links. |
| `/skill` | The skill file for Claude Code and Cursor. | IDE skills. |

```bash
curl $FOUNTAIN_URL/llms.txt
curl $FOUNTAIN_URL/llms-full.txt
```

## There is no MCP server for your IDE

**Nobody built one.** An MCP server that exposes the four primitives as tools
to an IDE is an idea that Fountain discussed and did not build. No package
exists to install, and no config block works. Use the `/skill` file above. It
gives an agentic IDE the full API surface in one fetch.

Fountain does host two MCP servers, and each one serves a conversation's own
sandbox, with that conversation's token. They are
[fountain-team](catalog/mcp-servers/fountain-team.md) and
`fountain-buzz`. An IDE cannot connect
to them. Everything they do is also on the [REST API](api.md#team).

## How to use the API from an agent

1. Load the skill from `/skill` when the session starts.
2. Authenticate with a Fountain API key from the agent's environment.
3. Start sub-agents with the CLI or the REST API. The
   [team](api.md#team), [schedule](api.md#schedules) and
   [sandbox](api.md#sandboxes) routes are on the same surface.

Here is an example prompt.

```
Please:
1. Create a Fountain conversation using the "security-auditor" agent
2. Set the prompt to: "Audit apps/fountain/lib/fountain_web/controllers/ for OWASP Top 10 issues"
3. Stream the output and report findings
```
