# Product Marketing Context

**Document version:** v7
**Last updated:** 2026-08-29

This file is the positioning, the ICP and the vocabulary that marketing work in
this repo starts from. It is drafted from the repo itself: `README.md`,
`docs/primitives.md`, `docs/tour.md`, `CLAUDE.md`, `contributing/docs.md`,
and the marketing templates under
`apps/fountain/lib/fountain_web/controllers/marketing_html/`.

Sections that the repo cannot source are marked **GAP** and left empty on
purpose. Fountain's audience checks claims, so an invented competitor quote or a
made-up metric costs more than a blank line. Fill a GAP from a primary source
and bump the version.

## Product Overview

**One-liner:** Run coding agents on ready machines. Pay only while they work.

**Lead with the meter.** Both halves of that line are the pitch, and the second
half is the part nobody else offers. A prompt goes over HTTP, a machine wakes
up with the repositories, packages and credentials already on it, an agent
works, the answer comes back, and the machine parks. A parked machine costs
nothing, holds its disk and takes none of the account's concurrency. Copy that
describes the machine without the meter has described a sandbox provider.

**The harness is not the product.** There is a glut of agent harnesses and
Fountain runs four of them (`claude`, `codex`, `gemini`, `opencode`) behind one
API. Nothing in the pitch should imply the runtime is the scarce part. The
scarce part is everything under it: the machine lifecycle, the installs, the
configuration, the networking, and a credential that reaches the machine
without reaching the prompt. That list is the reader's own to-do list, and
naming it is what makes the page land.

**What it does:** Agent, Environment and Vault are templates you write once. A
Conversation runs one of them on a machine Fountain builds, warms, meters and
reclaims. You send a prompt over the API and read the reply; the sandbox parks
between messages and wakes with its work intact, so there is no box to
provision, lock down, or pay for while nobody is talking.

**Product category:** The shelf is "managed sandboxes for coding agents", or
what the repo calls a managed agent control plane. Buyers arrive from "how do I
run Claude Code / Codex on a server", not from a category they already have a
name for. Assume readers have **no prior model for this category** and explain the
product terms when introducing them.

**Product type:** Multi-tenant hosted API plus a self-hostable server. Web UI is
an operator console, not an application.

**Self-hosted positioning:** Ownership is the decision, and the bring-up is its
proof. Lead with the same API, SDK and CLI running under the reader's keys and
infrastructure. Put the ownership choices before prerequisites and installation
detail. The open-source applications demonstrate product shapes, not customer
adoption, and copy must not present them as third-party proof.

**Business model:** None. Since 2026-10-12 Fountain is a self-hosted
application and is not sold as a service: no credits, no plans, no seats, no
subscription (ADR 0031, retired). The operator pays their own sandbox provider
and, if they set platform keys, their own model provider. Customers bring
their own model keys. Licence: the server is AGPL-3.0.

**Never quote a price.** Fountain charges nothing, and what a provider charges
is the provider's to say.

## Target Audience

**Target companies:** Small technical teams and solo builders shipping products
that embed coding agents. Not enterprise. Org and team features are explicitly
out of scope until the traction goal lands, so copy must not imply seats, roles
or SSO.

**Decision-makers:** The developer is the buyer. There is no committee, no
procurement, and no separate economic buyer at this stage. One person reads the
docs, runs the tour, and puts a card in.

**Primary use case:** Running a coding agent somewhere that is not your laptop,
with the machine, the credentials and the agent config kept as separate,
reusable rows.

**Jobs to be done:**
- "Give my app a coding agent without building the machine it needs."
- "Stop hand-shuffling worktrees, MCP configs and skill setups on my laptop."
- "Let something that is not a person start an agent run, and follow it."

**Use cases:**
- An API or webhook starts an agent run (the case study's alert-to-pull-request
  loop is the worked example).
- Agents as teammates: a Conversation bound to the `fountain:team` channel.
- Batch and CI work where a run needs a real checkout and a real credential.

## Personas

Single-persona at this stage. The developer is user, champion and buyer at once.
Do not write multi-stakeholder copy until org features exist.

| Persona | Cares about | Challenge | Value we promise |
|---|---|---|---|
| Infrastructure-literate developer | Whether the primitives compose, what the credential actually touches, what a run costs | Has run agents locally and hit the machine, secret and concurrency problems | Four objects that divide the problem, and a run you can start from code |

## Problems & Pain Points

**Core problem:** Builders do not want to run computers. They want software that
holds a conversation, and the software needs a computer to hold it on. So they
end up owning a machine lifecycle, a package install, a config, a network and a
credential problem, none of which is the product they set out to ship. That is
`README.md`'s own framing and the most load-bearing problem statement in the
repo. The older version of the sentence, "running Claude instances with
worktrees locally and shuffling MCP configs by hand is painful", is the same
problem told from the laptop rather than from the product, and it still works
for a reader who has not shipped yet.

**Why alternatives fall short:**
- A raw sandbox provider gives you a machine, not a template that outlives the
  run. There is no row to list, diff, share or launch from code.
