# create-team

> A five-question conversation that proposes a roster of teammates and hands
> it to you as a manifest to apply.

## Summary

| | |
|---|---|
| Bundled | Yes, in each sandbox. |
| Declared by | Nobody. It is always there. |
| Source | `apps/fountain/priv/sprite_skills/create-team/SKILL.md` |
| Triggered by | `/create-team`, or a request to a teammate for help with a team. |

## What happens when you run it

Say `/create-team` to any teammate. Or ask it what the team must look like.

**It asks at most five questions**, one at a time. It offers a default with
each one, so "yes" is a complete answer.

1. The work the team must get done.
2. The repos or services in scope, and which of them need a token.
3. How many teammates. Two to five is usual. Past three, a lead earns its
   place.
4. Any brain preference. It reads `GET /api/catalog` for the models, and asks
   which providers you hold a key for. It proposes nothing you cannot run.
5. The names. Role names such as `repo-maintainer`, or a themed set.

**Then it proposes.** You get a table of name, brain, a one-line role, and the
first thing it would send each teammate.

**It writes nothing before you say yes.**

**Then it hands you a manifest.** You get a `fountain.yml` with an `Agent`
and a `Teammate` document for each teammate. Apply it with
`fountain apply -f fountain.yml`, or create the same agents on the Agents
page. When you say it is done, it reads the team back. You get the roster,
and who to message for what. You also get one concrete first message for
each teammate, and a note that teammates can reach each other.

## What it creates

Nothing itself. The token a sandbox holds cannot create an agent or apply a
manifest, so that a prompt-injected agent cannot change what your next
launch runs. Read
[What a sandbox credential can do](../../api.md#what-a-sandbox-credential-can-do).

The manifest it writes creates an [Agent](../../concepts/agent.md) and a
[team membership](../../concepts/teammates.md) for each teammate. The
membership opens that agent's one conversation and provisions its sandbox.

When the team has a job that repeats, such as triage or a daily report, the
manifest can also hold a [schedule](../../api.md#schedules) for a teammate.
That is a cron line and a prompt, and the teammate runs it on its own.

You can edit everything it sets afterwards, from the team app or with the
[Team](../../api.md#team) routes. Brain, role and name are not decisions you
are stuck with.

## Its own rules

The skill holds itself to four rules. They are the difference between a
helpful flow and a destructive one.

- Ask one question at a time. Stop as soon as a proposal is possible.
- Never write the manifest before a confirmation. Never delete a thing, and
  never rename a thing.
- Never paste a token into a prompt, a description, a message or the
  manifest.
- Check the names against your agents and add a suffix to a name already
  taken. On an absent credential, name the provider and say where to add the
  key.

## Limits

**It only adds.** It will not remove a teammate, rename one, or reorganise a
team that already exists. The team app does those, and so do
`DELETE /api/team/:agent_id` and `PATCH /api/team/:agent_id`. Read
[Team](../../api.md#team).

**It needs your inference credentials in place first.** A sandbox cannot
read them, so it asks you which providers you hold a key for. Read
[Inference credentials](../../api.md#inference-credentials).

**Each teammate you apply provisions a sandbox.** A roster of five is five
machines. Read
[Change sandbox lifetimes](../../guides/operate/sandbox-lifetime.md).

## Related

- [Agents as teammates](../../concepts/teammates.md), what it builds.
- [Team](../../api.md#team), the routes it reads.
- [About agents](../../concepts/agent.md).
- [Skills](index.md).
