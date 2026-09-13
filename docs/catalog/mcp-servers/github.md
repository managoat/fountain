# github (MCP server)

> GitHub's remote MCP server. It gives an agent tools for the
> repositories, issues, and pull requests an account can reach.

## Summary

| | |
|---|---|
| URL | `https://api.githubcopilot.com/mcp` |
| Authorization server | `github.com/login/oauth`. |
| Client registration | Manual. Discovery fills the endpoints, and you paste a client id from your own GitHub app. |
| Verified | 2026-09-01. Read [what verified means](index.md#what-verified-means). |
| Status | Beta. Only on a deployment that runs the egress broker. Read [Feature status](../../reference/feature-status.md). |

## What you will need

A GitHub account, and an OAuth app of your own. Create one under
**Developer settings** on GitHub, with the redirect URI the provider
shows after discovery.

## Set it up

1. Open **Account, then Connections** in the console.
2. Under **Connect a remote MCP server**, click **GitHub**. The URL above
   appears in the field.
3. Click **Discover**. Fountain finds the endpoints. GitHub offers no
   client registration, and the page says so.
4. Edit the provider. Paste the client id and secret from your app.
5. Click **Connect** and approve on the consent screen.
6. Attach the server to an agent. Read
   [Connect a remote MCP server](../../guides/connect/remote-mcp-server.md).

## Verify

```bash
mix run --no-start scripts/mcp-catalog-probe.exs https://api.githubcopilot.com/mcp
```

The probe walks the discovery chain and prints one `ok` line.

## Limits

GitHub publishes its authorization metadata and offers no RFC 7591
registration. Each tenant supplies an app of their own. Fountain verifies
the authorization chain, and not the tools. The verified date says when
the chain last completed, and nothing more.

## Related

- [MCP servers](index.md), the catalog hub, with
  [what verified means](index.md#what-verified-means).
- [Connect a remote MCP server](../../guides/connect/remote-mcp-server.md),
  the full guide.