- Rolling your own means the machine image, the credentials and the agent config
  end up in one object, so every credential rotation edits the image and every
  prompt edits the credentials. `docs/primitives.md` argues exactly this, and the
  four-way split is the answer.
- Running locally does not give a run an id, a status, a transcript or an event
  stream, so a webhook or a cron job cannot start one and follow it.

**What it costs them:** Time on undifferentiated plumbing, and a machine you pay
for while nobody is talking to it.

**Emotional tension:** Handing a real credential to a model. The honest version
of this fear is the product's best material, and the guardrail vocabulary
("a gate the agent is unable to pass beats a gate it is asked not to") is how the
repo answers it.

## Competitive Landscape

**GAP — no competitor claim in this file is sourced yet.**

The competitive set to profile, in the order it matters:
- **Sandbox and code-execution platforms** the buyer might use directly instead
  of Fountain. E2B, Daytona, Modal, Fly.io. Note that E2B and Daytona are also
  *providers Fountain runs on*, so the framing is a layer argument, not a
  head-to-head one, and copy must not blur that.
- **Agent-hosting products** that run a coding agent for you as a finished
  service.
- **Roll your own** on a VM or in CI, which is the real incumbent and probably
  the most common thing a reader is doing today.

Before any comparison copy ships, read each competitor's own live page, quote
their own words, and record the URL and the date read. Their pricing pages change
without telling us.

## Differentiation

**Key differentiators:**
- **The meter runs only while an agent works.** A parked machine, an idle one
  and one on the customer's own runner all cost nothing. A sandbox provider
  rents a box by the hour whether or not anybody is talking to it. This is the
  differentiator to lead with, and the one that pays for the whole pitch.
- **Four primitives, split by rate of change.** What the machine holds changes
  rarely; which credentials a run uses changes constantly; how the agent behaves
  changes sometimes; what it does now changes continuously. Fountain gives each
  its own object. That division is the product.
- **The Vault wins on key collision.** One rule that makes the split usable
  rather than merely tidy, and the reason one Environment can run as you, as a
  bot, or as a customer.
- **A run is an addressable thing.** Id, status, transcript, event stream. A
  webhook, a cron job or another agent can start one and follow it.
- **The machine is Fountain's problem.** Built, warmed, metered, reclaimed.
  Parks between messages and wakes with its work intact.
- **The secret does not have to enter the sandbox.** On a hosted account with the
  egress broker on, a bound secret goes to the broker and the sandbox gets a
  placeholder such as `__github_token__`.
- **You pay for machine time, never for tokens.** Bring your own model key.

**Why customers choose us:** The templates outlive the run.

## Objections

| Objection | Response |
|---|---|
| "I can run an agent in a sandbox myself." | You can. The templates are the part you would end up building: rows you list, diff, share and launch from code, and a run with an id something else can follow. |
| "I am not giving a model a token that can push." | Then do not. Scope it to one repository, put the identity in a Vault so swapping it is a field and not a redeploy, and on a hosted account with the broker on the value never enters the sandbox at all. |
| "What happens when it does something wrong?" | Build the last gate so the agent cannot pass it. The case study's agent cannot approve or merge its own pull request, and cannot reach the cluster at all. |
| "What does this actually cost me?" | Fountain is free to run. You pay your sandbox provider for machine time and your model provider for tokens, with your own keys. |

**Anti-persona:** An enterprise buyer who needs orgs, seats, roles or SSO.
Those features are deliberately out of scope until the traction goal lands, so
selling to that buyer now costs a roadmap we have chosen not to have.

## Switching Dynamics

**Push:** The laptop stopped being enough. Worktrees, MCP config drift, and a
machine that has to be awake for the agent to work.

**Pull:** A run you can start with one API call, and templates that survive it.

**Habit:** The local setup already works, and the scripts around it are theirs.

**Anxiety:** The credential. Also: what a runaway agent costs, and whether a
sandbox that "parks" really comes back with the work intact.

## Customer Language

**GAP — no verbatim customer language yet.** There are no interviews, support
transcripts, reviews or quotes in this repo to mine. Until there are, copy draws
on the repo's own problem statement rather than pretending to quote a user.

**Words to use:** Agent, Environment, Vault, Conversation, sandbox, runtime,
template, run, transcript, primitive, cluster, gate, guardrail.

**"Computer" is a marketing word only.** The manual uses "sandbox" for the
isolated machine so its terminology matches the API and glossary. `README.md`
uses it on purpose because it is the word the reader already has for the thing
they do not want to run. The homepage instead
names coding agents and the work-only meter in its first line. When another
marketing surface uses "computer", use it once to open, then say "sandbox" or
"machine" for the rest of the page. Never use it in `docs/`.

**Accuracy:** Do not describe unbuilt behavior as available. Do not describe
credits, plans, tiers, seats or a subscription; there are none.

**Glossary:**

