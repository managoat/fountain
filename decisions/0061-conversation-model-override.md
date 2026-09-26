---
type: ADR
title: "A conversation may run a different model from its agent"
description: "A conversation carries an optional model override, set at launch or by reapply and applied from the next turn; ACP session/set_model stays unbuilt."
tags: [conversations, api, inference]
status: stable
adr: "0061"
adr_status: "Accepted"
date: 2026-09-26
---

# 0061 — A conversation may run a different model from its agent

## Context

The model has belonged to the agent since the start.
A conversation reads `agent.model` again on every turn and sends it to the
adapter as `session/set_model`, so the adapter can already change model between
two turns of one session. What stops a caller changing it is Fountain itself:

- There is nowhere to say it. The launch request takes an environment, a vault,
  a credential set and a permission policy as per-conversation overrides, but no
  model. The reapply endpoint (#1565) re-selects the agent, environment and
  vault in place, but not the model.
- Editing the agent does not switch a running conversation. It stops it. The
  resolved inference source stored on the conversation records the model
  ([ADR 0053](0053-inference-credential-sets.md)), and turn admission compares
  that source with the agent's current model. After an edit, the next turn is
  refused with `inference_source_changed` until the conversation is reapplied.
  The edit also reaches every conversation on the agent, which is rarely what
  was wanted when one conversation needed another model.
- [ADR 0015](0015-fountain-as-an-acp-agent.md) left the ACP gateway's
  `session/set_model` unimplemented for the same reason: the agent's model is
  authoritative, so a change through one session would change all of them.

So the only way to try a harder turn on a stronger model, or to finish on a
cheaper one, is to change the model for every conversation on the agent, or to
start a new conversation and lose the transcript and the runtime session.

## Decision

1. **A conversation has an optional `model`.** Null means the agent's model.
   A value overrides it for this conversation only. The model a turn runs is
   `conversation.model || agent.model`. That is the one value sent as
   `session/set_model`, used to resolve and revalidate the inference source,
   recorded on the turn's `model_selection`, and passed to the runtime module
   wherever it reads the agent's model. The runtime path applies the override
   where a conversation loads its agent. Individual call sites do not each
   choose between the two.

2. **It is set at launch or by reapply.** `POST /api/conversations` accepts
   `model`. `POST /api/conversations/{id}/reapply` accepts `model` alongside
   `agent_id`, `environment_id` and `vault_id`, with the same rules: omitted
   keeps the current override, an explicit null clears it back to the agent's
   model, and a string sets it. Reapply already refuses while a turn runs, bumps
   `configuration_revision`, audits `conversation.configuration_reapplied` with
   the previous and current values, and respawns the adapter for the next turn.
   A model change needs all of that, because some models carry process
   environment of their own (`Managoat.Runtimes.model_env/2`). The machine, its
   disk and the runtime session id are kept, so the next turn resumes the same
   session on the new model.

3. **It is validated like an agent's model.** The value must be in canonical
   `provider/model_id` form, and its provider must be one the conversation's
   runtime drives. These are the checks `Agent.changeset/2` applies, and the
   code is shared, not copied. The model id itself is not checked against the
   catalog, for the reason the agent does not check it: a model released since
   the last deploy has to work the day it ships. The `acp` runtime resolves no
   model, so an override there is refused (422 `model_invalid`), not stored and
   ignored. A reapply that also moves the agent validates the override against
   that agent's runtime.

4. **The credential stays pinned.** The override does not select a credential.
   A reapply revalidates the stored inference source with the new model merged
   in, as it already does for a new agent. A model that the same credential
   serves applies in place. A model that needs a different credential, such as
   an `opencode` conversation moving from an `anthropic/` model to an `openai/`
   one, is refused with 409 `inference_source_changed`, and nothing changes. The
   platform inference gate is applied to the revalidated source as before.

5. **It is not part of any identity.** A sandbox's binding identity stays
   `(user, agent, environment, vault)`. Two conversations on one machine may run
   different models, because the model is a per-turn argument and a per-spawn
   environment, not a disk. A channel's resume key does not include the model
   either. A channel request that resumes a conversation and names a different
   `model` is refused with 409 `conversation_model_differs`, and the prompt is
   not sent. The caller reapplies the model or passes `fresh: true`. Resuming
   silently on the old model would store a request field and ignore it.

6. **Editing the agent's model still stops every conversation that follows
   it.** A conversation with no override follows the agent. After an edit its
   next turn is refused with `inference_source_changed` until a reapply, as
   today. A conversation with an override does not read the agent's model, so
   an edit does not affect it. The supported way to change one conversation's
   model is decision 2. Changing that behaviour for conversations that follow
   the agent is outside this decision.

## Implementation status

Decisions 1 to 5 are built in the change that adds this ADR: the column, the
two request fields, the shared validation, resolution and revalidation on the
effective model, the channel refusal, and the `model` field on the conversation
response. `fountain acp` reports the conversation's own model on
`session/load`.

Not built:

- **ACP `session/set_model`.** The gateway still answers method-not-found.
  Mapping it onto a reapply of the session's conversation is now possible. It
  stays unbuilt because acpx narrows the controls it sends to the config
  options a reply last advertised (ADR 0015, #760), and advertising the model
  as one needs its own decision.
- **The console.** Neither the launch form nor the conversation page offers a
  model picker. Reapply has no console surface for any of its fields.
- **An agent-level allowlist of models.** An agent cannot limit which models its
  conversations may choose, as `allowed_environment_ids` limits environments.
  The agent's owner is also the conversation's owner, so the limit would guard
  nothing until agents are shared, which is out of scope until the traction goal
  in CLAUDE.md is met.

## Consequences

- A long conversation can move up or down a model without losing its
  transcript, its machine or its runtime session.
- The model a conversation runs is no longer read off its agent alone. Clients
  that display it read `conversation.model` first, or the turn's
  `model_selection`, which has always recorded what actually ran.
- One more override takes part in inference resolution. Every place that
  resolves or revalidates for a conversation has to use the effective model.
  Otherwise an overridden conversation reads as `inference_source_changed` on
  its next wake. `InferenceResolution` reads the override itself so that its
  callers cannot forget it.

## Alternatives considered

- **Implement ACP `session/set_model` against the agent.** This is what ADR 0015
  refused: one session's request would change every conversation on the agent.
- **Let an agent edit carry running conversations with it.** This would fix
  decision 6's refusal, but it is a different feature with a different blast
  radius. It changes conversations nobody asked to change, and a credential the
  new model needs may not be the pinned one.
- **A per-prompt `model` field.** This is finer than needed, and it would bypass
  reapply's revision fence and audit. It would also respawn the adapter on any
  prompt whose model differs from the last one.
