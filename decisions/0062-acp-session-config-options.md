---
type: ADR
title: "ACP session config options are requested per agent"
description: "An agent carries session_config, adapter config option ids to values, copied to a conversation at launch and requested on every turn; conversations and prompts may not set it."
tags: [conversations, api, inference, acp]
status: stable
adr: "0062"
adr_status: "Accepted"
date: 2026-09-30
---

# 0062 — ACP session config options are requested per agent

**Status:** Accepted, 2026-09-30. Built. Not built: a category-based refusal
of permission-mode options, read-only turns, and SDK helpers (see
Consequences).

## Context

The ACP adapters Managoat pinned when this was decided expose more than the
model through `session/set_config_option`. Reasoning effort and fast mode are the options
clients ask for (#1572, #2537):

| Adapter | Effort | Fast |
|---|---|---|
| claude-agent-acp 0.81.2 | `effort`, category `thought_level` | `fast`, category `model_config` |
| codex-acp 1.10.0 | `reasoning_effort`, category `thought_level` | `fast-mode`, category `model_config` |

Before this, Managoat sent only `configId: "model"`, and a client that wanted
effort sent `/effort high` as a prompt turn. That costs a turn, shows in the
transcript, does not exist on codex, and cannot be checked after a resume.

Three facts shape the choice:

- **The options depend on the model.** Claude offers `effort` only on a
  model that supports it, with that model's values; codex's values come from
  the model's `supportedReasoningEfforts`, and fast exists only on models
  with a fast tier. A list in Managoat would be wrong the day an adapter or a
  model changes, which is `Agents.ModelCatalog`'s argument for model ids
  (#554, #970).
- **The adapter already checks.** Both answer an unknown value with an
  error, and both report the full option list, with each `currentValue`,
  after every change.
- **The session outlives the adapter process.** A conversation resumes in a
  new process after a sleep, and the adapter does not restore the options
  there. Managoat already pins the model again on every turn for this reason.

Both pinned adapters also list their permission mode among their config
options: claude's `mode` (`default`, `acceptEdits`, `plan`, `auto`,
`bypassPermissions`) and codex's `mode` (`read-only`, `agent`,
`agent-full-access`) and `collaboration_mode` (`default`, `plan`). Gemini
0.59.0 advertises no config options. A request for
`{"mode": "bypassPermissions"}` would stop the adapter from asking
permission at all, moving the turn out from under the conversation's
`permission_policy`, which a launch may narrow and never widen
([0016](0016-governance-as-an-acp-proxy.md)).

## Decision

1. **`session_config` belongs to the agent.** It is a map of the adapter's
   option id to a value, a string or a boolean, set on agent create and
   update and served on show. At launch it is copied onto the conversation
   as `conversations.agent_session_config` (`SessionConfig.for_launch/1`),
   and the `conversation.created` audit records it. An edit to the agent
   reaches new conversations only, as the model does
   ([0061](0061-conversation-model-override.md)). A conversation's
   `session_config` in API responses is that copy.

2. **Conversations and prompts may not set it.** `POST /api/conversations`,
   a channel resume (`fresh: true` or not) and
   `POST /api/conversations/{id}/prompts` answer a non-empty
   `session_config` with `422 session_config_agent_only`. `null` and `{}`
   are accepted, because existing clients send them. The request schemas
   keep the field, marked deprecated, so the 422 names the change rather
   than a schema error. A caller that named an option and silently got the
   agent's would think it had changed effort for that turn, so the field is
   refused, not ignored, as [0073](0073-one-sandbox-per-conversation.md)
   refused `sandbox_id`. A caller that wants different options makes
   another agent.

3. **Only the shape is checked.** `SessionConfig.check/1`: ids are 1 to 64
   characters from `[A-Za-z0-9._:-]`, values are 1 to 200 characters or a
   boolean, at most 16 options. `model` is refused, because 0061's field
   owns it. `mode` and `collaboration_mode` (`harness_mode_ids/0`) are
   refused with a message naming `permission_policy`. The agent's changeset
   reports a malformed map as a changeset error. Which other ids and values
   exist is left to the adapter.

4. **The request is fixed on the turn when it opens.**
   `SessionConfig.effective/1` is the conversation's `agent_session_config`
   less any harness mode id, so a row stored before the mode refusal never
   sends one (the dropped ids are logged). It is stored as
   `turn.config_selection["requested"]`, and both connection paths, a fresh
   spawn and a reused idle peer, send exactly that to `Managoat.ACP.Peer`
   as `:config`, `%{}` included. Wake, rehydration and provisioning read it
   from the opened turn.