| Term | Means | Never means |
|---|---|---|
| Environment | the primitive | a deployment tier, or a map of env vars |
| Vault | the primitive: a small, plural, static override layer | HashiCorp's central authoritative credential store |
| Agent | the primitive, the stored config | the running process |
| Conversation | the primitive, one run | the transcript |
| runtime | the coding-agent CLI (`claude`, `codex`, `gemini`, `opencode`) | |
| sandbox | the isolated machine a run happens on | |
| Fountain | the product | the CLI binary, or the injected skill |
| `fountain` | the CLI binary, always in code font | |

**The Vault rule.** Because of HashiCorp, "vault" carries a prior that inverts
Fountain's meaning. Every page that introduces a Fountain Vault for the first
time states the collision before it states the feature, and never uses "Vault"
unqualified in a heading where a newcomer meets it first.

## Brand Voice

**Tone:** Modal's calibration and Tailscale's honesty. Explicitly **not** Fly's
register: the jokes cost reading budget the reader needs for the model.

**Style:** Voice lives in explanation only. Reference gets none. Four modes:
tutorial (first person plural, warm), how-to (second person, imperative, no
adjectives), reference (no person, declarative), explanation (first person
plural, allowed opinion, signed and dated).

**Personality:** Precise, candid, unshowy, technical, load-bearing.

**Manual writing:** See the optional guidance in `contributing/docs.md`. State
accurate defaults, show real commands and output, and explain failure cases.
The manual has structural checks and no prose linters. Marketing copy lives
in `managoat/site`.

## Proof Points

**Metrics:** The only sourced numbers are the case study's, counted on one
production cluster over a stated window (11 to 25 August 2026) and held as
literals in `marketing_html.ex` so they cannot quietly widen their own window.
Lead the aggregate proof with the 7.5 minute median alert-to-verdict time. The
alert and pull-request counts support that result rather than compete with it.
78 alerts investigated by an agent; 4m 27s from alert to open pull request on
the worked incident; 7.5 minute median alert to verdict; 0 cluster credentials
the agent holds. Twelve fix pull requests opened and eight merged, against 78
alerts, because most alerts end with no repository fix to propose. Frame that
ratio as reach rather than as a ceiling: it is set by how many systems the
agent may read and how many repositories it may open a pull request against.

The system is a Kubernetes cluster carrying live production workloads. Numbers
reported by the cluster administrator (us). **Say both whenever the numbers
appear, and keep the "(us)".** Without it the role noun reads as a neutral
third party, on a page where the administrator and the seller are the same
party. That conflict is the disclosure, so hiding it behind a job title is
worse than saying nothing.

The disclosure is provenance, not size. Every number is self-reported from a
single cluster rather than audited or drawn from a customer, and that is what a
reader is owed. It is not a hobby cluster and copy must not imply one: "a
private cluster run by one person" conceded smallness, which is neither true
nor the thing being disclosed. "The numbers are its own" then failed the other
way, because a possessive asserts nothing about who measured. Name the source
and admit it is us. The agent's definition is
public at `jhgaylor/agent-specs`.

**Customers:** GAP. No named customers or logos.

**Testimonials:** GAP. None. The case study's only quote is the agent's own
pull-request text, not a person's.

**Value themes:**

| Theme | Proof |
|---|---|
| The templates outlive the run | `docs/primitives.md`; three templates, one machine |
| The machine is not your problem | Built, warmed, metered, reclaimed; parks and wakes with work intact |
| The credential is separable from the machine | Vault wins on collision; egress broker placeholders |
| A run is addressable | Id, status, transcript, event stream; the case study's webhook |
| Guardrails are mechanisms, not promises | Every limit in the case study is enforced outside the model |
| You own the machine and the keys | Self-hosted; bring your own sandbox provider and model key |

## Goals

**Business goal:** 100 weekly active users by November 2026. It is the one
number the roadmap hangs on, and org/team features stay out of scope until it
lands. Every piece of marketing work is answerable to it. If a piece of work is
not, say so.

**Conversion action:** Register and run a first agent. The secondary action for
readers not ready to sign up is the tour, which is the page that turns a curious
reader into someone who has seen the primitives compose.

**Current metrics:** GAP. Current WAU is not recorded in this repo.

## Changelog
*Newest first. One line per revision: what changed and why.*
- v7 (2026-08-29) — Added a focused, unlisted launch campaign page that leads with the work-only meter, uses current production proof, and sends readers to one conversion action.
- v6 (2026-08-29) — Proof hierarchy pass: lead the aggregate case with median alert-to-verdict time and make the alert and pull-request counts supporting evidence.
- v5 (2026-08-29) — Case-study clarity pass: report alerts rather than incidents, show the full pull-request funnel, and describe the outcome as alert to pull request rather than self-healing.
- v4 (2026-08-29) — Self-hosted clarity pass: lead with ownership, put the ownership decision before installation detail, and frame open-source apps as examples rather than customer proof.
- v3 (2026-08-29) — Homepage clarity pass: lead with coding agents and the work-only meter, put production proof before implementation detail, and remove customer-shaped proof language.
- v1 (2026-08-27) — Initial context, drafted from the repo while working the case study headline. Competitive landscape, customer language, customers, testimonials and current WAU left as explicit GAPs rather than invented.
