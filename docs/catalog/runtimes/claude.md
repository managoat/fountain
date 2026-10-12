# Run Claude Code as an API

> Anthropic's Claude Code CLI, headless in the sandbox.

Run Claude Code on a sandbox with your repositories, packages and credentials.
Send a prompt over HTTP, follow the transcript, and send the next prompt to
the same conversation. Fountain manages the machine between turns.

To use a chat interface, [open Conversations](https://fountain-conversations.demo.managoat.com/).
To call it from your own code, follow the [quickstart](../../quickstart.md),
then use the agent definition below.

## Summary

| | |
|---|---|
| Provider | `anthropic` |
| Multi-provider | No |
| Transport | ACP, through the pinned `claude-agent-acp` adapter |
| Skills root | `/home/sprite/.claude/skills` |
| skills.sh agent | `claude-code` |
| System prompt | `~/.claude/CLAUDE.md` |
| Credential | An OAuth token or an API key. Read [which one it uses](#which-credential-it-uses). |

## Why you would choose this one

It is the default, and it is the most exercised path. Editor integration, the
permission flow and the block format all grew against it first.

## Set it up

```yaml
apiVersion: fountain.dev/v1
kind: Agent
metadata:
  name: researcher
spec:
  runtime: claude
  model: anthropic/claude-sonnet-5
```

The model must carry the `anthropic/` prefix. Fountain rejects any other
prefix when you save the agent.

Add your credential at `/account/inference-credentials` in the app. An
operator cannot set one for you. Read
[Services Fountain uses](../../integrations/index.md).

## Which credential it uses

Two kinds work. If you hold both, **the OAuth token wins**.

| Credential | Bills |
|---|---|
| Claude Code OAuth token | Your Claude.ai subscription, Pro or Team. |
| Anthropic API key | Metered API usage. |

That preference matters to you and not to Fountain. A subscription you already
pay for is usually the one you want spent.

**Fountain exports exactly one into the sandbox, and never both.** Claude Code
prefers the OAuth path when it sees both, but the variable it picks has
changed between CLI versions. So Fountain chooses one, and it does not let the
CLI decide.

### When an organization disallows the subscription

An Anthropic organization can disable Claude subscription access for Claude
Code. After that, a turn that uses the OAuth token fails with
`oauth_org_not_allowed`.

Fountain recovers. It does not leave you to work it out.

- **With an API key on file**, the conversation moves to that key, and the
  turn fails with a message that says so. Send the prompt again and it runs.
- **Without one**, the turn fails with a message that tells you to add one.

Two details about the recovery matter.

**The turn still fails.** The switch is not a silent retry. The failure and the
fix both sit in the transcript, and not only in a log nobody reads.

**The switch lasts for that conversation, and not forever.** A new
conversation tries the OAuth token again. So an organization policy that
somebody later reverts heals on its own. It does not stay pinned to the
fallback.

## Call it over HTTP

After you apply the agent definition, set `FOUNTAIN_AGENT_ID` to the returned
agent id, `FOUNTAIN_BASE_URL` to your instance URL, and `FOUNTAIN_API_KEY` to
your Fountain account key. The account key is separate from the model credential.

```sh
--8<-- "docs/snippets/first-request.sh"
```

Use the returned conversation id to [follow events and send another prompt](../../api.md).
A self-hosted instance uses the same request at its own base URL.

## Verify

Run a conversation, then ask it what model it is. A turn that reaches output
at all proves the credential, the runtime and the sandbox.

## Limits

**Fountain provisions the MCP servers. It does not pass them for each
session.** An upstream defect in `claude-agent-acp` breaks session-scoped MCP
delivery. So Fountain writes `.mcp.json` into the sandbox and starts the
project servers instead. The effect is the same and the mechanism is
different. That matters when you debug why a raw ACP probe behaves one way and
Fountain behaves another.

## Related

- [About agents](../../concepts/agent.md)
- [`fountain acp`](../../integrations/acp.md)
- [Runtimes](index.md)
