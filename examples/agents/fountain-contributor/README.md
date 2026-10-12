# fountain-contributor

An agent that contributes to Fountain itself, set up to do what a
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
| `GIT_AUTHOR_NAME` / `GIT_COMMITTER_NAME` | DCO sign-off identity | `${GIT_NAME}` substitution |
| `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_EMAIL` | DCO sign-off identity | `${GIT_EMAIL}` substitution |

The manifest ships with `${VAR}` references, which `fountain apply`
substitutes from your local environment or from `--var` flags. Keep the token
in a secret manager? Replace the value with a ref like
`op://Private/github/token` (1Password), `bws://...` (Bitwarden) or
`infisical://...`, and the CLI resolves it at apply time instead. Either way,
resolution happens on your machine and the manifest never holds a secret:

```bash
fountain apply -f examples/agents/fountain-contributor/manifest.yml \
  --var GITHUB_TOKEN="$(gh auth token)" \
  --var GH_TOKEN="$(gh auth token)" \
  --var GIT_NAME="Ada Lovelace" \
  --var GIT_EMAIL="ada@example.com"
```

The git identity is not decoration. Fountain injects `AoD <aod@local>` as the
git author/committer into every sandbox, and `git commit -s` signs off with
the committer ident, so without the override the DCO check rejects every
commit this agent makes. The vault values are appended after the platform
defaults, and **last wins on every provider** — measured on Sprites
(duplicate keys are deduplicated to the last value in the process
environment), and by construction on E2B (map conversion) and self-hosted
runners (Go `exec.Cmd` semantics).

## Run it

```bash
fountain apply -f examples/agents/fountain-contributor/manifest.yml
fountain run fountain-contributor --vault fountain-contributor-me \
  -p "Read issue #NNN and fix it"
```

The `--vault` flag matters: the agent's environment has the toolchain, but
the repo clone, `gh`, and the DCO identity all come from the vault. The
manifest deliberately leaves `allowed_vault_ids` unset — unset means any of
your vaults may attach; an empty list would forbid attaching one at all.

## What the first run costs

The setup script builds Erlang/OTP from source (mise honors the repo's
`.tool-versions` pin), compiles the umbrella twice (dev + test), and builds
the dialyzer PLT. Expect **about 15 minutes of provisioning** on the first
conversation, before the agent says anything (measured 15m38s on a Sprites
sandbox, packages through checkpoint).

That cost is paid once. Fountain checkpoints the fully-provisioned sandbox,
and every later conversation warm-starts from the checkpoint in seconds.

Two consequences of the checkpoint worth knowing before you edit anything:

- **Editing any warm-start field invalidates the checkpoint.** A
  one-character change to `setup_script`, `packages`, or `repositories` costs
  the next conversation the full ~15 minute build. Batch your edits.
- **A warm start skips the clone and the setup script entirely.** The
  checkout restored from the checkpoint is as old as the checkpoint. The
  agent's system prompt orders a `git fetch` before reading anything for
  exactly this reason; don't remove that instruction.

Inference credentials are **not** part of this manifest: they are per-user
and Fountain injects them from your account's credentials, never from an
Environment. Likewise `MASTER_SECRETS_KEY` is derived automatically in dev
and test, so the suite runs in the sandbox without it.

## What "done" looks like

A green `mix precommit` in the sandbox — the agent is told to run it in the
foreground and read the output, not the exit code — and one pull request on
[managoat/fountain](https://github.com/managoat/fountain), opened
with `gh`, commits signed off (`git commit -s`) under your vault's identity.
The turn that claims completion names the pushed commit sha and the gate
output it saw: backgrounded work dies when a turn ends (#817), so "I'll push
once the suite passes" pushes nothing.

## Guardrails

Every document in `examples/` is parsed by
`cli/internal/manifest/examples_test.go`, so a manifest that stops parsing —
or a document that loses its `apiVersion`/`kind`/`metadata.name` — fails CI.
