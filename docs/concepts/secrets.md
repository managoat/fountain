# Where a secret comes from

This page explains the whole chain, from the key on the server to the string
an agent's process reads. To put a value somewhere, read
[About environments](environment.md) and [About vaults](vault.md). For the
operator side, read
[Back up and restore](../guides/operate/back-up-and-restore.md).

## Four hops

You type a secret into Fountain. Fountain transforms it four times before an
agent sees it.

```
MASTER_SECRETS_KEY          (the platform key, never in the database)
        |  wraps
        v
per-tenant DEK              (one per user, stored wrapped)
        |  encrypts
        v
the stored value            (AES-256-GCM, at rest)
        |  merged at spawn
        v
environment + vault         (vault wins on collision)
        |  ${VAR} substitution
        v
the process environment     (inside the sandbox)
```

Each hop exists for a different reason. To know which hop you look at is
usually the difference between a five-minute problem and an afternoon.

## Hop 1: the master key wraps a key for each tenant

Each tenant has a data encryption key, a DEK. The DEK is what encrypts that
tenant's values.

Fountain does not store the DEK in the clear. It wraps the DEK with AES-256-GCM
under `MASTER_SECRETS_KEY`, then stores it in `user_data_keys.wrapped_key`.

`MASTER_SECRETS_KEY` is a 32-byte binary, base64url-encoded, and you set it at
runtime. **It is deliberately not in the database.** That is the whole point of
the arrangement, and it is also why a database backup on its own is worth
nothing. Read
[Back up and restore](../guides/operate/back-up-and-restore.md).

In dev and test, Fountain derives a deterministic key from a fixed phrase.
Production refuses to boot without a true one.

If the shape feels familiar, HashiCorp Vault uses the same one. The unseal key
wraps the root key, which wraps the keyring, which wraps the data.
That analogy holds here. Almost nothing else about the word "vault" does. Read
[About vaults](vault.md).

## Hop 2: the DEK encrypts the value

The DEK has a short and explicit lifecycle.

1. Generate a DEK at user creation, wrap it, and store it.
2. Load the tenant key at conversation start, then unwrap the DEK.
3. Hold the unwrapped DEK in the conversation process's own state while the
   conversation runs. Pass it to each encrypt and decrypt explicitly.
4. Drop the DEK from that state when the conversation ends.

Fountain passes the DEK explicitly and does not look it up. That makes tenant
isolation a property of the call, and not a convention. A function that needs a
DEK cannot use somebody else's by accident.

From the outside, values are write-only. A list of a vault or an environment
returns keys and timestamps. No endpoint returns a value, to anybody, and the
owner is nobody special.

## Hop 3: environment and vault merge

A conversation starts. At that moment Fountain resolves the full set.

```
environment secrets  --merge-->  vault secrets  -->  the sandbox
                                       ^
                               wins on collision
```

