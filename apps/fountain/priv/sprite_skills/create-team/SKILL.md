---
name: create-team
description: Set up the user's Fountain team through a short Q&A — use when the user says "/create-team", "help me set up my team", "I want a few agents for X", or when you are the only teammate and they ask what the team should look like. Asks what they want done, proposes a roster (names, brains, one-line roles), creates the agents and adds them to the team over the Fountain API with `FOUNTAIN_BASE_URL` + `FOUNTAIN_TOKEN`, and explains how to talk to them.
---

# /create-team — a team in five questions

You are a teammate on a Fountain team, and the user wants more teammates. A
teammate is an **agent** (name, brain = `provider/model` + runtime, a short
description, a system prompt) that is **on the team** (`POST /api/team`):
its own computer, one ongoing conversation with the user, reachable from the
team app and from other teammates through the `fountain-team` tools.

Keep it conversational: one question at a time, sensible defaults offered
in the question so "yes" is a complete answer, never more than five
questions before you propose something. The API is at `$FOUNTAIN_BASE_URL`
(under `/api`) with bearer `$FOUNTAIN_TOKEN`; use `curl -s` + `jq`.

## 1. Ask (at most five)

1. **What should the team get done?** (one sentence; examples: "maintain my
   repos and triage issues", "research + write for my newsletter", "keep my
   homelab healthy")
2. **Which repos / services are in scope?** — URLs or names. Note which need
   a token (private repos, deploy targets).
3. **How many teammates, roughly?** Offer a shape based on #1: usually 2–5.
   A *lead/gateway* that knows everyone is worth it past three.
4. **Any brain preference?** Default: the team's default brain for
   engineers is Claude Sonnet; Opus for the lead or anything that spans
   repos. Check what the account can run: `GET /api/catalog` (models per
   runtime) and `GET /api/account/inference-credentials` (which providers
   have a key). Never propose a provider without a key.
5. **Names?** Offer role names (`repo-maintainer`, `issue-triager`) or a
   themed set if they'd like; names must be unique per account.

## 2. Propose, then confirm

Show a table: name · brain · what they do (one line) · first thing you'd
send them. Ask "create these?" — adjust on feedback. Do not create anything
before a yes.

## 3. Create (after the yes)

For each teammate, in order:

```bash
B="$FOUNTAIN_BASE_URL/api"; H=(-H "Authorization: Bearer $FOUNTAIN_TOKEN" -H "content-type: application/json")
AGENT=$(curl -s "${H[@]}" -X POST "$B/agents" -d @- <<JSON | jq -r '.data.id'
{"name":"<name>","model":"<provider/model>","runtime":"<claude|codex|gemini>",
 "description":"<one line>",
 "system":"You are <name>, a teammate on the user's team. Your role: <one line>. You have your own computer; do the work there and report back in chat — concise, concrete, no filler. <repo/scope specifics>"}
JSON
)
curl -s "${H[@]}" -X POST "$B/team" -d "{\"agent_id\":\"$AGENT\"}" | jq -r '.data.name + " → " + .data.presence.label'
```

Runtime follows the brain: `anthropic/*` → `claude`, `openai/*` → `codex`,
`google/*` → `gemini`. If a teammate needs an environment (a repo
mounted, a token, packages), say so and point at Fountain's Environments
page or `fountain apply` — do not invent secrets; the user supplies them.

Optional, when the team has a recurring job (triage, a daily report):
`POST $B/team/<agent_id>/schedules {"name","cron","prompt"}` (five-field
cron, UTC).

## 4. Hand over

Reply with the roster as created (name, presence), who to message for what,
and one concrete first message for each. Mention that teammates can reach
each other (`fountain-team` tools: list_teammates, get_teammate,
send_to_teammate, wait_for_teammate, read_teammate) and that everything — brain, role, name —
is editable later from the team app. If you created a lead/gateway, say
"send your asks to <lead> from now on."

## Rules

- One question at a time; stop asking as soon as you can propose.
- Never create before a confirmation; never delete or rename anything.
- Never paste tokens into prompts, descriptions or messages.
- If `POST /api/agents` fails with a name conflict, add a short suffix and
  say so; if with a missing-credential error, say which provider needs a key
  and where (Account → Inference credentials).
