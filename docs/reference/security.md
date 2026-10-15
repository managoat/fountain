# Security answers

This page answers the questions a security reviewer asks about a Managoat
instance. Each answer names the mechanism, and each limit sits next to the
answer it limits. The concept pages linked from each answer have the detail.

## Where credentials live, and who can read them

An [Environment](../concepts/environment.md) holds a machine's variables, and
a [Vault](../concepts/vault.md) holds a small set of overrides for a run. Both
keep secrets apart from plain `env_vars`. Managoat encrypts each secret with
AES-256-GCM under a random key of the owner's account. It wraps that key under
the instance's `MASTER_SECRETS_KEY`, which is never stored in the database.
Read [Where a secret comes from](../concepts/secrets.md) for the whole chain.

Secret values are write-only. A list returns keys and timestamps, and no
endpoint returns a value.

**The limits.**

- Plain `env_vars` are stored and returned as written. Put a credential in
  `secrets`, never in `env_vars`.
- An operator who holds both the master key and the database can decrypt any
  account's secrets. Encryption at rest protects a stolen database or backup.
  It does not protect you from the person who runs the instance.

When an account is deleted, its key goes with it, so what stays in the
database cannot be decrypted. That does not reach a backup taken before the
deletion. That backup holds both the ciphertext and the wrapped key until your
backup retention removes it.
[Erase an account](../guides/operate/back-up-and-restore.md#erase-an-account)
has the detail.

## Whether the model sees a secret

No mechanism puts a secret into the prompt, the system prompt or the model's
context. Secrets merge into the sandbox's process environment when the sandbox
starts. They reach an agent's MCP server configuration through `${VAR}`
substitution. That substitution happens on the server, and applies only to
`mcp_servers`.

**The limit.** The code in the sandbox can read its own environment, and that
is why the value is there. If an agent prints a value, the value is now in its
context. The next answer covers what happens to that output.

## What ends up in the conversation's log

Managoat stores everything a sandbox writes to stdout or stderr as the
conversation's log events, and streams it live. Before it stores or streams a
line, it replaces each registered secret value with `[REDACTED]`. Managoat
registers these values for every conversation:

- the environment and vault secrets;
- the inference credential;
- the callback token;
- the values the broker holds.

Managoat also catches a value that output splits across two chunks, and the
JSON-escaped form of each value.
[Hop 5](../concepts/secrets.md#hop-5-a-hop-back-managoat-scrubs-the-output)
describes the scrubber.

**The limits.**

- The match is on bytes. A value the agent re-encodes in another way (base64
  or URL encoding, for example) is not caught.
- A value shorter than 8 bytes is not redacted. That floor keeps short
  non-secrets like `true` or a port number readable. Do not choose a short
  password.

## Whether one account can reach another's data

Every user-facing query is scoped by the owner's account. The few internal
reads that are not scoped carry an `_unsafe_` prefix, and a Credo check
requires an ownership note at each call. One search finds them all. A
cross-tenant isolation suite in CI asserts that another account's resources
answer 404.

Every sandbox belongs to one conversation, and Managoat destroys it when that
conversation ends. A second conversation cannot attach to it. Read
[One machine per conversation](../concepts/sandboxes.md#one-machine-per-conversation).

## What is recorded when something changes, and for how long

Managoat writes the audit event where the change happens, not where the request
arrived. So the console, the API and a background worker all follow one rule.
An update records the names of the fields that changed, never their values. A
secret event records the secret's key. An inference credential event records
the provider. Read your own trail at `GET /api/audit`. Filter it by action
prefix, by resource type, or by a `since` and `until` window.

A daily job deletes rows older than these windows:

| What | Kept |
|---|---|
| Conversation log events | 90 days |
| Audit events | 365 days |
| Usage events | 400 days |
| Revoked API keys | 30 days |
| Admin actions (`admin.*` audit events) | No limit. The record of what admins did is never pruned. |

**The limit.** The windows are not environment variables. To change one, set
`config :fountain, :retention_days` in your own build. A value of `nil` turns
pruning off for that table.

## Whether an agent can do something nobody approved

Set an agent's permission policy to `ask`. The agent's tool call then waits for
a human before it runs. If nobody answers in 5 minutes, Managoat refuses it.
Read [Before a tool runs](../concepts/permissions.md).

A stronger pattern is to put the final gate where the agent cannot reach it,
such as a protected branch that needs another account's review. Then refusing
the change is somebody else's job, not the model's.

**The limits.**

- `ask` is not the default.
- It does not cover every action. The runtime decides which tool calls it asks
  Managoat about, and a policy answers only those.

## Whether an agent can start agents without end

An agent can start another agent, and the one it starts can do the same from
inside its own sandbox. Managoat counts how deep each chain goes and refuses a
start past `CONVERSATION_MAX_DEPTH` (default 5) with
`422 conversation_depth_exceeded`, naming the depth. The count follows the
sandbox's own token, so an agent cannot reset it by leaving out the parent
header. Read [Spawn depth](../api.md#spawn-depth).

**The limits.**

- Nothing caps fan-out. An agent can start many conversations one level down,
  and each of those can do the same until the ceiling. The fleet ceiling
  (`SANDBOX_FLEET_CEILING`) bounds how many sandboxes run at once across the
  deployment.
- A sandbox that holds the owner's own full-scope key, from an environment or
  a vault, and starts a conversation with it without the parent header is
  counted as a start from outside, at depth 0.

## Whether a credential can stay out of the sandbox

The egress broker keeps a bound credential out of the sandbox. The sandbox
holds a placeholder, and the broker attaches the real value on the way out.

**The limits.**

- The broker is off until the operator sets `BROKER_LISTEN_PORT` and
  `BROKER_PROXY_URL`.
- When it is on, it applies to every account on the deployment. It covers only
  secrets that have a binding. The built-in bindings cover the GitHub token and
  the inference keys.
- A secret with no binding still enters the sandbox as plain text, and so does
  every secret on an instance without the broker.

Read
[Bindings, when the broker is on](../concepts/secrets.md#bindings-when-the-broker-is-on).

## Whether any of this can stay inside our network

Partly. On an instance of your own, the control plane, the transcripts, the
audit trail and the encrypted secrets live in your deployment and your
Postgres.

**The limit.** Sandboxes run at a hosted provider, Sprites or E2B. Managoat no
longer runs agents on hardware you own. So the repositories and credentials a
run uses reach that provider. Read [Self-host Managoat](../self-hosting.md).

## What it does not have

- **No organizations and no seats.** An account is one person. A team either
  shares one account or runs an instance of its own.
- **No SAML or OIDC single sign-on.** Sign-in is a password, or the optional
  [GitHub login](../integrations/github-oauth.md).
- **No independent penetration test.** The security work is what is in the
  repository, and you can read all of it.
