# CLAUDE.md — Contributor Guide

Read by Claude Code and other coding agents at session start, and by people.
It holds the rules that are easy to get wrong, the commands, and links to the
one place each longer procedure lives. Keep it short; the detail belongs in
the files it points at.

| For | Read |
|---|---|
| Workstation setup, toolchain pins | [SETUP.md](SETUP.md) |
| Contribution steps, licensing, checks, flakes, API changes | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Server implementation conventions | [contributing/server.md](contributing/server.md) |
| CI jobs, the merge queue mechanics, coverage, partitions | [scripts/ci/README.md](scripts/ci/README.md) |
| Writing and checking manual pages | [contributing/docs.md](contributing/docs.md) |
| Component libraries (extraction is paused) | [contributing/component-libraries.md](contributing/component-libraries.md) |
| Why things are the way they are | [decisions/index.md](decisions/index.md) |
| Reference templates and GitHub labels | [standards/](standards/) |
| Configuration reference | [docs/configuration.md](docs/configuration.md), `.env.example` |

## Product and goal

What Fountain is, in one paragraph, is the top of [README.md](README.md).
The standing goal since the May-2026 launch is **100 weekly active users by
month 6** (November 2026). Org/team features stay out of scope until that
traction shows; onboarding is the open product decision on the way there
(#1039). This is the only place the goal is written down.

## Working with Review Loop

On a Review Loop PR, read the
[repository skill](.agents/skills/review-loop/SKILL.md) for bot commits, CI
repairs, human decisions and bounded retries. Report outcomes briefly.
`.github/review-loop.yml` and its referenced files remain the policy
authority. The skill is copied unchanged from
[Review Loop Action `9278790`](https://github.com/managoat/review-loop-action/blob/92787907f1b236d471555e3d231443582e46ce12/skills/review-loop/SKILL.md);
review upstream changes before replacing it.

## Commands

```bash
mise install                        # Erlang/OTP 28 + Elixir 1.19.2, from .tool-versions
mix deps.get && mix setup           # dev DB: create + migrate
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
mix test                            # core and every sibling app
mix precommit                       # server checks: static analysis, sobelow, release assemble
mix precommit --full                # server checks plus the whole suite
mix precommit --list                # its stages; `mix precommit credo test` runs a subset
gh pr merge <N> --squash --auto     # queue a reviewed PR; never --admin
```

Choose local checks by the changed component in
[CONTRIBUTING.md](CONTRIBUTING.md#before-you-push). Go, SDK and tooling changes
use their own checks; mixed changes combine the relevant checks.

Run every mix command through the pinned toolchain (activate mise, or
`mise exec -- mix ...`). `mix precommit` refuses a different Elixir.

## Repo layout

```
apps/fountain/             the server (AGPL-3.0): lib/fountain/ contexts, lib/fountain_web/ Phoenix
  test/support/            DataCase, ConnCase, factory.ex
cli/                       the Go CLI module (Apache-2.0); test it from its own directory
sdk/                       the TypeScript client, against one OpenAPI contract (CONTRIBUTING.md)
config/                    config.exs, dev.exs, test.exs, prod.exs, runtime.exs
decisions/                 ADRs, an OKF bundle; start at decisions/index.md
docs/                      the public manual, served at /docs and nowhere else
standards/, contributing/  unpublished contributor material
scripts/                   the gates and the CI helpers (scripts/ci/README.md)
```

The eight `managoat_*` libraries Fountain uses (substitution, oauth, acp,
sandbox, docs, broker, runner, runtimes) are hex packages pinned in
`apps/fountain/mix.exs`, not directories here. What each owns is tabled in
[contributing/component-libraries.md](contributing/component-libraries.md).

## The four primitives

| Primitive | Purpose |
|---|---|
| **Environment** | Baseline set of encrypted env vars + runtime config (packages, repos, scripts) attached to an agent. A conversation may name a different one at launch (`environment_id`, scoped by `agent.allowed_environment_ids`) |
| **Vault** | Free-floating bag of env-var overrides. Vault values **win on key collision** when merged with an environment at sandbox spawn |
| **Agent** | A named, re-runnable agent config: model, runtime, skills, MCP servers, optional environment |
| **Conversation** | A single run of an agent inside a sandbox. Has turns, log events, and a status lifecycle |

## Rules

- Scope every user-facing query by `user_id`; never use `_unsafe_*` as the
  first fetch in a user-facing request.
- Audit mutations in the context, with caller attribution. Never log secret
  values or audit inside a transaction.
- Keep unbuilt behavior explicit in decisions and documentation.
- Check that an issue or PR reference supports its accompanying statement.
- Use the pinned toolchain and focused tests while iterating.

For server changes, read the relevant sections of
[Server conventions](contributing/server.md): tenant ownership, encryption,
audit, UI boundaries, web plumbing and test setup. Read a procedure
when the change touches it; the linked guides are reference material.

## How a change lands

[CONTRIBUTING.md](CONTRIBUTING.md#pull-requests) owns the landing procedure,
changelog requirements and ADR trigger. Use a reviewed PR and the merge queue;
never push directly to `main`, merge with `--admin`, or wait synchronously on
a queued PR. CI administration lives in [scripts/ci/README.md](scripts/ci/README.md).

## Docs and decisions

- For documentation-only changes, use the focused checks in
  [contributing/docs.md](contributing/docs.md); contributor-only Markdown
  needs no Elixir suite.
- `docs/` is published at `/docs` only. A page not in `docs/nav.yml` fails the
  suite, as does a dead internal link or anchor. The structural rules and
  writing guidance are in [contributing/docs.md](contributing/docs.md).
- Architecturally significant choices are ADRs in `decisions/`, an OKF
  bundle: copy `decisions/0001-template.md`, then run
  `scripts/decisions-index.sh` and `okf validate decisions` in the same PR.
  `okf backlinks decisions <id>` lists what depends on one before amending it.
