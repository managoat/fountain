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
wraps the root key, which wraps the keyring, which wraps the data. <!-- vale disable-line STE.IngForms -->
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
the next turn of a conversation that already runs. The section
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

The four proxy URL names have one exception, and it is in `/home/sprite/.env`
only. The broker's value for those four carries the conversation's session
token, so Fountain keeps it out of that shared file. Your `env_vars` entry is
then the only assignment left in the file. A `setup_script` that does
`source .env` picks it up for the rest of that script. This does not open a
path out. A brokered sandbox can reach the broker host and no other, so a
different proxy name there costs you your own egress.

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

**No rotation.** Nothing expires a value, and nothing tells an agent that a
value went stale.

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

<!-- vale STE.IngForms = NO -->
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
sandbox through the broker. Each row shows the host, the binding that matched
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
<!-- vale STE.IngForms = YES -->

## Where to go next

- [About environments](environment.md), the baseline half of the merge.
- [About vaults](vault.md), the override half.
- [Back up and restore](../guides/operate/back-up-and-restore.md), because
  hop 1 decides what a backup is worth.
- [Architecture](../architecture.md), for where each piece runs.
