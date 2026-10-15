# Before a tool runs

An agent works in a sandbox. Sooner or later it wants to run a command, edit a
file, or fetch a URL. A **permission policy** says what happens at that moment.

The runtime asks Managoat first. Managoat answers from the policy. The tool
then runs, or it does not. Each runtime decides which tool calls it asks
about: see
[what each runtime can do](#what-each-runtime-can-do).

**A permission policy is not the runtime's own sandbox.** Some runtimes build
one before they ask anything, and a verdict here answers only the requests the
runtime sends. Codex is the one that catches people: it confines its writes and
blocks its network by default, so a tool this policy permits can still fail
inside that sandbox. Codex can ask to go outside it, and an allow verdict here
can grant that request. When a policy has any verdict other than `auto_allow`,
Managoat starts codex in the mode that puts those requests to the policy.
Otherwise codex's own reviewer decides them without asking Managoat. Read
[the sandbox codex builds for itself](../catalog/runtimes/codex.md#the-sandbox-codex-builds-for-itself).

## The three answers

| Verdict | What Managoat does |
|---|---|
| `auto_allow` | It permits the tool. This is the default, and it is what every agent did before the policy existed. |
| `ask` | It holds the request, and a human answers it. Nobody answers in 5 minutes, and Managoat refuses. |
| `auto_deny` | It refuses the tool. It chooses a refusal that the runtime offered, and invents none. |

On claude and gemini, a refusal does not stop the turn. The agent reads that
it has no permission, and it continues. On codex a refusal ends the turn,
because codex offers no other way to refuse: see
[what each runtime can do](#what-each-runtime-can-do).

## Where a policy lives

An agent holds one. Each conversation on that agent runs under it.

A launch can send its own policy, on `POST /api/conversations`, on ACP
`session/new`, or with `managoat acp --permission`. Managoat merges the two,
and keeps the stricter verdict for each key.

**A launch can only narrow.** A launch policy that permits more than the agent
does gets a 422 that names the key. Managoat refuses it, and does not clamp it
quietly. Because of that rule, there is no allowlist beside this field. A
launch cannot reach a permission that the agent does not hold.

## Keys

A policy is a map. Each key names what the tool call is, and each value is a
verdict. The key `default` covers everything else.

```json
{ "default": "auto_allow", "execute": "ask" }
```

Managoat reads the keys in this order.

1. The **title** on the tool card, which is the agent's own words.
2. The **kind**, which is ACP's own short list. It is one of `read`, `edit`,
   `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode` and
   `other`.
3. The key `default`.

**Prefer a kind.** The claude and gemini runtimes put the command itself in the
title, and codex sends no title. A title key therefore matches one command, and
nothing else. A kind means the same thing on each turn, and on each runtime.

## When a human answers

With `ask`, the agent stops and waits. Managoat puts the request on the
conversation stream, as a `permission_request` block. It carries the tool, a
summary, and the runtime's own options.

Anyone with the conversation can answer it. The conversations app shows a
card. An editor over `managoat acp` shows its own approval prompt.
Your own code can answer with
`POST /api/conversations/{id}/requests/{request_id}`.

Some rules keep that safe.

- **The first answer wins.** The other clients see a request that no longer
  waits. No client is a fallback for another.
- **Nobody is also an answer.** A request nobody answers is refused after 5
  minutes, with the rejection the runtime itself offered, the same way an
  `auto_deny` verdict refuses it. That ceiling sits below the idle bound, so a
  request that waits costs a turn and not the sandbox.
- **A request lives as long as its turn.** When the turn ends, any request it
  still holds is refused. A request cannot be answered after its turn is over.
- **An option must come from the runtime.** Managoat refuses an option id that
  the runtime did not offer.
- **The agent cannot answer itself.** The sandbox holds an API token, and
  Managoat refuses that loop by name.

## What each runtime can do

| Runtime | Asks before a tool | Notes |
|---|---|---|
| claude | For most tools | Measured on claude-agent-acp 0.81.2. File edits and shell writes ask. A read-only command inside the workspace, such as `ls` or `git log`, runs without asking, and so does anything a trusted allow rule in the workspace permits. A refused request ends only that tool call. |
| codex | For what its sandbox refuses | Measured on codex-acp 1.10.0. Under a policy with any `ask` or `auto_deny` verdict, Managoat starts codex in its asking mode. A write outside the workspace, network access and an escalation the model requests then ask. Writes inside the workspace, the repositories and the temporary directories run without asking, and so do read-only commands. Under a policy that allows everything, codex's automatic reviewer decides those requests instead, and Managoat is not asked. A refused request ends the whole turn, `cancelled`, because codex offers no option that declines a single call. The turn is recorded `failed`, and the next prompt continues the conversation. See [codex](../catalog/runtimes/codex.md#the-sandbox-codex-builds-for-itself). |
| gemini | Yes | Measured on gemini 0.53 with `gemini-2.5-flash`. Google removed that model for new API keys after this measurement. Its option ids are its own (`proceed_once`, `cancel`), so answer with an id from the request, never a name you know from another runtime. |
| acp | If the command does | Managoat runs the command that the agent names, and the command decides whether to send `session/request_permission`. Managoat assumes that it does, so a policy is accepted and enforced on each request that arrives. A command that never asks gets no protection from a policy, and Managoat has no way to know that in advance. |

## An "always" answer does not always hold

Each runtime that asks offers an option that means "do not ask me again".
Managoat sends the option id, and it keeps no record of the answer. The runtime
decides how long its own grant lasts, and the three runtimes disagree.

| Runtime | How long an "always" answer lasts |
|---|---|
| claude | It writes a rule to a file in the sandbox. The rule holds for later turns. |
| codex | `Allow for Session` lasts the whole sandbox wake (#817). The option that amends the command policy goes to a file, and it holds. |
| acp | The command decides. Managoat sends the option id that the command offered, and keeps no record of the answer. |

Every grant lives inside the sandbox. A new sandbox starts with none of them.

Two limits are open work.

- codex keeps a session grant across turns now. The protocol connection lives
  for the sandbox wake, not one turn, so the grant in the runtime process
  survives (#817). A grant is still lost when the sandbox parks or the
  conversation ends. See
  [#996](https://github.com/managoat/managoat/issues/996).
- claude asks again for a command that writes outside the directory where it
  runs.
  The rule that `Always Allow` writes cannot answer the check that stopped the
  command, so the prompt repeats. This is a defect in the runtime, and the
  report is
  [anthropics/claude-code#88919](https://github.com/anthropics/claude-code/issues/88919).

## What the audit trail keeps

Managoat records a refusal, with the tool and the verdict. It records no
values, and no inputs.

It records no permits. One turn makes many tool calls, and a row for each would
make the trail a copy of the transcript.

## How to set one

- **The API.** `PATCH /api/agents/{id}` with `permission_policy`.
- **A manifest.** `permission_policy` in the Agent's `spec`, with
  [`managoat apply`](../guides/manifests.md).
- **An editor.** `managoat acp --permission ask`, or
  `managoat acp --permission execute=ask`.
