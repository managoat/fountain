# Secrets managers

`fountain apply` resolves secret values at apply time — before writing anything to the database — so you can commit `fountain.yml` without embedding credentials.

Any value under `spec.secrets` can be a URI reference. The resolver for each scheme runs on the operator's machine using its own CLI and credentials. Fountain never sees your vault password or access token.

## URI schemes

| Scheme | Format | Auth |
|--------|--------|------|
| `op://` | `op://<vault>/<item>/<field>` | `op` session / biometric |
| `bws://` | `bws://<secret-uuid>` | `BWS_ACCESS_TOKEN` env var |
| `infisical://` | `infisical://<project?>/<env>/<path?>/<name>` | `INFISICAL_TOKEN` or `infisical login` |
| `${VAR}` | `${MY_ENV_VAR}` | operator shell / `--var` flag |

## Composing references

`${VAR}` substitution runs first, so you can build dynamic URIs:

```yaml
secrets:
  ANTHROPIC_API_KEY: op://${OP_VAULT}/Anthropic/key   # ${OP_VAULT} → substituted, then op resolves
```

Use `$${VAR}` to write a literal `${VAR}` (escapes the substitution).

## Example manifest

```yaml
---
apiVersion: fountain/v1
kind: Environment
metadata:
  name: my-project
spec:
  secrets:
    GITHUB_TOKEN: ${GH_PAT}                                 # from $GH_PAT in shell
    POSTHOG_API_KEY: op://Work/PostHog/api_key              # 1Password
    NPM_TOKEN: bws://11111111-1111-1111-1111-111111111111   # Bitwarden Secrets Manager
    DATABASE_URL: infisical://abc123/prod/api/DATABASE_URL  # Infisical (explicit project)
    REDIS_URL: infisical:///prod/REDIS_URL                  # Infisical (workspace project)
---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: alice
spec:
  secrets:
    GITHUB_TOKEN: op://Personal/GitHub/token
```

Run:

```bash
GH_PAT=ghp_... ./fountain apply -f fountain.yml
# or: ./fountain apply -f fountain.yml --var GH_PAT=ghp_...
```

## Failure output

Both resolution phases collect all failures before aborting, so you fix everything in one pass:

```
apply-time substitution failed — set these in the env or pass --var KEY=VAL:
  my-project: GH_PAT

apply-time secret resolution failed:
  my-project:
    POSTHOG_API_KEY (op://Work/PostHog/api_key): [ERROR] ... session expired
    NPM_TOKEN (bws://be8e0ad8-...): Error: invalid access token
```

## Scope

Apply-time resolution is scoped to `spec.secrets` only. Other manifest fields (agent system prompts, `mcp_servers` command args, etc.) use the provision-time substitution layer — same `${VAR}` syntax, different scope.

## 1Password (`op://`)

Use the 1Password CLI to resolve secret references at `fountain apply` time. Fountain calls `op read` on your machine — it never sees your 1Password credentials or master password.

### Prerequisites

- A 1Password account (individual, Teams, or Business).
- The `op` CLI installed: https://developer.1password.com/docs/cli/get-started

```bash
# macOS
brew install 1password-cli

# Linux (example — see install page for your distro)
curl -sSfLo op.zip https://cache.agilebits.com/dist/1P/op2/pkg/v2.x.x/op_linux_amd64_v2.x.x.zip
unzip -o op.zip && sudo mv op /usr/local/bin/
```

### Auth

`op` manages its own authentication. Fountain doesn't see your password, session token, or service account key.

**Interactive (local dev):** Sign in with biometric or password once before running `fountain apply`:

```bash
op signin
```

After signing in, `op` keeps a session alive for a configurable TTL (default 30 minutes). If the session expires mid-apply, you'll see:

```
POSTHOG_API_KEY (op://Work/PostHog/api_key): [ERROR] ... session expired
```

Run `op signin` again and re-apply.

**Service accounts (CI):** Create a service account token in 1Password and export it:

