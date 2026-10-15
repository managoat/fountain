# fountain-contributor

> An agent that contributes to Fountain itself, configured to work the way a
> maintainer's laptop session does.

## Summary

| | |
|---|---|
| Manifest | [`examples/agents/fountain-contributor/`](https://github.com/managoat/fountain/tree/main/examples/agents/fountain-contributor) |
| Runtime | claude, model `anthropic/claude-opus-5` |
| Resources | one Environment, one Vault, one Agent |
| First prompt | about 15 minutes to provision (measured), paid by every new conversation |
| Network policy | `unrestricted` |
| Vault needs | a GitHub token with `repo` scope, and your git identity |

## What it does

It checks out
[managoat/fountain](https://github.com/managoat/fountain), reads
`CLAUDE.md` and the ADRs, makes a change, runs the full local gate, and opens
one pull request with `gh`. Its commits carry a DCO sign-off under your name,
from the vault.

The environment rebuilds a maintainer's machine inside the sandbox. The
pinned Erlang and Elixir toolchain from `.tool-versions`, and Go for the CLI
suite. Postgres, with the dev and test databases. Then `gh`, the dialyzer
PLT, and the docs linters that CI runs.

## What you will need

| | Where it comes from |
|---|---|
| `GITHUB_TOKEN`, `GH_TOKEN` | one GitHub token with `repo` scope |
| `GIT_NAME`, `GIT_EMAIL` | your DCO identity, substituted at apply time |
| a secret manager, or not | The 1Password CLI resolves `op://` refs. Without one, pass `--var`. |

Inference credentials are not part of the manifest. Fountain injects them
from your account. Fountain derives `MASTER_SECRETS_KEY` itself in dev and
test, so the suite runs without it.

## Set it up

1. Apply the manifest.

    ```bash
    fountain apply -f examples/agents/fountain-contributor/manifest.yml \
      --var GIT_NAME="Ada Lovelace" --var GIT_EMAIL="ada@example.com"
    ```

2. Start a conversation with your vault attached.

    ```bash
    fountain run fountain-contributor --vault fountain-contributor-me \
      -p "Read issue #NNN and fix it"
    ```

The `--vault` flag is not optional. The repo clone, `gh`, and the
DCO identity all come from the vault.

## Verify

Ask the agent to run the gate and read what it reports.

```
mix precommit
```

Done means it saw "N tests, 0 failures" in the output, and one pull request
exists on the repository with signed-off commits.

## Limits

**Every new conversation is slow to start.** Each conversation gets a
sandbox of its own, and the setup script builds Erlang from source and the
dialyzer PLT in it. Follow-up prompts in the same conversation reuse that
sandbox and skip the build. Fountain keeps no checkpoint of an environment
to start a new sandbox from, so plan for the full build each time.

**A long conversation works on an aging checkout.** The tree on disk is as
old as the sandbox. The agent's system prompt orders a `git fetch` first, for
exactly this reason.

**The git identity override is not optional.** Fountain gives every sandbox
`AoD <aod@local>` as its git identity, and the DCO check rejects commits
signed off that way. The vault's `GIT_*` values win, on every provider. We
measured this rather than assumed it.

## Related

- [Agents](index.md).
- [About environments](../../concepts/environment.md), where the machine
  comes from.
- [About vaults](../../concepts/vault.md), where your credentials live.
- [claude](../runtimes/claude.md), the runtime it runs on.