The merge happens once, at spawn. Edit either one afterwards and the edit does
not reach a sandbox that already runs. A brokered secret is the exception.
Before each turn, Fountain reads the environment and the vault again and
gives the broker the new value. A rotated `GITHUB_TOKEN` in a vault works on
the next turn of a conversation that already runs. Inference credentials
have a separate source binding: replacing the selected value requires a new
selection before another turn, even when that value came from a vault. The section
[Bindings, when the broker is on](#bindings-when-the-broker-is-on) says which
secrets the broker holds.

A conversation can name a different environment from its agent's default, and
it can attach a vault. The agent's `allowed_environment_ids` and
`allowed_vault_ids` scope both.

Fountain merges the non-secret `env_vars` from the environment in as well. It
stores those in the clear and returns them in the clear. So the difference
between `env_vars` and `secrets` is about who can read a value back. It is not
about who can use one.

On a deployment with the egress broker on, the sandbox also gets a small set
of variables from the broker. These divide into two halves with opposite
precedence.

The certificate variables (`SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`,
`CARGO_HTTP_CAINFO`, `NODE_EXTRA_CA_CERTS` and `UV_NATIVE_TLS`) are defaults.
An `env_vars` entry or a secret with the same name replaces them. You can
point a tool at a different trust store. That store must hold the broker
root, or the agent cannot reach a brokered host.

The proxy variables (`HTTPS_PROXY`, `HTTP_PROXY`, their lower case twins and
`NO_PROXY`) always win in the environment an agent runs in. The broker is
where Fountain attaches credentials to egress and makes a record of it.

Fountain keeps the four proxy URL names out of `/home/sprite/.env` because
the broker address contains a conversation's session token. This filter
applies to every assignment with one of those names, including your own
`env_vars` or secrets. The process still receives the broker's proxy values.

Inference auth inputs also stay out of that shared file. This includes
`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`,
`GEMINI_API_KEY` and OpenCode's Google alias,
`GOOGLE_GENERATIVE_AI_API_KEY`. The rule applies whether a value comes from a
credential set, the platform, an environment or a vault. The reserved managed
name `CODEX_CHATGPT_ACCESS_TOKEN` is filtered too, including when its value is
a broker placeholder.

Fountain passes auth inputs to each process through its environment. The
`setup_script` receives them too. A later shell cannot recover these values
with `source .env`; use the environment inherited by the script. Filtering
this file does not isolate processes from each other or remove runtime-owned
auth files such as Codex's `auth.json`.

## Credential sets

Your provider keys live in a **credential set**. An account can have no sets
until it creates one or writes its first provider credential. A write through
the original default-credential route creates a set called Default when none
exists. If you create a named set first, that becomes the default instead.
Existing credential rows become Default sets on upgrade.

A set holds up to four values: an Anthropic key, a Claude OAuth token, an
OpenAI key and a Gemini key. Most accounts never need a second set.

Make a second set when you hold a second subscription. A set carries a name
you choose. Exactly one set is the default, and the default is what Fountain
reads unless something names another.

Three rules follow from that.

- The first set you have is the default.
- You cannot delete the default. Promote another set first.
- You cannot demote a set. Promote a different one instead.

An agent names the set its conversations run on. Leave it unset and the agent
runs on the default. A launch can name a different set, and the agent's
`allowed_inference_credential_ids` scopes which one. That list works like
`allowed_vault_ids`: `null` allows any set the account owns, `[]` forbids a
different set, and a list of IDs is an allowlist. The agent's own selection
remains allowed.

A tenant environment or vault secret can override a static credential of the
same kind. Vault wins over environment; supported aliases resolve to the
same kind. Conflicting alias values within one layer are refused. The
runtime then selects the kind it supports: Claude prefers its OAuth token,
while OpenCode's Anthropic provider uses an API key. Billing follows the
resolved source. Managed ChatGPT inputs remain reserved, including static
tokens on the managed path.

Each conversation binds its resolved source, revision, selected set, model,
runtime, environment and vault. Each turn records the source that served it.
A changed default applies to new selections. Wake and resume check the bound
source; a replaced, deleted or unusable source is refused rather than silently
replaced with a different set or platform key. Start a new conversation with
an eligible selection when the existing binding can no longer be used.

An explicit configuration reapply can change the model, environment or vault
while retaining the same credential identity and revision. The configuration
and binding update together; earlier turns keep their recorded sources.
A reapply that would change the credential is refused before either changes.

For a credential supplied through plain environment `env_vars`, the revision
covers the whole map. Any edit to that map invalidates the bound source,
including a change to an unrelated variable. Secret rows have individual
revisions, so this broader check applies only to plain `env_vars`.

The set is not part of sandbox identity, so choosing another set does not
itself create another workspace. This is not unrestricted sharing. Codex
currently shares a mutable auth directory, so admission binds that machine to
one source identity and revision before auth preparation. The binding lasts
for the sandbox's lifetime, including after all its conversations terminate
or are deleted. A different Codex source needs a new sandbox; resetting an
existing sandbox does not clear this binding. An existing machine without a
provable source binding must also be replaced before it can use a new source.
Separate per-peer Codex auth directories and managed user ChatGPT execution
remain unbuilt. Use separate principals when different customers need
isolation.

Set the whole thing up at `/account/inference-credentials`, or over the API
under `/api/account/inference-credential-sets`.

## Hop 4: substitution, then the process

An agent config string takes `${VAR}` interpolation, which Fountain resolves
against the merged map. That is how an MCP server declaration gets a
credential, with no credential written into the agent.

```yaml
mcp_servers:
  github:
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PAT}"
```

Substitution is recursive, so it reaches inside maps and lists. It is also
fail-complete. Fountain reports each absent variable at once, and not one for
each attempt. The alternative is a config you fix one name at a time.

`$$` is a literal `$`.

## What the chain does not do

**No automatic static-key rotation.** Fountain does not replace provider keys
for you. A source check can refuse a changed inference credential, but it does
not renew that credential with its provider.

**No revocation of a live process.** Remove a vault from an agent's allowlist,
and no later conversation can attach it. A sandbox that already runs keeps what
you gave it. By then the value sits in a process environment, on a machine.

**No read audit.** Fountain audits the write, by key and by size, and never by
value. It cannot audit the read, because that read happens in the sandbox.

**No protection against the agent.** The code in that sandbox can read
everything in the merged map. That is why the value is there at all. Scope the
credential. Do not scope the agent.

## Hop 5, a hop back: Fountain scrubs the output

Fountain writes everything a sandbox sends to stdout or stderr into
`log_events`, word for word, and streams it over SSE. That table has none of
the envelope encryption above, and it outlives the conversation.

So an `env`, a `set -x`, a `cat .env` in a setup script, or an agent that
prints its own environment would write plaintext credentials into Postgres.
Fountain removes each known secret value from the output before it stores it.

Two results matter.

**A smoke test that echoes a secret prints `[REDACTED]`.** That is the system
at work. To confirm that a value arrived, ask for a character count instead.

**There is a length floor of 8 bytes.** A sandbox environment holds many short
non-secrets, such as `true`, `1`, a port or a region. To redact those would
turn logs into noise and protect nothing. The case this misses is a short
password that somebody chose on purpose. Do not choose one.

**Only the secrets are scrubbed.** The values that come from a credential go
into the registry: your environment and vault values, the inference credential,
the callback token and the values the broker holds. Fountain's own identifiers
do not. The conversation id, the sandbox id and the sandbox URL stay in the
output, where you can read them.

The values live in a registry that the one log writer reads. Fountain does not
pass them to each caller. The scrubber this replaced ran on the HTTPS clone
path and not on the SSH one. A redaction that each caller must remember is a
redaction that a new caller will one day forget.

## Bindings, when the broker is on

!!! note "Connections"

    Connections and credential binding management also need the `connections`
    feature flag. On your own instance, add `connections` to `FEATURE_FLAGS_ON`
    after configuring the broker and provider apps. Hosted accounts are enrolled
    separately; see [feature status](../reference/feature-status.md).
    The broker is on for every account of a deployment that runs one, and
    the hosted platform runs one. Without a broker, a secret enters the
    sandbox in the clear, and the bindings page and routes are absent. On your own instance, read
    [Feature status](../reference/feature-status.md).

On a hosted account with the egress credential broker on, a secret can have
one or more **bindings**. A binding names a host. By default the broker
replaces the secret's placeholder wherever it appears in a request to that
host. The agent uses the placeholder as it would use the secret, in any
header, in the query or in the path. It never has to know the shape the API
wants. The broker does not rewrite a request body.
Four other shapes are there for an API the agent cannot address itself. A
bearer header. Basic auth with a username of yours, which the client encodes
before it leaves. A header with an optional prefix. Custom headers with
`{{ KEY }}` in them.

A secret with a binding does not enter the sandbox. The agent sees a
placeholder, `__stripe_secret_key__` for `STRIPE_SECRET_KEY`. The broker puts
the real value on each request to the bound host. A secret with no binding
enters the sandbox in the clear. The four hops above describe that path.
`GITHUB_TOKEN` and `GH_TOKEN` have a built-in binding to GitHub. It applies
until you make one of your own. The runtime's inference credential has one
too. `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` go to
`api.anthropic.com`, `OPENAI_API_KEY` to `api.openai.com`, and
`GEMINI_API_KEY` to `generativelanguage.googleapis.com`. The runtime sees a
placeholder that keeps the vendor's prefix, such as
`sk-ant-oat01-__claude_code_oauth_token__`.

After a conversation, `GET /api/conversations/:id/egress` lists what left the
sandbox through the broker. URL paths, queries and fragments are withheld.
The `path` field contains `/[REDACTED]`, including for older rows. A credential
can be part of any path segment, even the first. Each row shows the host, the
binding that matched
and so the credential attached, the status, and the latency. A row for a host
you allowed, but bound no credential to, names no binding. A refused host
shows the refusal. The broker writes a row when the request ends, so a long
stream gets its row at the end of the stream. The latency is the duration of
the whole request, not the time to the first byte. The list stays for `BROKER_LOG_RETENTION_HOURS` after the
conversation ends. The route needs a key with full scope. The token a sandbox
holds cannot read it. Read the
[Conversations section](../api.md#conversations) of the API reference.

You manage bindings on Account, then Credential bindings, or with
`GET /api/secret-bindings` and its siblings, in the
[Secret bindings section](../api.md#secret-bindings) of the API reference.
The page and the routes are only
there when the deployment runs a broker. A binding is about the name of
a secret. So it applies to every environment and vault that holds a secret
of that name.

## Where to go next

- [About environments](environment.md), the baseline half of the merge.
- [About vaults](vault.md), the override half.
- [Back up and restore](../guides/operate/back-up-and-restore.md), because
  hop 1 decides what a backup is worth.
- [Architecture](../architecture.md), for where each piece runs.
