---
type: ADR
title: "ACP session config options are requested per agent, conversation and turn"
description: "Agents, conversations and prompts carry session_config, a map of the adapter's config option ids to values that is applied after the model and before every prompt; only the shape is checked, and pricing the options is unbuilt."
tags: [conversations, api, inference, acp]
status: stable
adr: "0062"
adr_status: "Accepted"
date: 2026-09-30
---

# 0062 — ACP session config options are requested per agent, conversation and turn

## Context

The two ACP adapters Fountain pins expose more than the model through
`session/set_config_option`. Reasoning effort and fast mode are the options
clients ask for (#1572, #2537):

| Adapter | Effort | Fast |
|---|---|---|
| claude-agent-acp 0.81.2 | `effort`, category `thought_level` | `fast`, category `model_config` |
| codex-acp 1.10.0 | `reasoning_effort`, category `thought_level` | `fast-mode`, category `model_config` |

Until now Fountain sent only `configId: "model"`. A client that wanted effort
had to send `/effort high` as a prompt turn. That costs a turn, shows up in
the transcript, doesn't exist on codex, and can't be checked after a resume.

Three facts shape the choice:

- **The options depend on the model.** Claude offers `effort` only on a model
  that supports it, and its values are that model's own. Codex's values come
  from the model's `supportedReasoningEfforts`, and fast exists only on
  models with a fast tier. A list in Fountain would be wrong the day an
  adapter or a model changes, which is `Agents.ModelCatalog`'s argument for
  model ids (#554, #970).
- **The adapter already checks.** Both answer an unknown value with an error,
  and both report the full option list, with each `currentValue`, after
  every change.
- **The session outlives the adapter process.** A conversation resumes in a
  new process after a sleep, and the adapter does not restore the options
  there. Fountain already pins the model again on every turn for this
  reason.

[ADR 0061](0061-conversation-model-override.md) set the precedent for a
per-conversation override of what an agent runs. It rejected a per-prompt
`model` that persists, because that would bypass reapply's revision fence and
audit, and because it respawns the adapter.

## Decision

1. **`session_config` on the agent, the conversation and the prompt.** Each
   is a map of the adapter's option id to a value, a string or a boolean.
   - The agent's applies to every conversation of the agent.
   - The conversation's overrides the agent's key by key. It is set at launch
     (`POST /api/conversations`) or by reapply, with 0061's rules: omitted
     keeps it, `null` clears it, and a map replaces it. It is audited and
     bumps `configuration_revision`.
   - A prompt's (`POST /api/conversations/{id}/prompts`) overrides both, for
     **that turn only**. It is not written to the conversation, so it bypasses
     no fence and no audit. It needs no respawn either, because an option is
     a `set_config_option` call on the open session, not process
     environment.
   - A channel resume that names a different `session_config` is refused with
     409 `conversation_session_config_differs`, as a differing model is.

2. **Only the shape is checked.**
   - Ids are 1 to 64 characters from `[A-Za-z0-9._:-]`, values are 1 to 200
     characters or a boolean, and there are at most 16 options.
   - `model` is refused, because 0061's field owns it.
   - A malformed map is 422 `session_config_invalid`.
   - Which ids and values exist is left to the adapter.

3. **The effective request is fixed on the turn when it opens.** It is the
   agent's config, then the conversation's, then the prompt's, and it is
   stored as `turn.config_selection["requested"]`. Both connection paths send
   exactly that to `Managoat.ACP.Peer` as `:config`: a fresh spawn and a
   reused idle peer, which always receives the full map, `%{}` included.

4. **The peer applies it before every prompt**, after the model
   (`managoat_acp` 0.5.0):
   - one option at a time, in the order the adapter lists them;
   - each one checked against the list the model pin returned, so options
     that vary by model are handled;
   - an id the adapter does not advertise is skipped and reported;
   - a value already current is not sent again;
   - a refusal fails the turn with the adapter's own message before any
     prompt is written, as `model_selection_failed` does (#724).

   `:model_selected` is still the report sent immediately before the prompt,
   so a turn that failed on a config refusal does not look like one that
   spent tokens (#1685).

5. **What happened is recorded.**
   - `turn.config_selection` records `applied` (id → the value the adapter
     confirmed), `skipped`, and `status`/`error` on a refusal.
   - Each option emits a `config` stage event: `done` with an `outcome` of
     `applied` or `skipped`, or `failed`.
   - `conversation.session_config_options` holds the adapter's option list
     from before the latest prompt: what the current model offers and what
     is in force. Clients render their pickers from it instead of
     hardcoding which models support which settings.

6. **The peer declares `session.configOptions.boolean`.** Both adapters then
   advertise fast mode as a real boolean. In the pinned versions it changes
   nothing else. The peer also translates `true`/`false` to `on`/`off`, and
   back, for an adapter that has only the select.

7. **The same mechanism is meant for read-only turns (#2533).** Both
   adapters expose a mode option (claude's `mode`, codex's `mode` and
   `collaboration_mode`), so a per-turn read-only switch can travel through
   a prompt's `session_config`. Whether that is enough to enforce read-only
   is #2533's decision. Measured: it is not. [ADR 0064](0064-read-only-turns.md)
   proposes the enforcement.

## Implementation status

Decisions 1 to 6 are built in the change that adds this ADR:

- the three fields and the turn's `config_selection`;
- validation, the channel refusal and the audit;
- `PromptDelivery` carrying a prompt's options down both prompt roads;
- the peer's apply loop (managoat_acp 0.5.0);
- the TurnMachine reports;
- the conversation's `session_config_options`.

`managoat_runtimes` 0.5.5 accepts managoat_acp 0.5.

Not built:

- **Pricing.** Fast mode runs at a higher rate on the providers that offer
  it, and `Credits.InferenceRates` prices a platform-key turn by model and
  tokens alone. #2538 prices it from the applied values recorded here. Until
  then, a platform-key turn with fast on is charged at the standard rate.
- **Read-only turns** (decision 7).
- **The console.** Neither the agent form nor the conversation page offers
  the options.
- **ACP gateway.** `fountain acp` does not advertise or forward
  `session/set_config_option`.
- **SDK helpers.** The field is in the OpenAPI contract and the generated
  TypeScript and Swift types, and map clients forward it. No SDK has a
  dedicated argument for it.

## Consequences

- Clients can set effort and fast mode on both runtimes without prompt-turn
  workarounds. They can read what the current model offers and see what was
  applied to each turn.
- A turn can fail on a value its model does not accept. The message names
  the option and the adapter's reason. The conversation's
  `session_config_options` lists the values that would have worked.
- A requested option the current model does not offer is kept and skipped,
  not refused, so moving between models does not need a reapply to clear it.
- Every turn that requests options adds one `set_config_option` round trip
  per option whose value changes. Options already in force cost nothing,
  which is the common case on an open connection.
- Mid-rollout, a server on the previous release ignores a prompt's
  `session_config`, and that turn runs on the conversation's options
  (`PromptDelivery`).

## Alternatives considered

- **A typed `effort` and `fast` field.** Clearer for two options. But each
  adapter names them differently, their values move per model, and the next
  option would need another migration. The adapter's own ids and categories
  are the stable contract.
- **A prompt's options become the conversation's default.** This was #2537's
  first proposal. It writes the conversation outside reapply's fence and
  audit, which 0061 refused for the model. Sending the options on every
  prompt costs a client nothing.
- **Validate against the options the adapter last advertised.** The list is
  per model and per session, and the adapter checks at the moment of the
  change anyway. A stale list would refuse values that would work.
- **Refuse a requested id the adapter does not advertise.** That would fail
  every turn after a move to a model without effort, until the conversation
  was reapplied.
