# square (MCP server)

> Square's remote MCP server. It gives an agent tools for the payments
> and catalog in a Square account.

## Summary

| | |
|---|---|
| URL | `https://mcp.squareup.com/sse` |
| Authorization server | Square runs its own. |
| Client registration | Automatic (RFC 7591). You type no client id. |
| Verified | 2026-09-01. Read [what verified means](index.md#what-verified-means). |
| Status | Beta. Only on a deployment that runs the egress broker. Read [Feature status](../../reference/feature-status.md). |

## What you will need

A Square account. The consent screen asks for the rest.

## Set it up

1. Open **Account, then Connections** in the console.
2. Under **Connect a remote MCP server**, click **Square**. The URL above
   appears in the field.
3. Click **Discover**. Fountain finds the authorization server and
   registers a client there.
4. Click **Connect** and approve on the consent screen.
5. Attach the server to an agent. Read
   [Connect a remote MCP server](../../guides/connect/remote-mcp-server.md).

## Verify

```bash
mix run --no-start scripts/mcp-catalog-probe.exs https://mcp.squareup.com/sse
```

The probe walks the discovery chain and prints one `ok` line.

## Limits

Fountain verifies the authorization chain, and not the tools. The tools
are for Square to change, and this page does not list them. The verified
date says when the chain last completed, and nothing more.

## Related

- [MCP servers](index.md), the catalog hub, with
  [what verified means](index.md#what-verified-means).
- [Connect a remote MCP server](../../guides/connect/remote-mcp-server.md),
  the full guide.
