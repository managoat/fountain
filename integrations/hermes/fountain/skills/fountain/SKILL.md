---
name: fountain
description: Delegate work to Fountain agents — sandboxed coding agents (claude/codex/gemini) that each run in their own per-conversation sandbox on a Fountain instance. Use when the user asks to spin up an agent on Fountain, hand a task to a named agent, fan a task out across several agents, or continue a Fountain conversation. The fountain_* tools are the interface; this skill is the operating model.
---

# Fountain from Hermes

You have `fountain_*` tools. Each call talks to a Fountain instance on the
user's behalf; the work runs **there**, in a sandbox Fountain provisions, not
on this machine.

## Mental model

| Primitive | What it is |
|---|---|
| **Agent** | a named runtime config: runtime (claude/codex/gemini), model, system prompt, an environment (packages, repos, secrets, network policy), optional skills and MCP servers |
| **Conversation** | one running instance of an agent in a fresh sandbox; multi-turn; the sandbox keeps state between turns until it is terminated or reclaimed |
| **Turn** | one prompt and everything the agent did in response |
| **Vault** | a bag of secret overrides picked per conversation (wins over the environment on key collision) |

The user chooses *which* agent by name; you do not configure agents from here.

## Workflow

1. `fountain_agents` — once per session, or when the user names an agent you
   have not seen. Match by name; pass the name (or id) to `fountain_run`.
2. `fountain_run(agent, prompt)` — write the prompt as if briefing a contractor
   with **no other context**: the goal, the repo/paths if the environment
   clones one, what "done" looks like, and what to report back. It provisions
   a sandbox (typically 30–90 s) and waits for the answer.
3. Read `output`. If `done` is `false`, the turn is still running: call
   `fountain_wait(conversation_id)` — repeat until `done`. Do not re-run the
   task.
4. Follow-ups go to the **same** conversation with `fountain_send` — the agent
   remembers the earlier turns and the sandbox still has its files.
5. When the delegated work is finished and no follow-up is expected,
   `fountain_terminate`. Idle conversations are reclaimed anyway; terminating
   just frees the sandbox sooner.

### Fan-out

Start each with `wait: false`, then `fountain_wait` each conversation id in
turn:

```
fountain_run(agent="reviewer", prompt="Audit auth/ …", wait=false)  → conv A
fountain_run(agent="reviewer", prompt="Audit billing/ …", wait=false) → conv B
fountain_wait(A); fountain_wait(B)
```

### Long turns

Every blocking call returns after `timeout_seconds` (default 300) with
`done=false` and the output so far. Keep waiting with `fountain_wait`; the
cursor is remembered, so you only see new text. Never assume a turn failed
because a wait returned — check `done` / `turn_state`.

## Reporting back

Relay the agent's `output` faithfully — it is the deliverable — and include
the conversation `url` so the user can open the transcript in Fountain. Say
which agent ran and whether the turn finished (`turn_state: done`), failed
(`failed`, with `reason`) or was interrupted.

## Errors you may see

- `No agent named …` — list agents; the user probably meant a different name.
- `HTTP 401` — the API key is wrong or missing (`FOUNTAIN_API_KEY`, or
  `fountain auth login`).
- `HTTP 402` — the account has no active subscription on that instance.
- `HTTP 404` on a conversation — wrong id, or it belongs to another account.
- `conversation_busy` — a turn is already running; `fountain_wait` first.