5. **The peer applies it before every prompt**, after the model pin:
   - one option at a time, in the order the adapter lists them;
   - each checked against the list the model pin returned, so options that
     vary by model are handled;
   - an id the adapter does not advertise is skipped and reported, so moving
     to a model without effort does not fail every turn;
   - a value already current is not sent again;
   - a refusal fails the turn with the adapter's own message before any
     prompt is written, as `model_selection_failed` does (#724).

   An option the request does not name is left as the adapter has it.
   `:model_selected` is still the report sent immediately before the prompt,
   so a turn that failed on a config refusal does not look like one that
   spent tokens (#1685).

6. **What happened is recorded.** `turn.config_selection` records
   `requested`, `applied` (id to the value the adapter confirmed),
   `skipped`, and `status`/`error` on a refusal. Each option emits a
   `config` stage event: `done` with `outcome` `applied` or `skipped`, or
   `failed`. `conversation.session_config_options` holds the adapter's
   option list from before the latest prompt: what the current model offers
   and what is in force, less the harness mode options
   (`SessionConfig.offered/1`, applied both when the list is stored and when
   it is served). Clients render their pickers from it instead of
   hardcoding which models support which settings.

7. **The peer declares `session.configOptions.boolean`,** so both adapters
   advertise fast mode as a real boolean. The peer translates
   `true`/`false` to `on`/`off`, and back, for an adapter that has only the
   select.

8. **`managoat acp` does not forward options.** It acknowledges
   `session/set_config_option` and applies nothing
   ([0015](0015-fountain-as-an-acp-agent.md)).

## Consequences

- Clients set effort and fast mode on an agent for both runtimes, read what
  the current model offers, and see what was applied on each turn.
- "What config did this run use?" has one answer: the conversation's copy,
  recorded on each turn.
- A turn can fail on a value its model does not accept; the message names
  the option and the adapter's reason, and `session_config_options` lists
  the values that would have worked.
- Each turn costs one `set_config_option` round trip per option whose value
  changes; options already in force cost nothing, the common case on an open
  connection.
- Fast mode costs the deployment whatever the provider charges for it;
  Managoat prices nothing.
- The mode refusal is by id, from the pinned adapters' lists, and must be
  revisited when a pin moves. A category-based refusal of any option listed
  under category `mode` belongs in `Managoat.ACP.Peer`, the one component
  that sees categories before it sends. Not built. The live adapter suite
  (`apps/fountain/test/live/adapter_behaviour_live_test.exs`) checks on a
  pin bump that the only mode ids are the ones `harness_mode_ids/0` names
  and that an option requested on every turn holds
  (`contributing/component-libraries.md`).
- Read-only turns do not travel through this mechanism. A harness mode does
  not enforce read-only, as measured for [0067](0067-read-only-turns.md),
  which was rejected.
- The field is in the OpenAPI contract and the generated TypeScript types;
  the SDK's hand-written layer has no dedicated argument for it. The console
  has no agent form, so it offers no picker
  ([0076](0076-console-without-configuration-pages.md)).

## Alternatives considered

- **Typed `effort` and `fast` fields.** Clearer for two options, but each
  adapter names them differently, their values move per model, and the next
  option would need another migration. The adapter's own ids and categories
  are the stable contract.
- **Validate against the options the adapter last advertised.** The list is
  per model and per session, and the adapter checks at the moment of change
  anyway; a stale list would refuse values that would work.
- **Refuse a requested id the adapter does not advertise.** That would fail
  every turn after a move to a model without effort.
- **Read the live agent on every turn.** An agent edit would then change the
  next turn of every running conversation with no audit on the
  conversation, while a model edit does not (#2664).
- **Three layers: agent, conversation at launch, prompt for one turn.**
  Built first and removed. It made a run's config a merge of three sources,
  needed a per-turn restore to keep a prompt's option to its turn, a gateway
  that resent options on every prompt to defeat that restore, and a resume
  rule for a differing request. Production had no conversation or prompt
  that set `session_config`. An agent is cheap to make, and a conversation
  already takes its model from the agent at launch.

## History

- 2026-09-30 — Decided and built: `session_config` on the agent, the conversation (launch and reapply) and the prompt (one turn); peer apply loop in managoat_acp 0.5.0 (#2539).
- 2026-10-14 — Credits removed (#2609), so fast mode is not priced; #2538 closed.
- 2026-10-14 — `mode` and `collaboration_mode` refused as session options; stored ones dropped at turn open (#2675).
- 2026-10-14 — Swift SDK types gone with `sdk/swift` ([0041](0041-typed-swift-client.md), [0059](0059-independent-sdk-maintenance.md)).
- 2026-10-14 — Reapply removed (#2676); a conversation's `session_config` fixed at launch.
- 2026-10-14 — A prompt's option no longer leaked past its turn: managoat_acp 0.6.0 restored the prior value (#2691); mode ids dropped from `session_config_options`.
- 2026-10-15 — The restore measured on both pinned adapters by the live suite (#2670).
- 2026-10-15 — `managoat acp` forwarded `session/set_config_option` as each prompt's `session_config` (#2663).
- 2026-10-15 — The agent's options copied onto the conversation at launch, `agent_session_config` (#2664).
- 2026-10-15 — Session options made the agent's alone: conversation and prompt `session_config` refused with 422, the restore and the gateway forwarding removed, the API serves the copy; `conversations.session_config` folded in and dropped a release later.
- 2026-10-17 — Context marked as describing the adapter pins of 2026-09-30; codex-acp is pinned at 2.2.2 now and its option list was not re-read for this edit.
