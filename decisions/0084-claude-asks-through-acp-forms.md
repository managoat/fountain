---
type: ADR
title: "Claude asks a person through ACP form elicitation"
description: "A claude conversation whose permission policy asks a person (some verdict is ask) declares ACP form elicitation, which is what makes claude-agent-acp offer AskUserQuestion; one whose policy asks nobody does not, so the tool stays removed and an unwatched conversation never waits on a question (Jake, 2026-10-15). Every elicitation/create form is held for a person like an ask permission request: one elicitation_request block carrying the agent's schema verbatim, answered on the same route with an action and content checked against that schema, declined on timeout, at the turn's end and for another session. No verdict answers a form and the content is never audited. Unbuilt: relaying forms through managoat acp, and the other runtimes."
tags: [acp, conversations, api, permissions]
status: stable
adr: "0084"
adr_status: "Accepted"
date: 2026-10-15
---

# 0084 — Claude asks a person through ACP form elicitation

**Status:** Accepted, 2026-10-15 (#2492).

## Context

Claude Code's `AskUserQuestion` tool asks the person to choose between
labelled options instead of guessing. claude-agent-acp (0.81.2, the pin)
removes the tool from every session unless the client declares form
elicitation on `initialize`:

```js
const disallowedTools = elicitationSupport.form ? [] : ["AskUserQuestion"];
```

With the capability declared, the adapter sends the tool's questions as ACP
`elicitation/create` (`mode: "form"`): one request per tool call, one to four
questions as `question_<n>` select fields, each followed by a free-text
`question_<n>_custom` field, and folds the response back into the tool's
answers. `decline` reads to the model as "the person skipped the questions";
`cancel` aborts the tool call.

The same declaration turns on two other things in that adapter: an MCP
server's form elicitations are forwarded (the SDK declines them by itself
otherwise), and the CLI's refusal-fallback consent prompt ("model X declined;
retry with Y?") is asked (the turn otherwise ends on the refusal). All three
arrive as the same request.

Managoat declared no elicitation (0014 declares no filesystem or terminal
capability either, so that an adapter never asks for what the host does not
service), so every claude agent lost the tool. The request is an
agent→client request the agent blocks on, the same shape as
`session/request_permission`, which 0014 and 0016 already hold for a human
under an `ask` verdict (#940).

ACP's `ElicitationFormCapabilities` is an object. The adapter's SDK
(`@agentclientprotocol/sdk` 1.5.0) reads `elicitation.form` with a schema
that discards a value of the wrong type, so `form: true` would be dropped and
the tool would stay removed. The declaration is `form: {}`.

## Decision

**A claude conversation declares `elicitation: {form: {}}` only when its
permission policy asks a person** (decided by Jake, 2026-10-15). "Asks a
person" means the effective policy (the agent's, narrowed by the launch's)
has some verdict `ask` (`Managoat.ACP.Permissions.asks_person?/1`); a policy
of only `auto_allow` and `auto_deny` asks nobody, and neither does no policy.
A conversation somebody answers permission requests for can also be asked a
question; one nobody answers does not declare the capability, so the adapter
keeps `AskUserQuestion` removed and the conversation never waits on a form.
`Managoat.Runtimes.client_capabilities/2` (the runtime module and the
policy) dispatches a new optional callback, `client_capabilities/1`, which
only claude implements; the others keep
`Managoat.ACP.Protocol.default_client_capabilities/0`. A changed policy
already closes an idle peer before the next turn
(`Connection.stale_reason/4`), so the next spawn declares from the new one. A
peer reattached across a deploy services forms by the policy as it is then.
URL elicitation is never declared: nothing in Managoat opens a URL for a
person.

**The peer services `elicitation/create` only when form elicitation was
declared**, and holds every form-mode request for a person. No verdict
answers it: a form has no answer except a person's. It shares the
permission request's single held slot, its minted public id, its turn-row
persistence (`pending_permission` with `"kind": "elicitation"` and the
schema), its timeout, its reattach replay rule and its first-answer-wins
rule. A url-mode request, or a mode the agent invents, is declined at once; a
request for another session is declined; a peer that did not declare the
capability refuses the method, as before.

**One form is one block.** It renders as an `elicitation_request` block with
`request_id`, `body` (the agent's message), `schema` (the agent's
`requestedSchema`, verbatim) and `tool_id`. All of an `AskUserQuestion`'s
questions are in that one block, as the adapter sent them, rather than split
into one `permission_request` per question.

**The answer reuses `POST /api/conversations/{id}/requests/{request_id}`**,
with `action` (`accept`, `decline`, `cancel`) and, for `accept`, `content`.
The answer is checked against the held schema before it is forwarded: a
property the form does not have, a value of the wrong type, a choice the form
did not offer, or a missing required field is refused with 422
`invalid_content`. Answering a form with `option_id`, or a permission request
with `action`, is 422 `wrong_answer_kind`. The sandbox may not answer.

**Unanswered means declined.** The timeout (the permission ask timeout,
5 minutes by default) and the turn's end decline a held form, which the
adapter reads as "skipped" for `AskUserQuestion`, "declined" for an MCP
form and "keep the refusal" for the fallback prompt. The `request` stage
event's `done` carries the outcome and, for an answer, the action.

**The content is never recorded beyond the transcript's answer to the
agent.** An answer is audited as `conversation.question_answered` with the
request id and the action only, and the stage event carries no content: an
MCP server's form may ask for a secret. A form declined without a person is
not audited, because no policy refused anything.

## Consequences

- Claude agents can ask. A client that renders the block and answers it gets
  the native tool; the TypeScript SDK yields it as an `elicitation` run event
  with `answerElicitation`.
- **The default asks nobody, so nothing changes for it.** A conversation on
  the default `auto_allow` policy, a headless one or one an agent started
  included, does not get the tool, and its MCP forms and refusal-fallback
  prompts are declined by the adapter as before.
- **A conversation whose policy asks can now wait on questions too.** Claude
  decides when to ask; each question waits up to the ask timeout before it
  is declined and the agent continues. The refusal-fallback prompt delays a
  refusal the same way. That is the same bargain the `ask` verdict already
  makes for tools.
- To get questions without asking about any tool, a policy needs an `ask`
  verdict somewhere; there is no separate switch.
- A client that does not render the new block, on a policy that asks, sees
  the form time out and be declined.
- `managoat acp` does not relay forms to the editor; an editor client of the
  gateway sees the form time out. Unbuilt.
- The conversations sample app does not render the block. Unbuilt.
- codex, gemini and custom `acp` runtimes declare nothing new. A runtime
  that declares it later needs only the callback.

## Alternatives considered

- **One `permission_request` per question, asked one at a time** (#2492's
  first suggestion). Fits a single select, but not a multi select, the free
  text field, an MCP server's arbitrary form, or the adapter's single
  response per form; the server would have to split one request and
  reassemble its answers.
- **Declare it for every runtime.** The other pinned adapters were not
  checked for it, and a capability is a promise the peer must keep.
- **Always declare it for claude** (the first draft of this ADR). Every
  conversation got the tool, and one nobody watches could spend the ask
  timeout on each question.
- **A switch of its own, per agent.** A new field and its API, for a choice
  the policy already expresses: whether a person answers this conversation.
- **Answer forms from a policy, like permissions.** A form has no answer
  without a person; the only automatic answer is to decline, which is the
  timeout's job.
