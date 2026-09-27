# fountain

> Lets an agent start more Fountain conversations from inside its own sandbox,
> and stream them.

## Summary

| | |
|---|---|
| Bundled | Yes, in each sandbox. |
| Declared by | Nobody. Fountain always adds it. |
| Source | `apps/fountain/priv/sprite_skills/fountain/SKILL.md` |
| Reads | `FOUNTAIN_BASE_URL`, `FOUNTAIN_TOKEN`, `FOUNTAIN_CONVERSATION_ID`, `FOUNTAIN_SANDBOX_ID` |

## What it gives the agent

Fountain's own API, from the inside. An agent that has it can fan work out
across other agents, then collect the answers.

The skill writes two patterns out. It can fan out N conversations in parallel
and gather their results. It can also drive one sub-conversation over several
turns.

That is what makes "delegate to another agent" work when a user asks for it.

## The credential it uses

`FOUNTAIN_TOKEN` is a **key for one conversation, scoped to that
conversation's owner**. It is not a long-lived admin token.

Fountain rotates it at each fresh provision and at each reattach, such as
after a deploy or a BEAM restart, and revokes the previous value. A request
that returns 401 with `"reason": "api_key_revoked"` means the agent cached a
stale copy. The agent must read the variable from its environment again.

## Provenance comes for free

`FOUNTAIN_CONVERSATION_ID` is always in the sandbox's environment. Send
`X-Fountain-Parent-Conversation-Id: $FOUNTAIN_CONVERSATION_ID` on a
`POST /api/conversations`, and Fountain records the parent. An operator can
then rebuild the whole spawn chain.

## A child on the same machine

`FOUNTAIN_SANDBOX_ID` is the id of the sandbox the agent runs on. Send it as
`sandbox_id` on a `POST /api/conversations`. The child conversation then runs
on that same machine, with the same disk, at the same time. That only works
for a child of the agent the machine belongs to, with the same environment and
vault. When the sandbox is a guest on another agent's machine, that is the
other agent, not its own. A child of any other agent, such as a codex agent
beside a claude one, needs a full-scope key, and
the sandbox's own token isn't one: the skill tells the agent to ask you to
attach it, or to give the child a machine of its own. See
[a second agent on a machine](../../concepts/sandboxes.md#a-second-agent-on-a-machine).

Without it, each child gets a sandbox of its own. When the agent runs in
persistent mode, the child gets that machine instead. To name the other mode
for one child, send `sandbox_mode` on the same call. See
[Sandboxes](../../concepts/sandboxes.md).

`GET /api/sandboxes` lists the machines the token's owner has, with the
conversations on each. Read [Sandboxes](../../api.md#sandboxes) and
[Conversations](../../api.md#conversations) for the fields.

## Limits

**A spawned agent has the same skill.** Nothing stops recursion, so the skill
tells the agent to cap the depth itself with a `MAX_DEPTH` check. A runaway
fan-out is a real way to spend money.

**Each conversation is a real sandbox.** The skill says plainly that an
orphaned conversation runs until the idle timeout, and that the agent must
terminate it without delay. Read
[Change sandbox lifetimes](../../guides/operate/sandbox-lifetime.md).

**The bare `/conversations` path returns 404.** The API is under `/api`.

## Related

- [API reference](../../api.md), the same surface from outside.
- [Skills](index.md).
- [About conversations](../../concepts/conversation.md).
