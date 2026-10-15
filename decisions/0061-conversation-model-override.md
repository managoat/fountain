---
type: ADR
title: "A conversation may run a different model from its agent"
description: "A conversation carries an optional model override, set at launch and fixed for its life."
tags: [conversations, api, inference]
status: stable
adr: "0061"
adr_status: "Accepted"
date: 2026-09-26
---

# 0061 — A conversation may run a different model from its agent

**Status:** Accepted, 2026-09-26, and built, except as listed under
Consequences.

## Context

The model belongs to the agent. A conversation reads `agent.model` on every
turn and sends it to the adapter as `session/set_model`, so the adapter could
already change model between two turns of one session. What stopped a caller
was Managoat itself:

- There was nowhere to say it: the launch request took per-conversation
  overrides for environment, vault and permission policy, but not the model.
- Editing the agent does not switch a running conversation; it stops it. The
  conversation's stored inference source records the model, and turn admission
  compares it with the agent's current model, so after an edit the next turn
  is refused with `inference_source_changed`. The edit also reaches every
  conversation on the agent, which is rarely what was wanted.
- [0015](0015-fountain-as-an-acp-agent.md) left the ACP gateway's
  `session/set_model` unimplemented for the same reason: a change through one
  session would change all of them.

So the only way to run a harder task on a stronger model, or a simple one on a
cheaper model, was to change it for every conversation on the agent.

## Decision

1. **A conversation has an optional `model`.** Null means the agent's model.
   The model a turn runs is `conversation.model || agent.model`. That one
   value is sent as `session/set_model`, used to resolve and validate the
   inference source, recorded on the turn's `model_selection`, and passed to
   the runtime module wherever it reads the agent's model. The override is
   applied where a conversation loads its agent, not chosen at each call site;
   `InferenceResolution` reads it itself so no caller can forget it.

2. **It is set at launch and fixed for the conversation's life.**
   `POST /api/conversations` accepts `model`. To run another model, start a new
   conversation.

3. **It is validated like an agent's model.** It must be in canonical
   `provider/model_id` form, and its provider must be one the conversation's
   runtime drives: the checks `Agent.changeset/2` applies, with the code
   shared. The model id is not checked against the catalog, so a model released
   since the last deploy works the day it ships. The `acp` runtime resolves no
   model, so an override there is refused (422 `model_invalid`), not stored and
   ignored.

4. **The credential is not selected by the override.** The inference source is
   resolved from the user's one credential record with the effective model. A
   model that record cannot serve is refused with 409
   `inference_source_changed`.

5. **It is not part of a channel's resume key.** A channel request that
   resumes a conversation and names a different `model` is refused with 409
   `conversation_model_differs`, and the prompt is not sent; the caller passes
   `fresh: true` to start a new conversation. Resuming silently on the old
   model would accept a request field and ignore it.

6. **Editing the agent's model still stops every conversation that follows
   it.** A conversation with no override follows the agent, and after an edit
   its next turn is refused with `inference_source_changed`; nothing in that
   conversation can clear it, and a new conversation runs the new model. A
   conversation with an override does not read the agent's model, so the edit
   does not affect it.

## Consequences

- The model a conversation runs is not read off its agent alone. Clients that
  display it read `conversation.model` first, or the turn's `model_selection`,
  which records what actually ran. `managoat acp` reports the conversation's
  own model on `session/load`.
- Every place that resolves inference for a conversation uses the effective
  model; otherwise an overridden conversation would read as
  `inference_source_changed` on its next wake.
- Not built: ACP `session/set_model`. The gateway answers method-not-found.
  acpx narrows the controls it sends to the config options a reply last
  advertised (0015, #760), and advertising the model as one needs its own
  decision.
- Not built: a console model picker.
- Not built and not planned: an agent-level allowlist of models, like
  `allowed_environment_ids`. The agent's owner is the conversation's owner, so
  it would guard nothing; agents are not shared.

## Alternatives considered

- **Implement ACP `session/set_model` against the agent.** What 0015 refused:
  one session's request would change every conversation on the agent.
- **Let an agent edit carry running conversations with it.** A different
  feature with a different blast radius: it changes conversations nobody asked
  to change, and the new model may need a credential other than the pinned one.
- **A per-prompt `model` field.** Finer than needed, and it would respawn the
  adapter on any prompt whose model differs from the last.
- **Change the override in place on a running conversation** (through reapply).
  Built at first, then removed with reapply itself, which prod had used three
  times in the 60 days before.

## History

- 2026-09-26 — Accepted and built: optional per-conversation `model`, set at launch or by reapply, with shared validation and the channel refusal.
- 2026-10-14 — Credential sets ([0053](0053-inference-credential-sets.md)) and the opencode runtime are removed; the credential rule holds for the user's one credential record.
- 2026-10-14 — The traction goal is withdrawn; the model allowlist stays unbuilt and is unplanned.
- 2026-10-14 — Reapply (#1565, #2215) is removed (#2676), so the override is fixed for the conversation's life and `conversation_model_differs` is answered with `fresh: true` only.
