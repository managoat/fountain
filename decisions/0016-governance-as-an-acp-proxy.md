---
type: ADR
title: "Governance as an ACP proxy"
description: "Retired 2026-10-14, the governance plane never built: its premise that the policy point in the middle is what Fountain sells went with the hosted business. The permission map it counted as foundation is built and is ADR 0014 gate 3 (`permission_policy`, `Fountain.PermissionPolicy`, docs/concepts/permissions.md). Was: Proposed; a versioned tenant policy primitive, path-aware PDP and decision ledger, none built."
tags: [acp, governance, product]
status: deprecated
adr: "0016"
adr_status: "Retired"
date: 2026-08-09
generated: { by: codex/gpt-5, at: 2026-09-03T02:05:29-04:00 }
verified: { by: codex/gpt-5, at: 2026-09-03T02:05:29-04:00 }
stale_after: 2026-11-15
---

# 0016 — Governance as an ACP proxy

**Status:** Retired 2026-10-14; see the addendum at the end. The text above
the addenda is history. Was: Proposed — **the enforcement foundation is built; the governance
product described here is not.** ACP is the only runtime I/O path for all four
coding agents ([0014](0014-agent-client-protocol.md)). Agents and conversations
carry a narrow per-tool permission map; Fountain can automatically permit or
deny a runtime's `session/request_permission`, hold it for a human, deny after
five minutes, and take the first answer from the API, either web app or an ACP
editor (#947, #950, #965). A deny does not end the turn. A runtime that never
asks is refused a policy it cannot enforce. `Managoat.ACP` now owns the peer
and permission evaluator behind Fountain's writer callback (#1358).

The other foundations landed out of the order proposed here. The sandbox
behaviour and conformance suite are built ([0018](0018-sandbox-provider-abstraction.md));
self-hosted runners and an isolated Firecracker backend followed ([0022](0022-self-hosted-runner-provider.md),
[0036](0036-firecracker-runner-backend.md)); and [0019](0019-egress-credential-brokerage.md)
built the forward broker, including inference credentials.

There is still no tenant-owned, versioned `Policy` primitive, path-aware PDP,
general allow/deny/escalate rule language, or separate governance-decision
ledger. The shipped permission map is useful enforcement, not the whole claim
this ADR makes. The gates below record that partial, out-of-order build rather
than pretending the original roadmap happened unchanged.

This is the third ACP ADR and the only one that is about what Fountain *is*.
[0014](0014-agent-client-protocol.md) proposes Fountain as an ACP client of
the CLIs it runs; [0015](0015-fountain-as-an-acp-agent.md) proposes Fountain
as an ACP agent reachable from an editor. Both are protocol decisions. This
one claims that the reason to do either is that together they put Fountain in
the middle of a synchronous call it can *answer* — and that answering is the
product.

It does not supersede either. It amends how **0014 gate 3** should be read
(see *Reframing 0014 gate 3*), and if accepted it becomes the reason 0014 and
0015 are sequenced the way they are.

## Context

### Fountain could observe. It could not intervene.

When this ADR was written, every runtime ran with its safety rail removed, and
0014 listed the vendor flags. This was not carelessness: a headless CLI had no
channel back to a human, so bypass was the only way it ran unattended.

The consequence was that the audit trail from [0013](0013-audit-trail.md) was
**retrospective by construction**. It is an excellent record of what a tenant
changed. It could not say "and this was not allowed to happen,"
because nothing in the system was positioned to prevent anything. The sandbox
was not defence in depth; it was the only defence there was.

That starting point is now history. The vendor bypass flags are gone; ACP
permission requests reach Fountain; and the shipped permission map can permit,
deny or escalate by tool title or ACP kind. It cannot inspect a command, path,
destination or prompt, and opencode sends no permission request at all. The
honest answer to *what stops the agent from doing X?* is therefore narrower
than this ADR's target: Fountain can stop a class of tool calls on runtimes
that ask, and the sandbox and broker enforce coarser boundaries underneath.

### A permission map is not yet a Policy primitive

Environment, Vault, Agent and Conversation are all **configuration**: what the
agent has, and what it ran. Agent and Conversation now carry
`permission_policy`, a map from tool title or ACP kind to `auto_allow`, `ask`
or `auto_deny`; a launch may narrow and never widen the agent's rule. That is a
real rule and should not be described as absent.

It is also deliberately smaller than the primitive proposed here. It has no
policy id or version, no conditional input beyond the tool label, and no
decision record tying a verdict to the rule that produced it. Adding the rest
piecemeal to Environment, Vault, Agent and Conversation would still scatter a
governance system across schemas designed to describe capability and execution.

### What ACP actually changes

`session/update` is a notification — a better-typed version of the stdout we
already parse, and on its own it buys a cleaner render path and nothing else.

`session/request_permission` is a **request**. The agent blocks; the client's
answer determines what executes. The same is true of `fs/read_text_file`,
`fs/write_text_file` and `terminal/*`, which the protocol assigns to the
*client*. Once Fountain holds the client role, it is synchronously in the path
of every tool call, file access and command the agent attempts — not as a
listener, but as the thing that decides.

That is the whole of the argument for this ADR. Not that ACP is a nicer
stream format, but that it is the only mechanism on the table that turns a log
into a control, and it does so by being synchronous.

### The reach, and its honest split

"Whatever client, whatever cloud" is the reach of the governance plane, not a
feature list. It splits unevenly, and the split determines the architecture:

| Control | Enforced at |
|---|---|
| Tool-call approval | ACP — `session/request_permission` |
| File read / write | ACP — `fs/*` (client-implemented) |
| Command execution | ACP — `terminal/*` (client-implemented) |
| Model, spend, prompt policy | inference path (see *Credential brokerage*) |
| **Network egress** | **the sandbox substrate — ACP cannot see it** |

Egress is the control most often asked for first and the one the protocol
cannot reach: the agent's network access happens inside the sandbox, below
ACP entirely. It is a property of *where the thing runs*. This is why the
substrate is in scope for a governance ADR at all, and it is the honest
correction to a reading of 0014 in which placement is merely orthogonal —
placement is orthogonal to the *protocol* and load-bearing for the *product*.

## Decision

**Fountain becomes a policy decision point that speaks ACP on both sides.**
The proxy shape from 0014 and 0015 is retained exactly; this ADR adds the
thing in the middle, and says that the middle is what we sell.

```
   whatever client                whatever cloud
  ┌────────────────────┐
  │ editor · web · CI  │◄── escalate ──┐
  │ · chat             │─── answer ────┤
  └─────────┬──────────┘               │
            │ ACP — Fountain as agent  │      (0015)
            ▼                          │
  ╔══════════════════════════════════════════════════════╗
  ║                      fountain                        ║
  ║  ┌────────────────────────────────────────────────┐  ║
  ║  │  PDP — evaluated server-side, always           │  ║
  ║  │  tool_call · fs/* · terminal/* · inference     │  ║
  ║  │  → allow / deny / escalate                     │  ║
  ║  └────────────────────────────────────────────────┘  ║
  ║   audit (0013)  ·  credential broker  ·  metering    ║
  ╚══════════════════════════════════════════════════════╝
            │ ACP — Fountain as client   │ inference proxy
            ▼                            ▼      (0014)
  ┌──────────────────────────────┐   provider APIs
  │ sandbox                      │   (tenant key, held server-side)
  │  claude · codex · gemini · … │
  │  ── egress policy HERE ──    │
  └──────────────────────────────┘
```

### 1. A fifth primitive: Policy

A `Policy` is a tenant-owned, versioned set of rules attached to an agent (and
later to an org or a project), evaluated on every intercepted call, returning
**allow**, **deny**, or **escalate**. It is the first primitive that expresses
what an agent may *not* do, and without it "governance" is the dashboard we
already have.

Deliberately unspecified here: the rule language. Whether it is a small
declarative schema, a matcher over ACP's `tool_call.kind` and `locations`, or
something embeddable is a gate-2 question that should be answered against real
denials rather than in advance. What *is* decided is that rules are data owned
by the tenant, versioned, auditable, and never expressed as code we deploy.

### 2. The PDP is evaluated server-side, always

Never in the sprite, never in the editor, never in `cli/`. The sprite executes
untrusted model output and the editor is a user surface; both are adjacent to
the thing being governed and neither has standing to decide. The proxy shape
is load-bearing rather than incidental precisely because the middle is the
only position with that standing.

Corollary, and it is a hard rule: **a runtime that cannot be made to route its
tool calls through the client is not a governed runtime.** We may still run
it, but it must be labelled ungoverned in the UI and the API rather than
quietly enrolled under a policy that cannot reach it.

Every surface may deny early for presentation; only an enforcement point may
permit. An editor, web app, CLI or sandbox may hide, disable or decline an
action, but none has standing to grant one. The server-side ACP evaluator,
inference broker or sandbox control is load-bearing. Removing a presentation
check may change what a user sees; it must never change what an agent can do.

Every recorded decision names its subject: tenant, agent, conversation and the
principal or surface that initiated the turn. It reuses 0013's closed actor
vocabulary where that vocabulary applies, but governance actions do not become
audit mutation actions. A principal-less subject is invalid rather than an
anonymous value that can drift into the record.

A denial is semantic and transport-neutral: action, reason, details and policy
version, with no HTTP status, redirect or ACP option baked into it. The API,
web apps, editor and runtime adapter render the same denial in their own
protocols.

### 3. Reframing 0014 gate 3

> **Status note (2026-09-03):** 0014 gate 3 and 0015 gate 4 are built, but in a
> narrower shape than this section proposes. `Managoat.ACP.Permissions`
> evaluates a title/kind/default map; `Fountain.Conversations.Pending`
> persists an `ask`, sends it to the API, apps and editor, takes the first
> answer, and denies after five minutes. It cannot express "deny writes outside
> the workspace," and there is no versioned PDP or separate decision record.

0014 gate 3 originally read as "implement `session/request_permission`
against the conversation LiveView: a real approval prompt." Read through this
ADR, the intended shape is broader:

> Build a PDP. The LiveView prompt is **one of its answer sources**, used only
> when a rule evaluates to *escalate*.

Policy-first, human-second. 0015 already found the failure mode from the other
end — permission forwarding is two hops (sprite → Fountain → editor →
Fountain → sprite) and *what replies when the editor detaches mid-request?* In
a product whose pitch is governance, that stops being an edge case and becomes
core semantics. Four requirements fall out, and none is a polish item:

- **Most decisions are made without a human.** An agent makes many tool calls;
  a design that asks a person about each one is not a governance product, it
  is a captcha.
- **Every escalation carries a timeout, and the default on expiry is deny.**
  Fail-open is not a governance posture, and an escalation nobody will ever
  see is the normal case for a conversation started from CI or left running
  overnight. This is built with a five-minute timeout.
- **An escalation holds a sandbox open, so the timeout is a cost control as
  much as a security one.** 0014's *Session lifetime* section binds the ACP
  connection to the turn precisely so that an idle sandbox can be reclaimed,
  and interception is possible only inside that window — which is fine,
  because tool calls only happen inside it too. But a conversation parked on
  an unanswered `session/request_permission` is a turn in flight, and
  `Lifecycle.check/4` suppresses idle reclaim while one is
  (`busy? = state.current_command != nil`, `conversation_server.ex:1263`). So
  a prompt nobody answers bills a sprite up to the 24-hour ceiling with the
  idle timeout disarmed. That is not a hypothetical: #413 produced exactly
  this by accident, and the comment at `conversation_server.ex:1204` records
  the result — "idle reclaim was suppressed (busy? true), the reaper skipped
  the sandbox (server alive), and the sprite billed until max_lifetime."
  Escalation deadlines must therefore be strictly shorter than the idle
  window, and stated as a number rather than inherited from it.
- **The conversation survives a deny.** A denial is an ordinary result the
  agent is told about, not a fault. Anything else hands `SandboxReaper` and
  the rehydrator a hang state neither knows about — which is the exact risk
  0015 named as a precondition for its own gate 4. This is built.

### 4. Credential brokerage: the sandbox holds no long-lived secret

[0019](0019-egress-credential-brokerage.md) implemented and generalized this
section. Fountain did not point each runtime's provider base URL at a bespoke
inference proxy. It built a forward proxy that the sandbox reaches through
`HTTPS_PROXY`; the sandbox holds placeholders and a short-lived,
conversation-scoped broker session, while the real credential is attached at
the proxy. Bindings constrain which hosts receive each secret, brokered
environments apply a limited-network floor, inference credentials use the same
path, and the egress trail records what crossed it.

That removes the per-runtime base-URL survey that this section treated as a
blocker and reaches more than inference. It also establishes the chokepoint
this ADR needs. It does not yet evaluate a tenant-owned governance policy over
model choice, spend or prompt content. Brokerage changes custody and makes
those questions enforceable; it is not itself the PDP that answers them.

### 5. The sandbox behaviour is defined by a conformance bar, not a cloud list

> **Status note (2026-09-03):** the seam is built and extracted.
> [0018](0018-sandbox-provider-abstraction.md) produced the behaviour and
> conformance suite, now `Managoat.Sandbox`, with Sprites, E2B and Daytona
> adapters. [0022](0022-self-hosted-runner-provider.md) added a tenant-owned
> runner and [0036](0036-firecracker-runner-backend.md) added its isolated
> backend. `Fountain.SandboxProviders` decides which are enabled here. The old
> two-implementation cap and bring-your-own-Kubernetes plan did not survive.

The surviving decision is **one sandbox behaviour with a capability contract
and conformance suite**. A provider answers for itself; Fountain does not
special-case a cloud name into a governance promise. A governed backend must
cover, at minimum:

- network egress policy, expressible per conversation;
- provisioning that injects no long-lived credential (§4);
- exec with captured output, and stdio attach for the ACP peer;
- guaranteed destruction, on a path the reaper can drive.

A backend that cannot express egress policy cannot host a governed
conversation, whoever owns the cloud it runs in. This inverts the problem from
"support everything" to "here is the bar," which is defensible, testable, and
makes community-contributed backends viable without us owning them.

### 6. Decisions are not mutations

`Fountain.Audit.Event` records `action`, `resource_type`, `resource_id`,
`actor`, `request_ip`, `metadata`. 0013's rule is *only record what happened*
— a rejected changeset records nothing, because a trail that logs attempts as
changes cannot be read literally.

A denied tool call **did** happen, and it is the single most important thing a
governance product records. But it is not a mutation of tenant-owned state,
and forcing it into `audit_events` would break exactly the property 0013 is
built on.

So: a **separate decisions record** — the request, the policy version that
decided it, the verdict, the answer source (rule / human / timeout), and the
latency. Same append-only discipline, same actor vocabulary, its own table and
its own rule. The existing vocabulary is closed and this ADR does not open it;
`sprite` already names an agent acting as the tenant, which is precisely the
principal on the requesting side of every decision.

This record is not built. The narrower permission system currently records a
`conversation.permission_denied` audit event and records no permits. That is a
useful operational event, but it has no policy version, answer source or
latency and does not satisfy this decision. A broader PDP must migrate or
dual-write deliberately rather than silently treating the audit row as the
decision ledger.

### 7. Coverage is enforced, not remembered

A governance claim needs a guardrail over every runtime and enforcement
chokepoint it names. The implementation must fail a test when a claimed path
bypasses evaluation, or list that path as explicitly ungoverned with a reason.
The current permission tests establish the runtime-specific matrix; the
broader PDP adds a reviewable decision-table snapshot of subject, action,
policy input and verdict. A policy change becomes a table diff, not a predicate
hidden in a call graph.

### Gates

**Gate 0 — partially built.** The shipped permission map proves interception,
server-side evaluation, automatic deny, deny-on-timeout, human escalation and
a conversation that survives refusal. It does not implement the gate's test
rule — *deny writes outside the workspace* — because it cannot inspect a path.
It also does not write the separate decision record or carry a policy version.

Two of its success criteria are numbers, not properties, and they should be
written down before the gate starts rather than discovered in it: the added
per-tool-call latency of a *non-escalated* decision, which every tool call
pays; and the escalation deadline, which by §3 must be shorter than
`sandbox_idle_timeout_minutes` and is the difference between a governance
control and an unbounded bill.

**Gate 1 — not built.** `fs/*` and `terminal/*`
serviced against the sprite, under policy. 0014 lists these under Consequences
as the likeliest source of a security finding, and that judgement stands:
paths arriving over this channel are untrusted input from a sandbox we do not
fully control, and the absolute-path and 1-based-line requirements are the
protocol's, not ours.

**Gate 2 — a narrow precursor is built.** Title/kind/default mapped to
`auto_allow`, `ask` or `auto_deny` is enough for runtime permission requests.
The versioned, tenant-owned rule language described in §1 remains unchosen and
must be selected against path-aware denials from gates 0 and 1.

**Gate 3 — built, with a different mechanism.** 0019's forward proxy replaced
the per-runtime base-URL design and now brokers inference credentials too.

**Gate 4 — the provider foundation is built.** The behaviour, conformance
suite, hosted adapters, runner and Firecracker backend exist. A governance
capability bar and an honest governed/ungoverned label still need to be added
for the controls this ADR claims.

Human escalation to an *editor* — 0015's own gate 4 — is built. The first
answer wins across peer clients; a detached editor is not a privileged
fallback, and the persisted request remains answerable elsewhere until its
five-minute timeout.

### Not in scope

- **The rule language.** Gate 2, deliberately.
- **Workspace sync and read-through.** 0015 names both as separate decisions
  and this ADR does not smuggle them in; the editor stays a control surface.
- **Governing anything that is not a coding agent in a sandbox.** A general
  policy plane for arbitrary MCP traffic is a larger and different product.
- **Application authorization.** Whether a user, API key, sprite or worker may
  invoke a Fountain context mutation is a separate policy plane, tracked in
  [#1464](https://github.com/BinaryBourbon/fountain/issues/1464). It must not
  share this `Policy` namespace by accident.
- **Tenant scoping.** User-facing queries continue to select by `user_id`; a
  policy check after an unscoped fetch is weaker than never loading another
  tenant's row.
- **Rate limiting.** Per-IP abuse control runs before authentication and has no
  governance subject to evaluate.

## Consequences

**Tool-layer policy is advisory unless the substrate backs it.** An agent that
can run `bash` routes around fine-grained tool rules; an agent with
unrestricted egress can exfiltrate whatever it can read regardless of what it
was allowed to call. Policy and sandbox are one control split across two
layers, and shipping either alone sells a guarantee we do not have. This is
the most important sentence in this ADR and the easiest one to lose during
implementation.

**Latency lands on every tool call.** A synchronous PDP in the path, and two
network hops whenever a decision escalates to a human. Agents make many tool
calls. A budget for this belongs in gate 0's success criteria, not in a
follow-up.

**We would be betting governance on a young spec.** ACP's remote transport is
documented as work in progress and parts of the adapter ecosystem are
vendor-maintained npm packages versioned independently of the CLIs they wrap
(0014, *supply-chain surface*). A vendor dropping an adapter turns a governed
runtime into an ungoverned one — which means "supported runtime" acquires a
maintenance obligation and a public status, per §2's corollary.

**The JSON-RPC peer did not land in `ConversationServer`.** It now lives in
`Managoat.ACP.Peer` behind a writer callback; Fountain keeps persistence,
lifecycle and answer routing in `Conversations.Pending` and `TurnMachine`.
The future PDP should preserve that boundary rather than move protocol state
back into the conversation process.

**The event stream becomes an interface with a policy dimension.** 0015 notes
that two clients rendering the same stream makes it an interface subject to
the OpenAPI spec and the router-walking guard from the #531 campaign. Decision
records extend that: they are the part a customer will export, alert on and
show an auditor.

**This is a go-to-market change wearing an architecture costume.** Governance
sells to a buyer with procurement, a security questionnaire and a long cycle.
[0031](0031-credits-are-the-product.md) and
[0038](0038-onboarding-first-reply.md) describe the current self-serve product:
credits, an API-first path, and activation at the first reply. The enforcement
foundations above are useful there without making an enterprise governance
claim. Adopting the broader claim still chooses a buyer, sales motion and
reliability obligation; the code is the cheaper half of that choice.

**What we give up:** the position that Fountain is a convenience layer over
agent configuration. Today the pitch is that running Claude with worktrees and
hand-shuffled MCP config is painful, and Fountain makes it pleasant. That
pitch is true, it is what exists, and it sells to an individual developer who
also has the option of a free CLI on a laptop. A governance plane is a claim
to be relied upon, and claims that are relied upon come with the obligation to
be right about them.

## Alternatives considered

- **Stop at 0014, 0015 and the shipped permission map.** This is now a real,
  useful product: one runtime protocol, editor integration and coarse tool
  permissions. Rejected as this ADR's *end state* because it cannot express
  conditional rules, prove a decision against a policy version, or back the
  broader governance claim.
- **Governance as post-hoc detection.** Keep the current architecture, add
  alerting and anomaly rules over the 0013 trail. Much cheaper, ships now, no
  protocol dependency, no latency. Rejected as the primary answer because it
  cannot prevent anything and the first buyer question is prevention — but it
  is a genuinely good *complement*, and if gate 0 fails this is the fallback
  rather than nothing.
- **Enforce entirely at the substrate** — no ACP, no PDP; sandbox network
  policy, read-only mounts, seccomp. Strictly stronger where it applies, since
  it cannot be argued around by a model. Rejected as sufficient on its own
  because it is coarse: it can say "no internet," not "you may open a PR
  against this repo but not force-push to `main`," and the second is the
  granularity the product needs. The right reading is that this ADR needs
  both, which §5 encodes as the conformance bar.
- **Buy or wrap an existing policy engine.** Sensible for the rule language at
  gate 2 and explicitly left open there. Rejected as a *starting point*
  because the hard part is not evaluating a predicate — it is having a
  synchronous position from which the answer matters, which is gates 0 and 1.
- **Lead with the sandbox abstraction, ACP later.** The implementation partly
  took this route: provider conformance and the broker landed before the
  broader PDP. That sequencing produced useful security controls without
  deciding that governance is the product. The remaining signal is commercial:
  if prospects ask about network and residency before approvals, the substrate
  may be the product and the proxy the sidecar.

## Addendum — 2026-10-14: no self-serve product to sit beside

The Consequences paragraph that cites [0031](0031-credits-are-the-product.md)
and [0038](0038-onboarding-first-reply.md) as "the current self-serve
product" is out of date. Fountain is no longer sold as a hosted service:
credits were removed on 2026-10-12 (#2609) and 0031 is retired, and 0038's
verified landing and onboarding stamp were removed on 2026-10-13. The
enforcement foundations this ADR lists as built are unchanged, and the
governance plane remains proposed and unbuilt.

## Addendum — 2026-10-14: retired, nothing in the middle is sold

The Decision rests on one sentence: "the middle is what we sell". Fountain is
no longer sold (2026-10-12; see [0003](0003-direction-option-b-api-ui-onboarding.md)'s
addendum), so there is no product for a governance plane to be, and no buyer
whose questions would decide between a proxy and a substrate. The ADR had
been Proposed since 2026-08-09 without its governance half being built, and
it is retired rather than left open.

- **Not built, and not planned:** the tenant-owned, versioned `Policy`
  primitive, the path-aware PDP, the general allow/deny/escalate rule
  language and the separate governance-decision ledger.
- **Built, and owned elsewhere:** the per-tool permission map. It is
  [0014](0014-agent-client-protocol.md) gate 3: `permission_policy` on agents
  and conversations, `Managoat.ACP.Permissions` for the tool half,
  `Fountain.PermissionPolicy` for the Fountain half (`ask_timeout`), and
  `docs/concepts/permissions.md` in the manual. Read 0014 for
  how it works, not this ADR. The broker
  ([0019](0019-egress-credential-brokerage.md)) and the sandbox seam
  ([0018](0018-sandbox-provider-abstraction.md)) stand on their own ADRs too.
- **Stale in the status block:** ACP is the I/O path for three packaged
  runtimes (claude, codex, gemini) and the `acp` runtime that runs a named
  command ([0049](0049-the-acp-runtime-runs-a-command-you-name.md)), not
  "all four coding agents"; opencode was removed in 2026-10, so the remark
  that it sends no permission request no longer describes a runtime Fountain
  runs.
