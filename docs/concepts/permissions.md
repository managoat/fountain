# Before a tool runs

An agent works in a sandbox. Sooner or later it wants to run a command, edit a
file, or fetch a URL. A **permission policy** says what happens at that moment.

The runtime asks Fountain first. Fountain answers from the policy. The tool
then runs, or it does not.

**A permission policy is not the runtime's own sandbox.** Some runtimes build
one before they ask anything, and a verdict here answers only the requests the
runtime sends. Codex is the one that catches people: it confines its writes and
blocks its network by default, so a tool this policy permits can still fail
inside that sandbox. Codex can ask to go outside it, and an allow verdict here
can grant that request. Codex's own reviewer can also decide a request without
asking Fountain. The setting that removes that sandbox also stops codex asking,
so this policy then sees none of codex's own commands or file edits. Read
[the sandbox codex builds for itself](../catalog/runtimes/codex.md#the-sandbox-codex-builds-for-itself).

## The three answers

| Verdict | What Fountain does |
|---|---|
| `auto_allow` | It permits the tool. This is the default, and it is what every agent did before the policy existed. |
| `ask` | It holds the request, and a human answers it. Nobody answers in 5 minutes, and Fountain refuses. |
| `auto_deny` | It refuses the tool. It chooses a refusal that the runtime offered, and invents none. |

A refusal does not stop the turn. The agent reads that it has no permission,
and it continues.

## Where a policy lives

An agent holds one. Each conversation on that agent runs under it.

A launch can send its own policy, on `POST /api/conversations`, on ACP
`session/new`, or with `fountain acp --permission`. Fountain merges the two,
and keeps the stricter verdict for each key.

**A launch can only narrow.** A launch policy that permits more than the agent
does gets a 422 that names the key. Fountain refuses it, and does not clamp it
quietly. Because of that rule, there is no allowlist beside this field. A
launch cannot reach a permission that the agent does not hold.

## Keys

A policy is a map. Each key names what the tool call is, and each value is a
verdict. The key `default` covers everything else.

```json
{ "default": "auto_allow", "execute": "ask" }
```

Fountain reads the keys in this order.

1. The **title** on the tool card, which is the agent's own words.
2. The **kind**, which is ACP's own short list. It is one of `read`, `edit`,
   `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode` and
   `other`.
3. The key `default`.

**Prefer a kind.** The claude and gemini runtimes put the command itself in the
title, and codex sends no title. A title key therefore matches one command, and
nothing else. A kind means the same thing on each turn, and on each runtime.

## When a human answers

With `ask`, the agent stops and waits. Fountain puts the request on the
conversation stream, as a `permission_request` block. It carries the tool, a
summary, and the runtime's own options.

Anyone with the conversation can answer it. The team app and the conversations
app show a card. An editor over `fountain acp` shows its own approval prompt.
Your own code can answer with
`POST /api/conversations/{id}/requests/{request_id}`.

Some rules keep that safe.

- **The first answer wins.** The other clients see a request that no longer
  waits. No client is a fallback for another.
- **Nobody is also an answer.** Two timeouts do this, and which one applies
  depends on whether the request is still inside a turn. A request held inside
  a turn is refused after 5 minutes. That ceiling sits below the idle bound, so
  a request that waits costs a turn and not the sandbox. A request that
  outlived its turn is refused at its own deadline, which may be days away.
  See [Requests that outlive a turn](#requests-that-outlive-a-turn).
- **An option must come from the runtime.** Fountain refuses an option id that
  the runtime did not offer.
- **The agent cannot answer itself.** The sandbox holds an API token, and
  Fountain refuses that loop by name.

## Requests that outlive a turn

The 5 minute ceiling above assumes an agent blocked mid-thought. Some waits are
longer than that. Approve a production apply, confirm a DNS delegation landed,
sign off the deletes in a plan. Those take hours or days, and nothing in the
sandbox has to run while they do.

An agent can say so. It sends `session/request_permission`, and then it answers
`session/prompt` with the stop reason `waiting`. The turn ends as a completed
turn with `waiting: true` on it. The request stays open. The conversation goes
idle, and the sandbox suspends on the idle bound like any other idle sandbox.

The card stays up. `GET /api/conversations/{id}` lists every such request under
`pending_requests`, with the tool, the options the agent offered, and the
deadline. The `turn` stage event that ended the turn carries `waiting: true`
and the request id, so a client watching the stream learns it there too.

A `waiting` stop reason with no open request means nothing. That turn ends the
way any completed turn does.

### Answering one

Answer it at `POST /api/conversations/{id}/requests/{request_id}`, the same
door an in-turn request uses. The rules above still hold. The first answer
wins, the option must come from the runtime, and the agent cannot answer
itself.

What happens next is different. The connection that raised the request is gone,
so Fountain cannot hand the answer back down it. Instead Fountain resolves the
request and opens a **new turn** whose prompt carries the outcome. Opening that
turn wakes the sandbox.

With `CREDITS_ENABLED=true`, this resume turn is billable on a platform-paid sandbox
provider at the normal `CREDIT_TURN_HOUR_CENTS` rate. The expiry sweep opens the
same billable turn when nobody answers before the deadline. The detached wait
itself adds no turn time. Each later detached approval adds another resume
turn. See [Prices](../guides/operate/plans-and-prices.md).

The prompt is one line of JSON and nothing else. It is broken up here to read
it.

```json
{"fountain/permission_answer":{
  "request_id": "7.1f0c9a",
  "tool": "Bash",
  "outcome": "answered",
  "option_id": "allow",
  "answered_at": "2026-09-07T09:14:02.113Z"
}}
```

`outcome` is `answered` or `timeout`. `option_id` is the option somebody
picked, or the rejection the expiry chose from the agent's own list. It is null
where the agent offered no rejection at all. The agent decides what to do with
it.

The turn's `origin` is `user`, like any other prompted turn. A client that
wants to render this as a system event and not as something a person typed can
tell it by the prompt itself, which is one JSON object whose only key is
`fountain/permission_answer`.

The connection the request was raised on is closed when the turn ends
`waiting`, so the resume turn starts a fresh one. The old peer is still holding
that request, and the runtimes number their requests from 0 on each turn, so
keeping it would make the resume turn's first request collide with the one it
still holds.

An answer is refused, and the request left where it is, when the conversation
cannot take the turn that carries it. A turn of its own is running, the account
is suspended, or the balance is spent. Answer again once that is fixed. The
expiry sweep does the same, and comes back a minute later.

### The deadline

A detached request is refused when its deadline passes, and the refusal opens
the same resume turn with `outcome: "timeout"`. Fountain reads the deadline
from the first of these that is set.

1. `_meta.fountain.timeout` on the `session/request_permission` itself, in
  seconds. The agent sets this per request.
2. `ask_timeout` in the permission policy, in seconds. This is the one policy
  key that names no tool.
3. The 5 minute ceiling, which is what an in-turn request gets.

Where the request and the policy both name one, the **shorter** wins. The
request is written inside the sandbox and the policy belongs to the tenant, so
an agent can bound its own wait and cannot extend the tenant's.

An `ask_timeout` cannot be longer than a year. Fountain refuses a longer one
when you save the agent or when you start the conversation. A database
timestamp cannot hold a longer deadline. This is not a limit on how long a
wait is useful. A per-request `_meta.fountain.timeout` above the same limit
falls back to the policy, or to the 5 minute ceiling.

A launch policy may shorten the agent's `ask_timeout` and may not lengthen it.
Where the agent named none, the 5 minute ceiling is what a launch may only
shorten. A longer wait is more time for somebody to approve the tool, so
longer is looser.

Only a detached request reads the first two. A request inside a turn always
gets the 5 minute ceiling, because the turn holding it keeps the sandbox from
parking.

The deadline is stored on the turn, not in a timer, so it survives the sandbox
suspending and the server restarting. A sweep every minute is what fires it.

## What each runtime can do

| Runtime | Asks before a tool | Notes |
|---|---|---|
| claude | Yes | Measured on claude-agent-acp 0.66. Safe commands that its own sandbox runs never reach Fountain. |
| codex | Yes | Measured on codex-acp 1.1.14. |
| opencode | **No** | It decides this in its own server, and sends nothing. Fountain refuses a policy stricter than `auto_allow` on this runtime, with 422 `permission_policy_unenforceable` ([#959](https://github.com/managoat/fountain/issues/959)). |
| gemini | Yes | Measured on gemini 0.53 with `gemini-2.5-flash`. Google removed that model for new API keys after this measurement. Its option ids are its own (`proceed_once`, `cancel`), so answer with an id from the request, never a name you know from another runtime. |
| acp | If the command does | Fountain runs the command that the agent names, and the command decides whether to send `session/request_permission`. Fountain assumes that it does, so a policy is accepted and enforced on each request that arrives. A command that never asks gets no protection from a policy, and Fountain has no way to know that in advance. |

## An "always" answer does not always hold

Each runtime that asks offers an option that means "do not ask me again".
Fountain sends the option id, and it keeps no record of the answer. The runtime
decides how long its own grant lasts, and the three runtimes disagree.

| Runtime | How long an "always" answer lasts |
|---|---|
| claude | It writes a rule to a file in the sandbox. The rule holds for later turns. |
| codex | `Allow for Session` lasts the whole sandbox wake (#817). The option that amends the command policy goes to a file, and it holds. |
| opencode | This runtime never asks, so it grants nothing. |
| acp | The command decides. Fountain sends the option id that the command offered, and keeps no record of the answer. |

Every grant lives inside the sandbox. A new sandbox starts with none of them.

Two limits are open work.

- codex keeps a session grant across turns now. The protocol connection lives
  for the sandbox wake, not one turn, so the grant in the runtime process
  survives (#817). A grant is still lost when the sandbox parks or the
  conversation ends. See
  [#996](https://github.com/managoat/fountain/issues/996).
- claude asks again for a command that writes outside the directory where it
  runs.
  The rule that `Always Allow` writes cannot answer the check that stopped the
  command, so the prompt repeats. This is a defect in the runtime, and the
  report is
  [anthropics/claude-code#88919](https://github.com/anthropics/claude-code/issues/88919).

## What the audit trail keeps

Fountain records a refusal, with the tool and the verdict. It records no
values, and no inputs.

It records no permits. One turn makes many tool calls, and a row for each would
make the trail a copy of the transcript.

## How to set one

- **The console.** Open the agent, and use *Before the agent runs a tool*.
- **The API.** `PATCH /api/agents/{id}` with `permission_policy`.
- **An editor.** `fountain acp --permission ask`, or
  `fountain acp --permission execute=ask`.