```bash
export OP_SERVICE_ACCOUNT_TOKEN=ops_...
fountain apply -f fountain.yml
```

### URI format

```
op://<vault>/<item>/<field>
```

| Segment | Description | Example |
|---------|-------------|---------|
| `vault` | Vault name (case-insensitive) or vault UUID | `Work`, `Personal` |
| `item` | Item name or item UUID | `PostHog`, `GitHub` |
| `field` | Field label (case-insensitive) or field ID | `api_key`, `token`, `password` |

Find the right path with:

```bash
op item list                          # list all items across vaults
op item list --vault Work             # list items in a specific vault
op item get PostHog --vault Work      # show item fields
```

### Example manifest

```yaml
---
apiVersion: fountain/v1
kind: Environment
metadata:
  name: ravi-hq
spec:
  packages:
    apt: [jq, ripgrep]
  secrets:
    ANTHROPIC_API_KEY: op://Work/Anthropic/api_key
    POSTHOG_API_KEY: op://Work/PostHog/api_key
    GITHUB_TOKEN: op://Work/GitHub/token

---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: alice
spec:
  description: Alice's personal credentials
  secrets:
    GITHUB_TOKEN: op://Personal/GitHub/token
    NPM_TOKEN: op://Personal/npm/token
```

Apply:

```bash
op signin    # once per session
fountain apply -f fountain.yml
```

Output:

```
env    +  ravi-hq
  secret  +  ravi-hq/ANTHROPIC_API_KEY
  secret  +  ravi-hq/POSTHOG_API_KEY
  secret  +  ravi-hq/GITHUB_TOKEN
vault  +  alice
  secret  +  alice/GITHUB_TOKEN
  secret  +  alice/NPM_TOKEN
```

### Dynamic vault name

Combine `${VAR}` substitution with `op://` to keep the vault name configurable:

```yaml
secrets:
  ANTHROPIC_API_KEY: op://${OP_VAULT}/Anthropic/api_key
```

```bash
OP_VAULT=Work fountain apply -f fountain.yml
```

### Troubleshooting

**`op` not on PATH**

```
ANTHROPIC_API_KEY (op://Work/Anthropic/api_key): 1Password CLI (`op`) not on PATH — install from https://developer.1password.com/docs/cli/get-started
```

Install `op` and make sure it's in your `PATH`.

**Session expired**

```
ANTHROPIC_API_KEY (op://Work/Anthropic/api_key): [ERROR] ... session expired
```

Run `op signin` and re-apply.

**Item or field not found**

```
ANTHROPIC_API_KEY (op://Work/Anthropic/key): [ERROR] ... item "Anthropic" not found in vault "Work"
```

Double-check vault name, item name, and field label with `op item get <item> --vault <vault>`.

## Bitwarden Secrets Manager (`bws://`)

Use the Bitwarden Secrets Manager CLI to resolve `bws://<uuid>` references at `fountain apply` time. Fountain calls `bws secret get` on your machine — it never sees your Bitwarden master password.

> **Note:** This is the **Secrets Manager** CLI (`bws`), not the personal vault CLI (`bw`). Secrets Manager is designed for IaC / CI flows and uses access tokens + UUID addressing.

### Prerequisites

- A Bitwarden Secrets Manager account: https://bitwarden.com/products/secrets-manager/
  (Separate from the personal vault; free tier available for small teams.)
- The `bws` CLI installed: https://bitwarden.com/help/secrets-manager-cli/

```bash
# macOS
brew install bitwarden/brew/bws

# Linux / Windows — download from the releases page:
# https://github.com/bitwarden/sdk-sm/releases
```

### Auth

`bws` authenticates with a machine access token. Fountain reads `BWS_ACCESS_TOKEN` from your environment and passes it to `bws` — it's never written to the database.

**Generate a token in the Bitwarden dashboard:**

