# The four primitives

This page explains what Managoat's four objects are, and why there are four of
them. For the fields on each one, read the [API reference](api.md). To build
something with them, start with the [guided tour](tour.md).

## The problem the four primitives divide up

To run a coding agent on a machine that is not yours, you must decide four
things. Each of the four changes on its own schedule.

What the machine holds changes rarely. Python 3.12, a checkout of your repo, a
setup script. You decide it once for a team, then leave it alone for months.

Which credentials the agent runs with changes constantly. A staging database
URL today, a customer's API key tomorrow, a rotated token an hour from now.

How the agent behaves changes sometimes. Which model, which runtime,
which skills, which MCP servers, and what its system prompt says.

What it does right now changes every few seconds.

Put all four in one object, and each credential rotation edits the machine
image. Each prompt edits the credentials. Managoat divides them into four
objects on purpose, and that division is the product.

| Primitive | Answers | Changes |
|---|---|---|
| [Environment](concepts/environment.md) | what the machine holds | rarely |
| [Vault](concepts/vault.md) | which credentials the run uses | constantly |
| [Agent](concepts/agent.md) | how the agent behaves | sometimes |
| [Conversation](concepts/conversation.md) | what it does now | continuously |

## How they compose

An Agent names an Environment. A Conversation runs an Agent. That Conversation
can name a different Environment, and it can attach a Vault for that one run.

Three of the four are templates. They are rows that you write once and use
many times. The fourth, the Conversation, is a run on a machine. The machine
is the heavy work, and Managoat does it for you.

<figure>
<svg viewBox="0 0 740 336" role="img" aria-label="Three templates, one machine, in three stages. Stage one, write once: Agent, Environment and Vault are rows an account writes and reuses. Stage two, at launch: Managoat builds the machine, merges the Environment's secrets with the Vault's and the Vault wins, and starts the agent's runtime. Stage three, the machine: a sandbox receives its environment and runs exactly one Conversation, with its own transcript. The next turn lands on the same machine, and an idle machine parks until that turn wakes it. A bound secret's real value goes to the egress broker instead, the sandbox gets a placeholder, and the sandbox reaches the internet only through the broker." style="max-width:100%;height:auto">
  <defs>
    <marker id="pr-a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker>
    <marker id="pr-b" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#c98a2b"/></marker>
  </defs>
  <g fill="none" stroke="currentColor" stroke-width="1.4">
    <rect x="14" y="32" width="192" height="50" rx="8" stroke="#8a93a3"/>
    <rect x="14" y="96" width="192" height="50" rx="8" stroke="#8a93a3"/>
    <rect x="14" y="160" width="192" height="50" rx="8" stroke="#8a93a3"/>
    <rect x="252" y="74" width="190" height="94" rx="8" stroke="#2f8fb3" stroke-width="1.8"/>
    <rect x="490" y="32" width="236" height="182" rx="8" stroke="#2f8fb3" stroke-width="1.8"/>
    <rect x="502" y="62" width="212" height="40" rx="6" stroke-dasharray="4 3"/>
    <rect x="502" y="112" width="212" height="48" rx="6"/>
    <rect x="502" y="170" width="212" height="34" rx="6" stroke-dasharray="4 3"/>
    <rect x="490" y="252" width="236" height="50" rx="8" stroke="#c98a2b" stroke-width="1.8" stroke-dasharray="6 4"/>
  </g>
  <g font-family="ui-monospace, Menlo, monospace" fill="currentColor">
    <text x="14" y="20" font-size="10.5" fill="#8a93a3"><tspan font-weight="600">1 · WRITE ONCE</tspan> · reusable rows</text>
    <text x="252" y="20" font-size="10.5" fill="#8a93a3"><tspan font-weight="600">2 · AT LAUNCH</tspan> · one API call</text>
    <text x="490" y="20" font-size="10.5" fill="#8a93a3"><tspan font-weight="600">3 · THE MACHINE</tspan> · one per launch</text>
    <text x="26" y="53" font-size="12.5" font-weight="600">Agent</text>
    <text x="26" y="69" font-size="10" fill="#8a93a3">model, runtime, skills</text>
    <text x="26" y="117" font-size="12.5" font-weight="600">Environment</text>
    <text x="26" y="133" font-size="10" fill="#8a93a3">packages, repos, secrets</text>
    <text x="26" y="181" font-size="12.5" font-weight="600">Vault</text>
    <text x="26" y="197" font-size="10" fill="#8a93a3">secret overrides, per run</text>
    <text x="264" y="96" font-size="12.5" font-weight="600" fill="#2f8fb3">Managoat</text>
    <text x="264" y="116" font-size="10">builds the machine</text>
    <text x="264" y="132" font-size="10">merges secrets, vault wins</text>
    <text x="264" y="148" font-size="10">starts the agent's runtime</text>
    <text x="502" y="52" font-size="12.5" font-weight="600" fill="#2f8fb3">Sandbox</text>
    <text x="510" y="79" font-size="10">env: config + credentials</text>
    <text x="510" y="93" font-size="9" fill="#8a93a3">brokered placeholders, unbound values</text>
    <text x="510" y="131" font-size="10">Conversation</text>
    <text x="510" y="145" font-size="9" fill="#8a93a3">exactly one per sandbox, own transcript</text>
    <text x="510" y="187" font-size="10">the next turn lands on it</text>
    <text x="510" y="199" font-size="9" fill="#8a93a3">idle parks it until the next turn</text>
    <text x="502" y="272" font-size="12.5" font-weight="600" fill="#c98a2b">Egress broker</text>
    <text x="502" y="288" font-size="10" fill="#c98a2b">every sandbox's only way out</text>
    <text x="502" y="320" font-size="10" fill="#8a93a3">→ GitHub, model APIs, yours</text>
  </g>
  <g fill="none" stroke="currentColor" stroke-width="1.4" marker-end="url(#pr-a)">
    <path d="M206,57 C228,57 232,100 250,100"/>
    <path d="M206,121 H250"/>
    <path d="M206,185 C228,185 232,142 250,142"/>
    <path d="M442,121 H486"/>
  </g>
  <g fill="none" stroke="#c98a2b" stroke-width="1.6" marker-end="url(#pr-b)">
    <path d="M347,168 V292 H486"/>
    <path d="M600,214 V248"/>
  </g>
  <g font-family="ui-monospace, Menlo, monospace" font-size="9.5" fill="#8a93a3">
    <text x="447" y="114">spawns</text>
    <text x="356" y="284" fill="#c98a2b">the real values</text>
    <text x="592" y="232" fill="#c98a2b" text-anchor="end">HTTPS_PROXY, the only exit</text>
  </g>
