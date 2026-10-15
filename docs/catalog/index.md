# Catalog

Here are the things you can plug into an agent, and the things Managoat plugs
into.

Each entry has the same shape. Read one and you can skim the rest.

## Choose an agent's parts

| Catalog | An entry is | Count |
|---|---|---|
| [Runtimes](runtimes/index.md) | One coding-agent CLI that a sandbox can run. | 4 |
| [Skills](skills/index.md) | One `SKILL.md` that Managoat writes into the sandbox. | 2 bundled, and any repo on GitHub. |
| [MCP servers](mcp-servers/index.md) | One server that gives the runtime tools. | 1 hosted, and any server you declare. |

## Start from a whole agent

[Agents](agents/index.md) is the catalog of ready-to-apply manifests. One
file holds an Environment, a Vault and an Agent, and one `managoat apply -f`
reconciles all three. There is 1 entry, a
[Managoat contributor](agents/fountain-contributor.md).

## Elsewhere in these docs

Two catalogs are older than this section, and they keep their own pages for
now.

**[Sandbox providers](../integrations/sandbox-contract.md).** Where a
conversation's machine comes from. Sprites or E2B.

**[Services Managoat uses](../integrations/index.md).** What an operator
configures. Mail, GitHub OAuth, Sentry.

**[Ways to drive Managoat](../integrations/clients.md).** What drives Managoat
from outside. Editors, chat surfaces, plugin hosts, relays, and your own code.

## Request an entry

If you want an entry that does not exist, open an issue.

To write one, copy the shape of an existing entry in the same catalog. Every
entry has these sections, in this order:

| Section | What it says |
|---|---|
| `# <Name>` | The thing's own name, then one sentence on what it is. |
| `## Summary` | What it does and where it comes from, in a few lines. |
| `## Why you would choose this one` | When to pick it over the others in its catalog. Optional. |
| `## What you will need` | Accounts, keys and versions, before you start. |
| `## Set it up` | The manifest or the steps, ready to copy. |
| `## Verify` | One check that shows it works. |
| `## Limits` | What it does not do, with an issue link for each known gap. |
| `## Related` | Links to the concepts and guides it touches. |

Add the entry's row to its catalog's index page, and add the page to
`docs/nav.yml`.