1. Open your Bitwarden Secrets Manager project.
2. Go to **Machine Accounts** → **New machine account**.
3. Grant it read access to the secrets you need.
4. Copy the access token — it's only shown once.

**Set it before running `fountain apply`:**

```bash
export BWS_ACCESS_TOKEN=0.your-token-here...
fountain apply -f fountain.yml
```

Or inline:

```bash
BWS_ACCESS_TOKEN=0.your-token-here... fountain apply -f fountain.yml
```

### URI format

```
bws://<secret-uuid>
```

The UUID uniquely identifies a secret within your Bitwarden Secrets Manager organization. There is no vault/item hierarchy — just a flat UUID.

**Find the UUID** in the dashboard (hover a secret → copy ID) or with the CLI:

```bash
BWS_ACCESS_TOKEN=... bws secret list
```

Output:

```json
[
  {
    "id": "11111111-1111-1111-1111-111111111111",
    "key": "GITHUB_TOKEN",
    "value": "ghp_...",
    ...
  }
]
```

Use the `id` field as the UUID in your manifest.

### Example manifest

```yaml
---
apiVersion: fountain/v1
kind: Environment
metadata:
  name: ravi-hq
spec:
  packages:
    apt: [jq, ripgrep]
  secrets:
    GITHUB_TOKEN: bws://11111111-1111-1111-1111-111111111111
    ANTHROPIC_API_KEY: bws://22222222-2222-2222-2222-222222222222
    NPM_TOKEN: bws://33333333-3333-3333-3333-333333333333

---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: alice
spec:
  description: Alice's credentials
  secrets:
    GITHUB_TOKEN: bws://c0ffee00-dead-beef-cafe-123456789abc
```

Apply:

```bash
BWS_ACCESS_TOKEN=0.your-token... fountain apply -f fountain.yml
```

Output:

```
env    +  ravi-hq
  secret  +  ravi-hq/GITHUB_TOKEN
  secret  +  ravi-hq/ANTHROPIC_API_KEY
  secret  +  ravi-hq/NPM_TOKEN
vault  +  alice
  secret  +  alice/GITHUB_TOKEN
```

### Troubleshooting

**`bws` not on PATH**

```
GITHUB_TOKEN (bws://be8e0ad8-...): Bitwarden Secrets Manager CLI (`bws`) not on PATH — install from https://bitwarden.com/help/secrets-manager-cli/
```

Install `bws` and make sure it's in your `PATH`.

**Invalid or missing access token**

```
GITHUB_TOKEN (bws://be8e0ad8-...): Error: invalid access token
```

Check that `BWS_ACCESS_TOKEN` is set and not expired. Rotate the token in the Bitwarden dashboard if needed.

**UUID not found**

```
GITHUB_TOKEN (bws://be8e0ad8-...): Error: resource not found
```

Verify the UUID with `bws secret list` and confirm the machine account has read access to that secret.

**Missing UUID**

```
GITHUB_TOKEN (bws://): bws://<uuid> reference is missing the UUID
```

The URI must include the full UUID after `bws://`.

## Infisical (`infisical://`)

Use the Infisical CLI to resolve `infisical://` references at `fountain apply` time. Fountain calls `infisical secrets get` on your machine — it never sees your Infisical credentials.

### Prerequisites

