# All commands

<!-- GENERATED FILE. Do not edit.

     Rendered from the Cobra command tree by
     cli/internal/cmd/docsgen_test.go. Regenerate with:

         cd cli && go test ./internal/cmd/ -update-cli-docs

     Prose about what a command is for, and which one to reach for, belongs in
     the hand-written index at docs/cli.md. This file is the flag-complete
     description and nothing else. -->

Every command and every flag, generated from the binary. For what to reach for
and why, start at the [CLI guide](../cli.md).

## `fountain acp`

Speak the Agent Client Protocol on stdio (spawned by an editor)

Speak the Agent Client Protocol on stdio.

Not meant to be run by hand: an ACP-capable editor spawns this process and
talks JSON-RPC to it over the pipe. stdout carries the protocol and nothing
else; diagnostics go to stderr.

--agent names the Managoat agent a session runs — the protocol has no field
for it, so it is configured here. Point one editor entry at each agent you
want to reach.

--vault attaches a vault to every conversation this process opens. Vault
values override the agent's environment, so this is where per-entry secrets
belong — an identity the agent posts under, for instance. Two entries pointing
at the same agent with different vaults stay separate; the same secret in a
shared environment would not.

--environment provisions every conversation this process opens from that
environment instead of the agent's own. One agent config can then run under
several environments — one entry per environment — without duplicating the
agent. The vault still wins over it on key collision.

--permission decides what happens before the agent runs a tool. "ask" puts the
question in your editor, as an approval prompt, and the tool waits for your
answer; "auto_deny" refuses; the default, "auto_allow", runs it. Narrow it per
tool with key=verdict pairs — --permission execute=ask asks before shell
commands and allows the rest. Keys match the tool card's title first and then
ACP's kind (execute, edit, read, fetch, …), and a launch may only narrow what
the agent already allows.

Nobody answering is an answer: an unanswered prompt is denied after the
server's timeout, and so is one your editor dismisses or disconnects from. The
turn continues either way.

What it is, and is not: a control surface for a conversation running in a
Managoat sandbox — watch it, steer it, interrupt it. It has no access to the
files open in your editor, and the paths it reports are inside the sandbox,
not on your machine.

```
fountain acp [flags]
```

Options:

```
      --agent string         Managoat agent name or id to open sessions against
      --environment string   environment name or id to provision each session's conversation from, instead of the agent's own
      --log-level string     stderr log level: debug, info, warn, error (default "info")
      --permission string    what happens before the agent runs a tool: auto_allow, ask, auto_deny, or key=verdict pairs (for example "execute=ask")
      --vault string         vault name or id to attach to each session's conversation
```

## `fountain agent list`

List agents

```
fountain agent list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain agent show`

Show an agent

```
fountain agent show <id>
```

## `fountain apply`

Apply resource definitions from a YAML file or directory

```
fountain apply [flags]
```

Options:

```
  -f, --file string       path to YAML file or directory
      --var stringArray   extra variable for ${VAR} substitution (KEY=VAL, repeatable)
```

## `fountain auth login`

Authenticate and save credentials

```
fountain auth login [flags]
```

Options:

```
      --api-key    paste an API key you created in the console
      --device     sign in by approving this device in your browser (the default on a terminal)
      --password   sign in with email + password (the default when stdin is piped)
```

## `fountain auth logout`

Remove saved credentials

```
fountain auth logout
```

## `fountain auth register`

Create an account, wait for the emailed link, and save the key

Creates the account, waits while you click the link in your email, saves the API key, and prints the same first request the manual shows.

```
fountain auth register [flags]
```

Options:

```
      --email string      email address (prompted for when omitted)
      --password string   password (prompted for when omitted, which keeps it out of shell history)
```

## `fountain auth whoami`

Print current user info

```
fountain auth whoami
```

## `fountain conv create`

Create from API-shaped JSON and print the API response

```
fountain conv create --file <path|-> [flags]
```

Options:

```
      --file string   conversation request JSON file, or - for stdin (required)
```

## `fountain conv delete`

Delete a conversation

```
fountain conv delete <id>
```

## `fountain conv interrupt`

Interrupt the running turn

```
fountain conv interrupt <id>
```

## `fountain conv list`

List conversations

```
fountain conv list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain conv prompt`

Send a prompt to a conversation and stream the result

```
fountain conv prompt <id> [flags]
```

Options:

```
      --client-request-id string   caller-provided prompt correlation ID (not an idempotency key)
  -i, --image strings              image file path (repeatable)
  -p, --prompt string              prompt text (required)
```

## `fountain conv show`

Show a conversation

```
fountain conv show <id>
```

## `fountain conv stream`

Stream conversation events

```
fountain conv stream <id>
```

## `fountain conv terminate`

Terminate a conversation

```
fountain conv terminate <id>
```

## `fountain conv wake`

Bring the sandbox up without sending a prompt

```
fountain conv wake <id>
```

## `fountain env list`

List environments

```
fountain env list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain env show`

Show an environment

```
fountain env show <id>
```

## `fountain keys create`

Create a new API key

```
fountain keys create <name>
```

## `fountain keys list`

List API keys

```
fountain keys list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain keys revoke`

Revoke an API key

```
fountain keys revoke <id>
```

## `fountain oauth-client create`

Register an OAuth app

```
fountain oauth-client create <name> [flags]
```

Options:

```
      --json                       output JSON
      --redirect-uri stringArray   where the code is returned to; repeatable
```

## `fountain oauth-client delete`

Unregister an OAuth app

```
fountain oauth-client delete <id>
```

## `fountain oauth-client list`

List OAuth apps

```
fountain oauth-client list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain oauth-client update`

Rename an OAuth app or replace its redirect URIs

```
fountain oauth-client update <id> [flags]
```

Options:

```
      --json                       output JSON
      --name string                new name
      --redirect-uri stringArray   replaces every redirect URI; repeatable
```

## `fountain quickstart`

Run the first request against your default agent and stream the reply

Sends the same prompt the manual shows, to the agent this account already has, and streams the reply. It is `fountain run` with the agent and the prompt filled in.

```
fountain quickstart
```

## `fountain run`

Run an agent (create conversation + stream until done)

```
fountain run <agent-name-or-id> [flags]
```

Options:

```
      --client-request-id string   caller-provided prompt correlation ID (not an idempotency key)
      --environment string         environment name or id to provision from, instead of the agent's own
  -p, --prompt string              prompt text (required)
      --vault string               vault name or id
```

## `fountain sandbox list`

List sandboxes

```
fountain sandbox list [flags]
```

Options:

```
      --json            output JSON
      --status string   comma-separated statuses to include (default: all)
```

## `fountain sandbox show`

Show a sandbox and the conversations on it

```
fountain sandbox show <id>
```

## `fountain vault create`

Create a vault

```
fountain vault create <name> [flags]
```

Options:

```
      --description string   vault description
```

## `fountain vault delete`

Delete a vault

```
fountain vault delete <id-or-name>
```

## `fountain vault delete-secret`

Delete a vault secret

```
fountain vault delete-secret <id-or-name> <key>
```

## `fountain vault list`

List vaults

```
fountain vault list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain vault set-secret`

Set a vault secret

```
fountain vault set-secret <id-or-name> <key> <value>
```

## `fountain vault show`

Show a vault

```
fountain vault show <id-or-name>
```

## Global flags

Accepted by every command.

```
      --profile string   credentials profile name
```
