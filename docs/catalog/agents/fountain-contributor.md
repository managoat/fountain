# fountain-contributor

> An agent that contributes to Managoat itself, configured to work the way a
> maintainer's laptop session does.

## Summary

| | |
|---|---|
| Manifest | [`examples/agents/fountain-contributor/`](https://github.com/managoat/managoat/tree/main/examples/agents/fountain-contributor) |
| Runtime | claude, model `anthropic/claude-opus-5` |
| Resources | one Environment, one Vault, one Agent |
| First prompt | binary toolchain setup per new conversation; timing not measured |
| Network policy | `unrestricted` |
| Vault needs | a GitHub token with `repo` scope, and your git identity |

## What it does

It checks out
[managoat/managoat](https://github.com/managoat/managoat), reads
`CLAUDE.md` and the ADRs, makes a change, runs the checks for the changed components, and opens
one pull request with `gh`. Its commits carry your name as author, from the
vault.

The environment rebuilds a maintainer's machine inside the sandbox. The
pinned Erlang and Elixir toolchain from `.tool-versions`, and Go for the CLI
suite. Postgres and `gh` are installed at setup. Project dependencies, dev/test
databases, the Dialyzer PLT and docs tools are prepared only when needed.

## What you will need

| | Where it comes from |
|---|---|
| `GITHUB_TOKEN`, `GH_TOKEN` | one GitHub token with `repo` scope |
| `GIT_NAME`, `GIT_EMAIL` | your git identity, substituted at apply time |
| a secret manager, or not | The 1Password CLI resolves `op://` refs. Without one, pass `--var`. |

Inference credentials are not part of the manifest. Managoat injects them
from your account. Managoat derives `MASTER_SECRETS_KEY` itself in dev and
test, so the suite runs without it.

## Set it up

1. Apply the manifest.

    ```bash
    managoat apply -f examples/agents/fountain-contributor/manifest.yml \
      --var GIT_NAME="Ada Lovelace" --var GIT_EMAIL="ada@example.com"
    ```

2. Start a conversation with your vault attached.

    ```bash
    managoat run fountain-contributor --vault fountain-contributor-me \
      -p "Read issue #NNN and fix it"
    ```

The `--vault` flag is not optional. The repo clone, `gh`, and the
git identity all come from the vault.

## Verify

Ask the agent to run the checks in `CONTRIBUTING.md` for the changed components.
For server work, this includes the gate and relevant tests.

```bash
mise exec -- mix precommit
```

Done means the required checks passed and one pull request exists with
commits under your name. `mix precommit` does not run the suite by default.

## Limits

**Each conversation provisions a fresh sandbox.** Setup requires a compatible
precompiled Erlang release for the repository pin. It fails if none exists;
there is no source-build fallback. See [mise's supported platforms](https://mise.jdx.dev/lang/erlang.html).
Project compilation and checks still take time when a task needs them.
Follow-up prompts reuse the sandbox, but new conversations have no checkpoint.

**A long conversation works on an aging checkout.** The agent fetches before
starting work and preserves the task branch and local changes on follow-ups.

**The git identity override is not optional.** Managoat gives every sandbox
`AoD <aod@local>` as its git identity, so without it every commit is
authored by that placeholder. The vault's `GIT_*` values win, on every
provider. We
measured this rather than assumed it.

On Ubuntu 26.04, setup selects the Ubuntu 24.04 Erlang binary explicitly
and checks that Elixir and Erlang crypto load successfully. Source compilation
remains disabled.

## Related

- [Agents](index.md).
- [About environments](../../concepts/environment.md), where the machine
  comes from.
- [About vaults](../../concepts/vault.md), where your credentials live.
- [claude](../runtimes/claude.md), the runtime it runs on.