- An Infisical account (cloud at https://app.infisical.com or self-hosted).
- The `infisical` CLI installed: https://infisical.com/docs/cli/overview

```bash
# macOS
brew install infisical/get-cli/infisical

# Linux
curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.rpm.sh' | bash
# or: see https://infisical.com/docs/cli/overview for your distro
```

### Auth

Two options depending on your workflow:

#### Interactive (local dev)

Log in once and bind the project:

```bash
infisical login                        # opens browser or prompts credentials
infisical init                         # creates .infisical.json with your project ID
```

After `infisical init`, references using the empty-project form (`infisical:///<env>/<name>`) pick up the project automatically from `.infisical.json`. Run `fountain apply` from the same directory.

#### Token-based (CI / headless)

Generate a service token or machine identity token in the Infisical dashboard, then set it before running `fountain apply`:

```bash
export INFISICAL_TOKEN=st.your-token-here...
fountain apply -f fountain.yml
```

Service tokens are scoped to a project + environment, so the project can be omitted from the URI. Machine identity tokens are project-agnostic — include the project ID in the URI.

### URI format

```
infisical://<project-id>/<env>/<name>
infisical://<project-id>/<env>/<folder>/<name>
infisical://<project-id>/<env>/<a>/<b>/<name>    # folder path = /a/b
```

**Empty project** — falls through to `.infisical.json` or `INFISICAL_PROJECT_ID`:

```
infisical:///<env>/<name>
infisical:///<env>/<folder>/<name>
```

| Segment | Description | Example |
|---------|-------------|---------|
| `project-id` | Infisical project ID (UUID or leave empty) | `abc123ef-...` or `` (empty) |
| `env` | Environment slug | `dev`, `staging`, `prod` |
| `folder` (optional) | Folder path, may be multiple segments | `api`, `api/services` |
| `name` | Secret name (always the last segment) | `DATABASE_URL` |

**Find your project ID** in the Infisical dashboard under Project Settings, or:

```bash
infisical projects list
```

### Example manifest

```yaml
---
apiVersion: fountain/v1
kind: Environment
metadata:
  name: ravi-hq
spec:
  packages:
    apt: [jq, ripgrep]
  secrets:
    # Explicit project ID
    DATABASE_URL: infisical://abc123ef-1234-5678-abcd-000000000001/prod/api/DATABASE_URL
    REDIS_URL: infisical://abc123ef-1234-5678-abcd-000000000001/prod/api/REDIS_URL

    # Workspace project (from .infisical.json or INFISICAL_PROJECT_ID)
    GITHUB_TOKEN: infisical:///prod/GITHUB_TOKEN
    NPM_TOKEN: infisical:///prod/npm/NPM_TOKEN

---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: alice
spec:
  secrets:
    GITHUB_TOKEN: infisical:///prod/alice/GITHUB_TOKEN
```

#### Local dev (interactive auth)

```bash
infisical login
infisical init    # run once in the directory where you'll run fountain apply
fountain apply -f fountain.yml
```

#### CI (token auth)

```bash
INFISICAL_TOKEN=st.your-token... fountain apply -f fountain.yml
```

Output:

```
env    +  ravi-hq
  secret  +  ravi-hq/DATABASE_URL
  secret  +  ravi-hq/REDIS_URL
  secret  +  ravi-hq/GITHUB_TOKEN
  secret  +  ravi-hq/NPM_TOKEN
vault  +  alice
  secret  +  alice/GITHUB_TOKEN
```

### Troubleshooting

**`infisical` not on PATH**

```
DATABASE_URL (infisical://...): Infisical CLI (`infisical`) not on PATH — install from https://infisical.com/docs/cli/overview
```

Install the CLI and ensure it's in your `PATH`.

**Not logged in / token expired**

```
DATABASE_URL (infisical://abc123/prod/api/DATABASE_URL): Unauthorized
```

For interactive auth: run `infisical login` again.
For token auth: check `INFISICAL_TOKEN` and regenerate if expired.

**Missing required segments**

```
DATABASE_URL (infisical:///prod): invalid infisical:// reference: expected infisical://<project?>/<env>/<path?>/<name> with at least env and name
```

The URI needs at least `/<env>/<name>`. Add the secret name as the final segment.

**Project not found**

```
DATABASE_URL (infisical://bad-id/prod/DATABASE_URL): Could not find project
```

Verify the project ID in the Infisical dashboard under Project Settings.

**Secret not found in environment/path**

```
DATABASE_URL (infisical:///prod/api/DATABASE_URL): secret not found
```

Check the environment slug and folder path in the Infisical dashboard. Paths are case-sensitive.
