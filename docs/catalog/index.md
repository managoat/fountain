# Catalog

Here are the things you can plug into an agent, and the things Fountain plugs
into.

Each entry has the same shape. Read one and you can skim the rest.

## Choose an agent's parts

| Catalog | An entry is | Count |
|---|---|---|
| [Runtimes](runtimes/index.md) | One coding-agent CLI that a sandbox can run. | 4 |
| [Skills](skills/index.md) | One `SKILL.md` that Fountain writes into the sandbox. | 2 bundled, and any repo on GitHub. |
| [MCP servers](mcp-servers/index.md) | One server that gives the runtime tools. | 3 hosted, 10 verified remote, and any server you declare. |

## Start from a whole agent

[Agents](agents/index.md) is the catalog of ready-to-apply manifests. One
file holds an Environment, a Vault and an Agent, and one `fountain apply -f`
reconciles all three. There is 1 entry, a
[Fountain contributor](agents/fountain-contributor.md).

## Elsewhere in these docs

Two catalogs are older than this section, and they keep their own pages for
now.

**[Sandbox providers](../integrations/sandbox-contract.md).** Where a
conversation's machine comes from. Sprites, E2B, Daytona, or a machine you own
through `fountain runner`.

**[Services Fountain uses](../integrations/index.md).** What an operator
configures. Mail, GitHub OAuth, Sentry.

**[Plug into Fountain](../integrations/clients.md).** What drives Fountain
from outside. Editors, chat surfaces, plugin hosts, relays, and your own code.

## Request an entry

If you want an entry that does not exist, open an issue. The entry template is
`standards/catalog-template.md` in the repository.

For a remote MCP server, run
`mix run --no-start scripts/mcp-catalog-probe.exs <url>` first. A green
probe is the whole bar for the
[verified list](mcp-servers/index.md#what-verified-means). "Supported" as
an opinion was the reason no such list existed for a year.
