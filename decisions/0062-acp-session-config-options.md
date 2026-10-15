---
type: ADR
title: "ACP session config options are requested per agent, conversation and turn"
description: "Agents, conversations and prompts carry session_config, a map of the adapter's config option ids to values that is applied after the model and before every prompt; only the shape is checked. Nothing prices the options: credits, which would have, were removed on 2026-10-12. Amended 2026-10-14: the harness permission mode ids (`mode`, `collaboration_mode`) are refused, and a prompt's option is recorded as outliving its turn on a live adapter. Amended 2026-10-14 (#2676): reapply is removed, so a conversation's session_config is set at launch only. Amended 2026-10-14 (managoat_acp 0.6.0): a prompt-only option is put back on the next turn, and the mode ids are no longer listed in session_config_options. Amended 2026-10-15 (#2663): `fountain acp` forwards `session/set_config_option` as each following prompt's session_config. Amended 2026-10-15 (#2670): the restore and the hidden mode ids measured on the pinned claude and codex adapters. Amended 2026-10-15 (#2664): a conversation copies its agent's session_config at launch, so an agent edit reaches new conversations only. Amended 2026-10-15 (#2739): the conversation's and the prompt's session_config are removed and refused with 422 `session_config_agent_only`; every turn requests the agent's copy from launch, the peer's per-turn restore is removed, and `fountain acp` acknowledges `session/set_config_option` without applying it again."
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
   is #2533's decision. Measured: it is not. [ADR 0067](0067-read-only-turns.md)
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

## Addendum — 2026-10-14: there is nothing to price

