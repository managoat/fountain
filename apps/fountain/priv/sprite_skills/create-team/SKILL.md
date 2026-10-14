---
name: create-team
description: Set up the user's Fountain team through a short Q&A — use when the user says "/create-team", "help me set up my team", "I want a few agents for X", or when you are the only teammate and they ask what the team should look like. Asks what they want done, proposes a roster (names, brains, one-line roles), writes it as a `fountain apply` manifest for the user to apply (a sandbox token cannot create agents), then confirms the team over the Fountain API and explains how to talk to them.
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

Your token is a sandbox token: it reads agents and the team, but creating an
agent (`POST /api/agents`) or applying a manifest (`POST /api/apply`) answers
`403` `insufficient_scope`. The user creates the agents, from their own
machine or the Agents page; you write exactly what to create.

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
   repos. Check what the instance can run: `GET /api/catalog` (models per
   runtime). Ask the user which providers they hold a key for; never
   propose a provider they do not.
5. **Names?** Offer role names (`repo-maintainer`, `issue-triager`) or a
   themed set if they'd like; names must be unique per account.

## 2. Propose, then confirm

Show a table: name · brain · what they do (one line) · first thing you'd
send them. Ask "is this the team?" — adjust on feedback.

## 3. Hand over the manifest (after the yes)

Write the roster as one `fountain.yml`, an `Agent` and a `Teammate`
document per teammate, and give it to the user in a code block:

```yaml
---
apiVersion: fountain/v1
kind: Agent
metadata:
  name: <name>
spec:
  model: <provider/model>
  runtime: <claude|codex|gemini>
  description: <one line>
  system: >-
    You are <name>, a teammate on the user's team. Your role: <one line>.
    You have your own computer; do the work there and report back in chat —
    concise, concrete, no filler. <repo/scope specifics>
---
apiVersion: fountain/v1
kind: Teammate
metadata:
  name: <name>
spec:
  agent: <name>
```

Runtime follows the brain: `anthropic/*` → `claude`, `openai/*` → `codex`,
`google/*` → `gemini`. If a teammate needs an environment (a repo
mounted, a token, packages), say so and point at Fountain's Environments
page — do not invent secrets; the user supplies them. A recurring job
(triage, a daily report) is a `Schedule` document (`teammate`, five-field
`cron` in UTC, `prompt`).

Tell the user to save it and run `fountain apply -f fountain.yml` with their
own login, or to create the same agents on the Agents page and add them to
the team.

## 4. Confirm

When the user says it is done, read the team back
(`curl -s -H "Authorization: Bearer $FOUNTAIN_TOKEN" "$FOUNTAIN_BASE_URL/api/team"`).
Reply with the roster as created (name, presence), who to message for what,
and one concrete first message for each. Mention that teammates can reach
each other (`fountain-team` tools: list_teammates, get_teammate,
send_to_teammate, wait_for_teammate, read_teammate) and that everything — brain, role, name —
is editable later from the team app. If you created a lead/gateway, say
"send your asks to <lead> from now on."

## Rules

- One question at a time; stop asking as soon as you can propose.
- Never write the manifest before a confirmation; never delete or rename
  anything.
- Never paste tokens into prompts, descriptions, messages or the manifest.
- Names must be unique per account: check `GET /api/agents` and suffix a
  name already taken. If the user's apply reports a missing credential, say
  which provider needs a key and where (Account → Inference credentials).
