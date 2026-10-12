# Declarative manifest (`fountain apply`)

For more than a handful of agents/environments, manage them as YAML and reconcile via the CLI.

## Format

A `fountain.yml` is a multi-document YAML file. Each doc is one resource with three top-level fields:

```yaml
apiVersion: fountain/v1
kind: Environment | Vault | Agent | Teammate | Schedule
metadata:
  name: <unique-on-operator-side>
spec:
  # ... fields matching the API schema for the kind ...
```

The `metadata.name` is the upsert key for every kind. If a resource with that name exists, it's updated; if not, it's created.

## Order is irrelevant inside the file

`fountain apply` reconciles in a fixed order: **environments, vaults, agents, teammates, schedules** — so a doc can reference another by name even if that one is defined later in the file. An `Agent` references an `environment`; a `Teammate` references an `agent`, an `environment` and a `vault`; a `Schedule` references a `teammate`. Every reference resolves against the manifest first and then against what **already exists** server-side, so a manifest can attach an agent to an environment managed elsewhere; a name that matches neither fails that doc and no other.

## The team kinds

A `Teammate` puts an agent on the team, which opens its conversation and provisions its computer. Re-applying moves what the teammate is called and which environment and vault it is bound to — it never provisions a second one, and it never resurrects a computer that is gone (message the teammate for that). A `Schedule` is a cron that runs a teammate with a prompt, keyed by its name under its teammate.

Two things about it that surprise people:

- **A `Teammate` doc is the whole teammate.** Unlike the other four kinds, where an absent `spec` key leaves that column alone, dropping `environment` or `vault` from a Teammate doc *clears* that binding — back to the agent's own environment and no vault. That is what makes the doc a declaration rather than a patch.
- **A teammate's name is not unique.** It is the conversation's title, or the agent's name. A `Schedule` naming a teammate that two of them answer to fails rather than binding to whichever the roster listed last; one this manifest reconciled is unique among the docs and wins.
- **Rebinding moves the computer.** A home is keyed on `(user, agent, environment, vault)`, so changing either id retires the machine the old key named; the teammate's next message builds a fresh one. Refused with an error on that row while a turn is still running there — the same refusal `Agent`'s `environment` gives (#1084). A conversation that *shared* that machine and names a different environment or vault does not follow the teammate; it builds its own on its next prompt. And because there is only ever one home per identity, a rebind onto an identity the agent **already** has a home for is **refused**, not merged onto that home — reset or remove the existing one first (#1636).

**Two Teammate docs can't name the same agent.**

```yaml
---
apiVersion: fountain/v1
kind: Teammate
metadata:
  name: Ada
spec:
  agent: researcher
  environment: my-project
  vault: alice

---
apiVersion: fountain/v1
kind: Schedule
metadata:
  name: standup
spec:
  teammate: Ada
  cron: "0 9 * * 1-5"          # five fields, UTC
  prompt: What is on today?
  one_off: false
  enabled: true
```

## Nothing is pruned

Apply is additive. Deleting a doc from the manifest leaves its record in place; delete it through its own command or the console.

## What the trail says

Each applied row leaves its context's own audit event, with the actor and IP of the request that applied it: `team.member.added` / `team.updated` for a Teammate and `team.schedule.created` / `team.schedule.updated` for a Schedule. An `unchanged` row writes nothing at all.

## Example

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
    GITHUB_TOKEN: ghp_alice_...
    NPM_TOKEN: npm_alice_...

---
apiVersion: fountain/v1
kind: Agent
metadata:
  name: researcher
spec:
  runtime: claude
  model: anthropic/claude-sonnet-5
  environment: my-project        # ← resolved to environment_id at apply time
  system: You are a research assistant.
  skills: [aod]
  mcp_servers:
    everything:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-everything"]
```

## Apply

```bash
fountain apply -f fountain.yml          # single file
fountain apply -f ./fountain-specs/     # directory: walks **/*.{yml,yaml}
```

Directory mode walks recursively. Any YAML document carrying both `apiVersion` and `kind` is treated as a resource; anything else (a doc without front-matter, an unrelated `.yaml` config) is silently ignored. So `fountain-specs/agents/*.yml`, `fountain-specs/environments/*.yml`, plus an unrelated `.github/workflows/ci.yml` in the same tree all coexist cleanly. Files are processed in alphabetical order; if you want strict ordering for any reason, prefix names like `10-envs.yml` / `20-agents.yml` (though reconciliation order is fixed internally — envs first, then vaults, then agents — regardless).

Output uses `+` for create, `~` for update, `=` for a resource that already matched, one line per resource:

```
env    +  my-project
vault  +  alice
  secret  ~  alice/GITHUB_TOKEN
  secret  ~  alice/NPM_TOKEN
agent  =  researcher
teammate  =  Ada
schedule  +  standup
```

Errors per-resource go to stderr but don't stop the run; other resources still apply.

Under the hood the CLI compiles the whole manifest into one document and sends it to `POST /api/apply` in a single request — the server reconciles everything and returns per-resource results. (Against older servers without that endpoint, the CLI falls back to one call per resource.)

## Idempotency

Re-applying the same file is a no-op, and says so: every resource shows `=` (`unchanged`) because nothing was written to it. Inline `spec.secrets` are the exception — they are re-encrypted on every apply, so they keep showing `~` under a resource that shows `=`. Useful for CI: keep `fountain.yml` in source control, run `fountain apply -f fountain.yml` from your deploy pipeline.

## Apply-time secret resolution (so you can commit `fountain.yml`)

Secret values in `spec.secrets` accept references that get resolved at **apply time** before any DB write:

- `${VAR}` — substituted from your local environment, or from `--var KEY=VAL` flags.
- `op://<vault>/<item>/<field>` — resolved via the [1Password CLI](https://developer.1password.com/docs/cli/get-started). Auth (biometric unlock, session) handled by `op`.
- `bws://<secret-uuid>` — resolved via the [Bitwarden Secrets Manager CLI](https://bitwarden.com/help/secrets-manager-cli/). Auth via `BWS_ACCESS_TOKEN` (consumed by `bws`).
- `infisical://<project?>/<env>/<path?>/<name>` — resolved via the [Infisical CLI](https://infisical.com/docs/cli/overview). Empty project segment (`infisical:///<env>/<name>`) falls through to `.infisical.json` / `INFISICAL_PROJECT_ID`. Last URI segment is always the secret name; segments between env and name form the folder path.

```yaml
---
apiVersion: fountain/v1
kind: Environment
metadata:
  name: my-project
spec:
  secrets:
    GITHUB_TOKEN: ${GH_PAT}                                  # ← from $GH_PAT at apply time
    POSTHOG_API_KEY: op://Work/PostHog/api_key               # ← 1Password CLI
    NPM_TOKEN: bws://11111111-1111-1111-1111-111111111111    # ← Bitwarden Secrets Manager
    DATABASE_URL: infisical://abc/prod/api/DATABASE_URL      # ← Infisical (explicit project)
    REDIS_URL: infisical:///prod/REDIS_URL                   # ← Infisical (workspace project)
    ANTHROPIC_API_KEY: op://${OP_VAULT}/Anthropic/key        # ← composes: ${VAR} first, then op
---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: alice
spec:
  secrets:
    GITHUB_TOKEN: op://Personal/GitHub/token
```

Run with:

```bash
GH_PAT=ghp_... POSTHOG=phc_... ALICE_GH_PAT=ghp_alice... \
  fountain apply -f fountain.yml

# or pass values inline:
fountain apply -f fountain.yml --var GH_PAT=ghp_... --var POSTHOG=phc_...
```

Flags win over env vars when both are set. Use `$${VAR}` to write through a literal `${VAR}` (rare).

### Failure modes

Both kinds of resolution collect failures across the whole manifest and abort before any DB write — so you fix everything in one pass:

```
apply-time substitution failed — set these in the env or pass --var KEY=VAL:
  my-project: GH_PAT, POSTHOG
  alice: ALICE_GH_PAT
```

```
apply-time secret resolution failed:
  my-project:
    POSTHOG_API_KEY (op://Work/PostHog/api_key): [ERROR] ... session expired
    NPM_TOKEN (bws://abc-123): Error: invalid access token
```

If the relevant CLI isn't installed, you'll see install instructions for that provider. The two phases run in order — `${VAR}` first, then external refs — so values like `op://${OP_VAULT}/Anthropic/key` work.

### Scope

Apply-time resolution is **scoped to `spec.secrets`** only. Everything else in the manifest (agent system prompts, `mcp_servers` headers, etc.) is left literal — `${VAR}` references in those positions are resolved by the **provision-time** substitution layer when a conversation starts. Two layers, two scopes, one syntax.