The "Not built: Pricing" item under Implementation status is no longer
pending. Credits were removed on 2026-10-12 (#2609), and
`Credits.InferenceRates` with them, so no turn is charged at any rate. #2538
was closed as not planned on 2026-10-13. A platform-key turn with fast mode on
costs the deployment whatever the provider charges for it.

## Addendum — 2026-10-14: the permission mode is refused, and "that turn only" leaks

**The permission mode is not a session option.** Decision 2 left every id but
`model` to the adapter. Both pinned adapters list their permission mode among
their config options. claude-agent-acp 0.81.2 has `mode`, category `mode`,
with `default`, `acceptEdits`, `plan`, `auto` and `bypassPermissions`.
codex-acp 1.10.0 has `mode`, category `mode` ("approval and sandboxing
preset"), with `read-only`, `agent` and `agent-full-access`, and
`collaboration_mode`, with `default` and `plan`. Gemini 0.59.0 advertises no
config options. A request for `{"mode": "bypassPermissions"}` on the agent,
the conversation or a single prompt therefore stopped the adapter from asking
permission at all. That moved the turn out from under the conversation's
`permission_policy`, which a launch may narrow and never widen
([0016](0016-governance-as-an-acp-proxy.md)). Decision 7 had named the ids for
read-only turns, and [0067](0067-read-only-turns.md) measured that harness
modes do not enforce read-only either.

- `Agents.SessionConfig.check/1` now refuses `mode` and `collaboration_mode`
  like `model`: `422 session_config_invalid`, with a message that names
  `permission_policy`. The check covers each door: the agent changeset,
  launch, a channel resume, reapply and the prompt.
- A row written between this ADR and the addendum may still hold one. These
  rows are not migrated. `SessionConfig.effective/3`, and the request an
  already-open turn carries, drop the ids and log their names. A reapply that
  omits `session_config` keeps the stored map without them. So such a row
  never fails a turn and is never sent.
- The refusal is by id, from the pinned adapters' lists. It must be revisited
  when an adapter pin moves. A category-based refusal, of any option the
  adapter lists under category `mode`, belongs in `Managoat.ACP.Peer`, which
  is the only component that sees the categories before it sends. It is not
  built.

**A prompt's option outlives its turn on a live adapter.** Decision 1 says a
prompt's options apply for that turn only. The peer (managoat_acp 0.5.0)
replaces its requested map on every turn and applies only what the map names.
An id that the prompt named, and that the agent and the conversation do not,
is not reset on the next turn. A reused idle peer keeps the value the prompt
set, until the adapter process ends. After a sleep, a deploy or a respawn, the
adapter starts again from its own default. Fountain alone cannot fix this
cleanly. ACP reports each option's `currentValue` and no default, and only the
peer sees the value in force before the prompt changed it. The fix belongs in
the peer: it should record an option's value before the first change it makes
in a session, and on a later turn whose request omits that id, set it back.
Until then, the manual says to name the option on the conversation or the
agent when every turn should get the same value.

## Addendum — 2026-10-14: no Swift types

The "SDK helpers" item under Implementation status mentions generated Swift
types. There are none: `sdk/swift` was removed on 2026-10-12, when
TypeScript became the one maintained SDK
([0041](0041-typed-swift-client.md), [0059](0059-independent-sdk-maintenance.md)).
The field is in the OpenAPI contract and the generated TypeScript types, and
the TypeScript SDK still has no dedicated argument for it.

## Addendum — 2026-10-14: reapply is removed

Reapply is removed (#2676), so a conversation's `session_config` is set at
launch and cannot change after it. The three layers stay: the agent's, the
conversation's from launch, and the prompt's for one turn. A prompt's
`session_config` is how a caller changes the options of a conversation that
exists. The `conversation_session_config_differs` answer to a channel resume
now offers a prompt's `session_config` or `fresh: true`.

The places above that name reapply describe what was built before this
addendum: the `model` refusal's reason (reapply's revision fence), the second
layer's "or by reapply", and the permission-mode addendum's "a reapply that
omits `session_config` keeps the stored map without them". A stored map that
holds a harness mode id is still dropped by `SessionConfig.effective/3` when a
turn opens.

## Addendum — 2026-10-14: a prompt's option holds for its turn, and mode ids are not offered

The "that turn only" leak recorded above is fixed in the peer, as that
addendum proposed. managoat_acp 0.6.0 records, per option id, the value the
adapter reported just before the session's first change to it. A later turn
whose request does not name the id puts it back through
`session/set_config_option`; the "already in force" check still spares the
round trip. A restore is skipped when the adapter no longer offers the option
or the value, and a refused restore is logged rather than failing a turn
that asked for nothing. A new, resumed or loaded session starts with no
recorded values. The peer reports a restore as `{:config_restored, id,
confirmed}`; Fountain records it on the turn as `config_selection["restored"]`
and emits a `config` stage event with outcome `restored`. The manual no
longer tells callers to name an option on the conversation or the agent to
work around the leak.

`session_config_options` no longer lists the harness mode options:
`SessionConfig.offered/1` drops `harness_mode_ids/0` (the list `check/1`
refuses) when the turn machine stores the adapter's list and again when the
API serves a conversation, so a row stored before this addendum is not
served with them either.

## Addendum — 2026-10-15: the restore, measured on the real adapters (#2670)

The live adapter suite (`apps/fountain/test/live/adapter_behaviour_live_test.exs`)
ran the restore against the pinned adapters on 2026-10-15. Both took it. On
claude-agent-acp 0.81.2, `effort` went from `default` to `low` for one turn.
The next turn's request did not name it, so the peer reported
`{:config_restored, "effort", "default"}`, the option read `default` again,
and a third turn sent no restore. On codex-acp 1.10.0, `reasoning_effort` did
the same, from `low` to `medium` and back to `low`. A session resumed on a
new connection after a raised turn came back at the adapter's default on both
adapters, so the restore needs no baseline across connections. On both, the
only harness mode ids listed were the ones `harness_mode_ids/0` names: `mode`
on claude, and `mode` and `collaboration_mode` on codex. `offered/1` dropped
them. A pin bump re-runs these checks
(`contributing/component-libraries.md`).

## Addendum — 2026-10-15: `fountain acp` forwards `session/set_config_option`

The "Not built: ACP gateway" item under Implementation status is built
(#2663). `fountain acp` keeps, per session and in its own process, each option
an editor sets over `session/set_config_option`, and sends the set as the
`session_config` of every following `session/prompt` until the editor changes
one. Decision 3's "that turn only" is why the options ride on every prompt:
sent once, the 0.6.0 restore above would put them back on the next turn. The
agent and the conversation are never edited.

The gateway checks the shape `check/1` checks, so a bad option is an error on
the control the editor touched rather than a refused prompt on every turn
after it. `mode` and `collaboration_mode` are refused with the reason, and
dropped from the `config_option_update` notifications the gateway forwards.
`model` is accepted and not applied, with `_meta.fountain.applied: false`:
OpenClaw's acpx pushes a model at every spawn and aborts the turn on an error
(#759, #760).

The reply carries ACP's `configOptions` once the conversation's
`session_config_options` is known: that list with the session's values as
`currentValue`. Before the first turn the list is null and the reply leaves
the key out, because acpx narrows the controls it pushes to the last list it
was shown, and an invented list would fail its next push. `session/new` and
`session/load` still advertise no `configOptions`.

## Addendum — 2026-10-15: a conversation keeps its agent's options from launch

Decision 1's first layer read the agent row on every turn:
`SessionConfig.effective/3` took the live agent each time a turn opened. An
edit to the agent's `session_config` therefore changed the next turn of every
running conversation of that agent, with no audit on the conversation, while
an edit to the agent's model fences them instead
([0061](0061-conversation-model-override.md) decision 6). "What config did
this run use?" had no single answer (#2664).

**The rule: the agent's `session_config` is copied onto the conversation at
launch, and an edit to the agent reaches new conversations only.** As the
model is resolved once for a conversation, its session options are too.

- `conversations.agent_session_config` holds the copy. `Launch` writes it from
  the agent it scoped, through `SessionConfig.for_launch/1`, which leaves out
  the harness mode ids an agent row stored before their refusal could still
  hold. The `conversation.created` audit records it beside the request.
- `SessionConfig.effective/2` merges the copy, then the conversation's
  `session_config`, then the prompt's. It reads no agent. The opened turn's
  `config_selection["requested"]` is still the one request both connection
  paths send, so wake, rehydration and provisioning, which send the opened
  turn's request, need no change of their own.
- A prompt's options still apply to their turn alone, and managoat_acp
  0.6.0's restore still puts a prompt-only option back on the next turn. The
  next turn's request is the copy plus the conversation's, as before.

**A column, not a merge into `session_config`.** The conversation's
`session_config` is what the launch asked for. A channel resume compares a
request against it (`conversation_session_config_differs`), the API serves
it, and the audit records it. Merging the agent's values in would make a
resume naming the same request it launched with refuse, and would blur what
the caller asked for with what the agent had. Two columns keep both, and the
effective request is their merge, recorded on each turn.

**The backfill.** The migration copies each existing conversation's agent's
current `session_config`, less the harness mode ids, so a running
conversation's next turn requests what the previous release would have
requested. For a conversation that had already ended, the copy is the
agent's config at migration time, not at its launch; what each of its turns
requested is on the turn. A conversation whose agent is gone keeps `{}`,
which is what the previous release read for it.

Not built: the API does not serve `agent_session_config`. A client reads the
effective request per turn from `config_selection["requested"]`.

Decision 1's "The agent's applies to every conversation of the agent" now
means every conversation launched after the agent holds it.

## Addendum — 2026-10-15: session options are the agent's alone

Decided by the maintainer on 2026-10-15. Of decision 1's three layers only the
agent's stays. Production had no conversation or prompt that set
`session_config`.

**Kept.**

- The agent's `session_config`: create, update and show, checked by
  `SessionConfig.check/1` as before.
- Its copy onto the conversation at launch, `agent_session_config`
  (`SessionConfig.for_launch/1`, the addendum above). That copy is what every
  turn of the conversation requests.
- The refusal of `model` and of the harness mode ids, and `offered/1`
  dropping the mode ids from `session_config_options`.
- `turn.config_selection`, with `requested`, `applied`, `skipped` and the
  refusal's `status`/`error`. `requested` is still the one request both
  connection paths send, and wake, rehydration and provisioning read it from
  the opened turn, so it is not derived again from the conversation.
- `conversation.session_config_options`. It is what a client reads to choose
  the agent's options, and the turn machine already writes it.

**Removed.**

- A conversation's `session_config` at launch. `POST /api/conversations` with
  a non-empty `session_config` returns `422 session_config_agent_only`, and
  so does a channel resume that names one, `fresh: true` or not. `null` and
  `{}` are accepted, because existing clients send them.
- A prompt's `session_config`, for one turn. `POST
  /api/conversations/{id}/prompts` answers the same way.
  `PromptDelivery` no longer carries it.
- The per-turn restore (managoat_acp 0.6.0, #2691). With one request per
  conversation there is nothing to put back. The peer, folded into this
  repository as `Managoat.ACP.Peer` (#2737), no longer records a baseline or
  sends a restore, and no longer reports `{:config_restored, id, confirmed}`;
  an option the request does not name is left as the adapter has it. The
  turn machine no longer records `config_selection["restored"]` or emits a
  `restored` stage event. Turns from before this addendum keep the
  `restored` they recorded. The live adapter suite checks instead that an
  option requested on every turn holds.
- `fountain acp`'s forwarding of `session/set_config_option` (#2663). The
  gateway acknowledges the method and applies nothing, with
  `_meta.fountain.applied: false`, as it did before #2663. It still does not
  return "method not found", because OpenClaw's acpx aborts a turn on one
  (#759, #760).
- `409 conversation_session_config_differs` and the
  `session_config_invalid` answer of the conversation and prompt doors. The
  agent's door reports a malformed map as a changeset error, as it did.

`SessionConfig.effective/2` collapses to `effective/1`: the conversation's
`agent_session_config`, less any harness mode id.

**Refused, not ignored.** A caller that names an option and silently gets
the agent's would think it had changed effort or fast mode for that turn.
[0073](0073-one-sandbox-per-conversation.md) refused `sandbox_id` and
`sandbox_mode: "persistent"` with a 422 for the same reason, while accepting
the values an existing client sends to mean "nothing". The request schemas
keep the field, marked deprecated, so the 422 names the change instead of
a schema error.

**The API serves the copy.** A conversation's `session_config` in responses
is now its `agent_session_config`: the options its turns request. Before,
it was the launch's own request, which no conversation can have any more.
This closes the addendum above's "Not built: the API does not serve
`agent_session_config`".

**The data.** A migration folds each conversation's own `session_config`
into its `agent_session_config`, less the harness mode ids, so a running
conversation launched with options of its own keeps requesting them. The
schema stops mapping `conversations.session_config`, and the column is
dropped one release later, as [0074](0074-remove-the-team.md) dropped its
table. A rollback to the previous release reads the column, still there,
over the folded copy, which gives the same request.

**Why one layer.** Three layers made "what did this run use?" a merge of
three sources, needed the restore to keep a prompt's option to its turn, a
gateway that resends options on every prompt to defeat that restore, and a
resume rule for a differing request. An agent is cheap to make, and a
conversation already takes its model and its options from the agent at
launch; one more agent is how a caller runs different options.

The TypeScript SDK's generated types follow the contract. Its hand-written
layer never had a `session_config` argument. Its next major version covers
this removal with others.
