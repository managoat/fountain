# fountain-contributor

An agent that contributes to Managoat itself, set up to do what a
maintainer's laptop session does: the pinned Erlang/Elixir toolchain, Go for
the CLI, Postgres for the suite, `gh` for the pull request, and the docs and
decisions linters CI runs. One file defines all three resources — the
Environment (machine + toolchain), a Vault (your credentials and git
identity), and the Agent (model, runtime, working rules).

## What the vault needs

Two credentials and a git identity, all resolved on **your** machine at apply
time — nothing secret is stored in this file:

| Key | Purpose | Where it comes from |
|---|---|---|
| `GITHUB_TOKEN` | clones the repo (`repositories[].secret_key`) | a token with `repo` scope |
| `GH_TOKEN` | authenticates `gh` for the pull request | same token |
| `GIT_AUTHOR_NAME` / `GIT_COMMITTER_NAME` | commit identity | `${GIT_NAME}` substitution |
| `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_EMAIL` | commit identity | `${GIT_EMAIL}` substitution |

The manifest ships with `${VAR}` references, which `managoat apply`
substitutes from your local environment or from `--var` flags. Keep the token
in a secret manager? Replace the value with a ref like
`op://Private/github/token` (1Password), `bws://...` (Bitwarden) or
`infisical://...`, and the CLI resolves it at apply time instead. Either way,
resolution happens on your machine and the manifest never holds a secret:

```bash
managoat apply -f examples/agents/fountain-contributor/manifest.yml \
  --var GITHUB_TOKEN="$(gh auth token)" \
  --var GIT_NAME="Ada Lovelace" \
  --var GIT_EMAIL="ada@example.com"
```

The git identity is not decoration. Managoat injects `AoD <aod@local>` as the
git author/committer into every sandbox, so without the override every
commit this agent makes is authored by that placeholder. The vault values are appended after the platform
defaults, and **last wins on every provider** — measured on Sprites
(duplicate keys are deduplicated to the last value in the process
environment), and by construction on E2B (map conversion).

## Run it

```bash
managoat apply -f examples/agents/fountain-contributor/manifest.yml
managoat run fountain-contributor --vault fountain-contributor-me \
  -p "Read issue #NNN and fix it"
```

The `--vault` flag matters: the agent's environment has the toolchain, but
the repo clone, `gh`, and the git identity all come from the vault. The
manifest deliberately leaves `allowed_vault_ids` unset — unset means any of
your vaults may attach; an empty list would forbid attaching one at all.

## Launch from Arugula / Illogical

Attach the same vault when opening a contributor pane in the current tab:

```bash
arugula agent --managoat fountain-contributor --vault fountain-contributor-me \
  --split "$ARUGULA_PANE" "Read issue #NNN and investigate it"
```

The agent's permission policy is `auto_allow`. Clients that override that
policy must explicitly request `auto_allow` as well. On Arugula versions
without the per-launch `--permission` flag, the block API accepts
`config.permission: "auto_allow"`; use `config.vault` to attach the vault.
An allowed vault is not automatically attached, and auto approval does not
supply credentials. Verify the created conversation's `vault_id` and
`permission_policy` before assigning a batch of work.

## Check access and evidence first

The agent checks authenticated GitHub access before substantial work. A public
clone or anonymous issue read does not establish that it can publish findings.
If `gh api user --jq .login` fails, check that the contributor vault was attached
and that its credentials are valid. Do not use the Sprites gateway or the
conversation's `MANAGOAT_TOKEN` as GitHub credentials.

For trace investigations, provide the evidence in the issue or pass the actual
artifacts into the sandbox. A workstation path such as `tmp/bootstrap-probes/`
is not shared with the agent. Supply an approved trace-access route when live
queries are required; otherwise the agent should label its analysis as based
on supplied evidence. Missing access is a reported limitation, not proof that
the service is down. Blocked reports are saved outside the checkout and
included in the final response so the caller can publish them.

## What the first run costs

The setup script installs precompiled toolchains, Postgres and `gh`. Erlang
uses the repository pin with `MISE_ERLANG_COMPILE=false`: if mise has no
compatible binary for the sandbox, setup fails rather than compiling OTP.
Use a supported Ubuntu sandbox; see [mise's Erlang support](https://mise.jdx.dev/lang/erlang.html).

Project dependencies, database setup and the Dialyzer PLT are deferred until
a task needs them. The agent still compiles changed project code and runs
its required checks. No startup timing has been measured for this setup.
Each new conversation provisions its own sandbox; follow-ups reuse it.

The agent fetches before starting a task, preserves work on follow-up turns,
and reads the current repository guides to choose its checks.

Inference credentials are **not** part of this manifest: they are per-user
and Managoat injects them from your account's credentials, never from an
Environment. Likewise `MASTER_SECRETS_KEY` is derived automatically in dev
and test, so the suite runs in the sandbox without it.

On Ubuntu 26.04, setup selects the Ubuntu 24.04 Erlang binary explicitly
and checks that Elixir and Erlang crypto load successfully. Source compilation
remains disabled.

## What "done" looks like

Passing checks for the changed components from `CONTRIBUTING.md`, and one
pull request on [managoat/managoat](https://github.com/managoat/managoat)
with commits under your vault's identity. Server work needs `mix precommit`
and relevant tests; `mix precommit` alone does not run the test suite.
The final response names the PR, pushed commit SHA, checks and any blockers.

## Guardrails

Every document in `examples/` is parsed by
`cli/internal/manifest/examples_test.go`, so a manifest that stops parsing —
or a document that loses its `apiVersion`/`kind`/`metadata.name` — fails CI.
