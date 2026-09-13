# fountain-gmail

> Gives an agent a Gmail mailbox that the account owner connected once, and
> gives it no Google token.

## Summary

| | |
|---|---|
| Hosted by | Fountain |
| Declared by | The agent. Its `mcp_servers` names a connection. |
| Injected when | The agent names an active connection, and the deployment runs the egress broker. |
| Endpoint | `POST /api/mcp/gmail/:conversation_id/:connection_id` |
| Auth | The sandbox's own callback token, for that one conversation. |
| Status | Beta. Only on a deployment that runs the egress broker. Read [Feature status](../../reference/feature-status.md). |

## Why it exists in this shape

An agent that reads your mail needs a Google credential. Put one in the
sandbox, and any agent that prints its environment has leaked your mailbox.

So the credential does not go there. **You sign in to Google once**, on the
Connections page of the console, and Fountain keeps the refresh token.
Fountain encrypts it with your tenant key, like a vault secret. The agent reaches the
mailbox through these tools alone. Fountain gets a fresh access token for
each call, on the server. The sandbox never sees one.

This is the shape [fountain-comms](fountain-comms.md) has. When an agent
needs a capability that a credential would grant, serve the capability. Do
not ship the credential.

## Connect an account

1. Open **Account, then Connections** in the console.
2. Click **Connect a Google account** and complete the Google consent screen.
3. Copy the connection id from the page.

The consent asks for `gmail.modify`, which covers read, send, reply and
labels. Google names it a restricted scope. An unverified Google app serves
its test users only, so a self-hosted instance adds each account to the test
users of its Google Cloud project. Read
[`GOOGLE_OAUTH_CLIENT_ID`](../../configuration.md#authentication).

## Attach it to an agent

Name the connection in the agent's `mcp_servers`. The key is the server name
the agent sees, and the value names the connection instead of a command or a
URL.

```json
{
  "mcp_servers": {
    "gmail": { "connection": "3f6c1a2e-2b0e-4f8a-9d5b-7c1e2a9f0b44" }
  }
}
```

At spawn, Fountain rewrites the entry into an HTTP MCP server on this
endpoint, authenticated by the conversation's callback token. The runtime
sees a normal remote server.

## The tools

| Tool | What it does |
|---|---|
| `gmail_search` | Searches the mailbox with Gmail's query syntax, newest first. |
| `gmail_get_thread` | Returns every message in a thread, with the plain text body. |
| `gmail_get_message` | Returns one message in full. |
| `gmail_send` | Sends a new plain text email from the connected account. |
| `gmail_reply` | Answers a message in its thread. Use this for a reply, and not `gmail_send`. |
| `gmail_modify_labels` | Adds or removes labels. Remove `INBOX` to archive. |
| `gmail_list_labels` | Lists the labels and their ids. |

Fountain writes each send to the audit log as `connection.used`, with the
tool name and the number of recipients. The log holds no address, subject or
body.

## Revoke

Click **Revoke** on the Connections page, or call
`DELETE /api/connections/:id`. Fountain tells Google to forget the grant.
The next tool call from an agent that names the connection fails with
`connection revoked`, and not with a 401 from Google. Connect the account
again to replace it.

## Token expiry

A Google access token lasts one hour. Fountain refreshes it on the server
when a tool call finds it near expiry, so a turn does not fail on an expired
token.

## The other way: a brokered token

The same connection also gives a brokered `GOOGLE_ACCESS_TOKEN` to the
sandbox, for an MCP server that you run. The sandbox holds a placeholder,
and the egress broker attaches the real token as a bearer on requests to
`gmail.googleapis.com` and `www.googleapis.com`. Bind that name to a host of
your own on the Credential bindings page, and the broker sends the token
there instead. Fountain uploads a rotated token to the broker at the start
of the next turn. Read [Where a secret comes from](../../concepts/secrets.md).
A provider you define yourself works the same way. Read
[Connections](../connections/index.md).
