# Agents

An entry here is one ready-to-apply manifest. One file holds an Environment,
a Vault and an Agent, and one `managoat apply -f` reconciles all three.

Every field in a hand-written manifest is a decision. Which runtime, which
model, what a `setup_script` must do, what belongs in an Environment and what
in a Vault. A canned agent makes those decisions for you, in a single file
you can read from top to bottom. The per-person secrets stay out of the file.
They arrive at apply time, from your secret manager or from `--var` flags.

The manifests live in the repository, under
[`examples/agents/`](https://github.com/managoat/fountain/tree/main/examples/agents).
Each folder holds the manifest and a README that covers cost, first-run time
and what the vault needs. CI parses every document, so a broken example fails
the build before it can mislead anyone.

## All 1 agents

| Agent | What it does | Runtime |
|---|---|---|
| [fountain-contributor](fountain-contributor.md) | Contributes to Managoat itself. Full toolchain, a database, the local gate, one pull request. | claude |

## Not here yet

**A docs writer and a triager.** Both need much less machine than the
contributor, and both wait until the shape has proven itself. If you want an
entry that does not exist, open an issue.
