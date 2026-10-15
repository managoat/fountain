# Manage resources as YAML

Once you have more than a few agents, environments and vaults, keep them in
YAML under source control and reconcile them with `fountain apply`. This page
covers the manifest format and the secret references that let you commit a
manifest with no plaintext in it. The flags themselves are in the
[CLI reference](../cli.md#apply-manifests).

## The format

A manifest is a YAML file of one or more documents. Each document is one
resource.

```yaml
apiVersion: fountain/v1
kind: Environment        # or Vault, or Agent
metadata:
  name: my-project       # the upsert key
spec:
  # the fields of that kind, as the API names them
```

`metadata.name` is the key for every kind. A resource with that name is
updated; with no such resource, apply creates one. The `spec` fields are the
API's fields for the kind; see [About environments](../concepts/environment.md),
[About vaults](../concepts/vault.md), [About agents](../concepts/agent.md) and
the generated reference at `/api/docs`. An absent `spec` key leaves that field
as it is, and an unknown one is refused for that document.

An example with one of each:

```yaml
---
apiVersion: fountain/v1
kind: Environment
metadata:
  name: my-project
spec:
  packages:
    apt: [jq, ripgrep]
  setup_script: cd /workspace && uv sync
---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: alice
spec:
  description: Alice's credentials
  secrets:
    GITHUB_TOKEN: op://Personal/GitHub/token
---
apiVersion: fountain/v1
kind: Agent
metadata:
  name: researcher
spec:
  runtime: claude
  model: anthropic/claude-sonnet-5
  environment: my-project     # resolved to an environment by name
  system: You are a research assistant.
  mcp_servers:
    everything:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-everything"]
```

## A file or a directory

```bash
fountain apply -f fountain.yml
fountain apply -f ./fountain-specs/
```

Given a directory, the CLI walks it recursively and reads every `.yml` and
`.yaml` file, in alphabetical order. A document that does not carry both
`apiVersion` and `kind` is skipped without a word, so an unrelated YAML file,
such as a CI workflow, can share the tree. A document whose `kind` is not one
of the three stops the run before anything is sent.

The file order does not matter. The server reconciles every environment
first, then every vault, then every agent, so an agent can name an
environment defined later in the file. The name resolves against the
manifest first and then against the environments your account already holds.
A name that matches neither fails that agent's document, and no other.

## What apply prints

One line per resource: `+` for a create, `~` for an update, `=` for a
resource that already matched, `!` for a failure. Inline secrets get a line of
their own under their resource.

```
env  +  my-project
vault  +  alice
  secret  ~  alice/GITHUB_TOKEN
agent  =  researcher
```

A failure on one resource goes to stderr and does not stop the others; the
CLI exits nonzero at the end. Re-applying the same manifest prints `=` on
every resource, because nothing was written. Inline secrets are the
exception: Fountain cannot compare stored ciphertext with the value you gave,
so it encrypts them again on each apply and they keep printing `~`.

Each create or update writes the same audit event as the matching API call,
with the actor and address of the request that ran the apply, and secret
writes are marked `via: apply`. An unchanged resource writes none.

Apply never deletes. A document you remove from the manifest leaves its
record in place; delete the record through the API, the Conversations app, or
`fountain vault delete` for a vault.

## Secret references

Any value under `spec.secrets` of an Environment or a Vault can be a
reference instead of the secret itself. The CLI resolves it on your machine,
at apply time, before it sends the manifest. Fountain never sees your
secret manager's credentials, only the value it returns.

| Reference | Resolved from |
|---|---|
| `${VAR}` | Your shell environment, or `--var VAR=value`. A flag wins over the environment. |
| `op://<vault>/<item>/<field>` | 1Password, with `op read` |
| `bws://<secret-uuid>` | Bitwarden Secrets Manager, with `bws secret get` |
| `infisical://<project?>/<env>/<path?>/<name>` | Infisical, with `infisical secrets get` |

```yaml
kind: Environment
metadata: { name: my-project }
spec:
  secrets:
    GITHUB_TOKEN: ${GH_PAT}
    POSTHOG_API_KEY: op://Work/PostHog/api_key
    NPM_TOKEN: bws://11111111-1111-1111-1111-111111111111
    DATABASE_URL: infisical://abc123/prod/api/DATABASE_URL
    REDIS_URL: infisical:///prod/REDIS_URL
    ANTHROPIC_API_KEY: op://${OP_VAULT}/Anthropic/key
```

```bash
GH_PAT=ghp_... OP_VAULT=Work fountain apply -f fountain.yml
fountain apply -f fountain.yml --var GH_PAT=ghp_... --var OP_VAULT=Work
```

Substitution runs first and the managers second, so a reference can be
built from a variable, as `op://${OP_VAULT}/...` is above. Write `$${VAR}` to
store a literal `${VAR}`, and `$$` for a literal `$`.

### Every failure at once

Each phase collects its failures across the whole manifest, and the CLI stops
before it sends anything, so one run lists everything to fix.

```
apply-time substitution failed — set these in the env or pass --var KEY=VAL:
  my-project: GH_PAT
```

```
apply-time secret resolution failed:
  my-project:
    POSTHOG_API_KEY (op://Work/PostHog/api_key): [ERROR] ... session expired
    NPM_TOKEN (bws://11111111-...): Error: invalid access token
```

An empty value counts as a failure, because it nearly always means the
manager found no secret. If a manager's CLI is not on `PATH`, the message
says where to install it.

### Only `spec.secrets`

Apply-time resolution touches `spec.secrets` and nothing else. A `${VAR}`
elsewhere in a manifest, such as in an agent's `mcp_servers`, goes to the
server as written. Fountain resolves that one when a conversation starts,
against the merged environment and vault secrets. Read
[Hop 4](../concepts/secrets.md#hop-4-substitution-then-the-process). The
syntax is the same; the time and the source differ.

## Set up each manager

Each manager's own CLI does the authenticating. Install it and sign in before
you run `fountain apply`.

### 1Password

Install the [1Password CLI](https://developer.1password.com/docs/cli/get-started).
Run `op signin` for an interactive session; for CI, export a service account
token as `OP_SERVICE_ACCOUNT_TOKEN`.

| Segment | Is |
|---|---|
| `vault` | A vault name or ID, such as `Work` |
| `item` | An item name or ID, such as `PostHog` |
| `field` | A field label or ID, such as `api_key` |

`op item get <item> --vault <vault>` shows an item's fields. An expired
session fails with `op`'s own message; sign in again and re-apply.

### Bitwarden Secrets Manager

This is the Secrets Manager CLI, `bws`, and not the password manager's `bw`.
Install it from the
[Secrets Manager CLI page](https://bitwarden.com/help/secrets-manager-cli/).
Create a machine account with read access to the secrets you need, and export
its access token as `BWS_ACCESS_TOKEN`.

A reference is the secret's UUID, with no hierarchy. `bws secret list` shows
each secret's `id`. `invalid access token` means the token is missing or
expired; `resource not found` means the UUID is wrong or the machine account
cannot read it.

### Infisical

Install the [Infisical CLI](https://infisical.com/docs/cli/overview). Either
run `infisical login` and `infisical init` in the directory you apply from, or
export `INFISICAL_TOKEN` for CI.

```
infisical://<project-id>/<env>/<name>
infisical://<project-id>/<env>/<folder>/<name>
infisical://<project-id>/<env>/<a>/<b>/<name>   # folder /a/b
infisical:///<env>/<name>                       # project from .infisical.json or INFISICAL_PROJECT_ID
```

The last segment is always the secret's name, and the segments between the
environment slug and the name are the folder path. A reference needs at least
an environment and a name. Paths are case-sensitive.

## Where to go next

- [CLI reference](../cli.md#apply-manifests), for the command's flags and the
  server version it needs.
- [Where a secret comes from](../concepts/secrets.md), for what happens to a
  secret after apply stores it.
