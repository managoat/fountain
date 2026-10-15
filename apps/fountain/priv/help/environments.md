# Environments

An **Environment** describes the sprite shape to provision — what's installed, what's mounted, what the network looks like, and any setup script that runs before the runtime CLI.

Fields:

- **`packages`** — packages to install (currently `apt`)
- **`env_vars`** — env vars to inject into the sprite
- **`networking_type`** — `unrestricted` (default) or `limited`
- **`networking_config`** — for `limited`, an `allowed_hosts` list
- **`repositories`** — git repos to clone into the sprite at provision time, optionally authenticated via a secret
- **`setup_script`** — shell run after packages/clones, before the runtime CLI

## Create one

```bash
curl -s -X POST "$FOUNTAIN_BASE_URL/api/environments" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" -H "Content-Type: application/json" \
  -d '{
    "name": "my-project",
    "packages": {"apt": ["jq", "ripgrep"]},
    "env_vars": {"PROJECT_ROOT": "/workspace/my-repo"},
    "networking_type": "limited",
    "networking_config": {
      "allowed_hosts": ["github.com", "api.anthropic.com", "registry.npmjs.org"]
    },
    "repositories": [
      {
        "url": "https://github.com/my-org/my-repo",
        "mount_path": "/workspace/my-repo",
        "secret_key": "GITHUB_TOKEN"
      }
    ],
    "setup_script": "cd /workspace/my-repo && uv sync"
  }'
```

## Secrets

`repositories[].secret_key` references a **Secret** stored under the environment. Secrets are AES-256-GCM encrypted at rest with a per-tenant data encryption key derived from the server's `MASTER_SECRETS_KEY`. Add one:

```bash
ENV_ID=...
curl -s -X POST "$FOUNTAIN_BASE_URL/api/environments/$ENV_ID/secrets" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" -H "Content-Type: application/json" \
  -d '{"key":"GITHUB_TOKEN","value":"ghp_..."}'
```

Secrets are **never** returned by the API — only used internally during provisioning.

> Need to override these per-conversation (e.g. run as a different GitHub user)? See [Vaults](/help/vaults). A vault selected at conversation creation is layered over the environment's secrets, with vault values winning on key collision.

## Every conversation provisions from scratch

Each conversation gets a sandbox of its own, and that sandbox runs the packages, clones and `setup_script` every time. Fountain keeps no disk checkpoint of an environment, so keep the setup script fast or bake what is slow into the runtime image.