</svg>
<figcaption><b>Three templates, one machine.</b> Agent, Environment and Vault are rows you write once. At launch Managoat builds the sandbox from the Environment, merges the secrets with the Vault winning, and starts the Agent's runtime. Each Conversation has a machine of its own, and its next turn lands on the machine the last one left. An idle machine parks, and the next turn wakes it. The fleet ceiling only refuses a new machine; it reclaims none. A bound secret's real value goes to the egress broker and the sandbox gets a placeholder, such as <code>__github_token__</code>; the sandbox reaches the internet only through the broker, which attaches the value. A secret with no binding enters the sandbox as an environment variable.</figcaption>
</figure>

A Conversation starts. At that moment Managoat merges the Environment's
secrets with the Vault's secrets. **The Vault wins on a key collision.** That
one rule is what makes the division into four usable and not merely tidy.
[About vaults](concepts/vault.md) sets it out.

What happens next depends on the secret. Every sandbox reaches the internet
through the egress broker. A bound secret does not enter the sandbox: the
sandbox gets a placeholder, such as `__github_token__`, and the broker puts the
real value on each request to the bound host. A secret with no binding enters
the sandbox as an environment variable.
[Where a secret comes from](concepts/secrets.md) follows one secret through
both paths.

Why an API for this, when you can run an agent in a sandbox by hand? Because
the templates outlive the run. The machine, the secrets and the agent are
rows you can list, diff, share and launch from code. Because the identity and
the machine are separate, so one Environment can run as you, as a bot user,
or as a customer. And because a run is a thing with an id, a status, a
transcript and an event stream. A webhook, a cron job or another agent can
start one and follow it.

## Substitution

Each string value in an Agent config takes a `${VAR}` reference. Managoat
resolves it from the merged environment and vault secrets at spawn time.

| Syntax | Result |
|---|---|
| `${VAR}` | The value of `VAR` from the merged map |
| `$$` | A literal `$` |

Substitution is recursive, so it works inside maps and lists. It is also
fail-complete. Managoat reports each absent variable at once, and not one for
each attempt.

## What Managoat does not have

There is no fifth primitive. Two things look like one and are not.

A **long-lived agent** is not an object. It is a Conversation that you keep,
by its id or by a `channel_id` of your own.

A **sandbox** is not an object you create. Managoat gives you one when a
Conversation starts, one for each Conversation, and it ends with that
Conversation. You can list sandboxes and read one.
Read [About sandboxes](concepts/sandboxes.md) and the
[Sandboxes section](api.md#sandboxes) of the API reference.

## Where to go next

- **Learn as you build.** The [guided tour](tour.md) uses all four to open a
  pull request, in about forty lines.
- **Understand one primitive.**
  [Environment](concepts/environment.md),
  [Vault](concepts/vault.md),
  [Agent](concepts/agent.md),
  [Conversation](concepts/conversation.md).
- **Understand the machinery.**
  [Where a secret comes from](concepts/secrets.md) follows a value from the
  master key to the process. [About sandboxes](concepts/sandboxes.md) covers
  the machine a run happens on. [Architecture](architecture.md) follows a
  prompt from the API call to the first token.
- **Look something up.** The [API reference](api.md) has each field.
  [Conversation states](reference/conversation-states.md) has the state table.
  The [glossary](reference/glossary.md) has the overloaded words.
