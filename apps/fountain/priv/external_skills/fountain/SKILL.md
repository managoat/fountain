---
name: fountain
description: Operate Fountain (https://managoat.com) — a multi-tenant service that runs sandboxed coding agents (claude/codex/gemini) inside per-conversation sprites. Use this skill whenever the user asks you to spin up an agent on Fountain, delegate work to another agent, fan out a task across N agents, manage Fountain agents/environments/vaults declaratively, or drive the `fountain` CLI. Reads `FOUNTAIN_API_KEY` (required) and `FOUNTAIN_BASE_URL` (defaults to https://managoat.com).
---

# Fountain — driving the API, CLI, and manifest from outside a sprite

You are NOT running inside a Fountain sprite. You are an LLM (in a user's IDE,
CI job, or shell) operating Fountain on the user's behalf — spawning
conversations, listing/creating agents, applying YAML manifests, gathering
results.

If you are running inside a sprite (i.e. `$FOUNTAIN_CONVERSATION_ID` is set),
use the in-sprite `fountain` skill instead — it covers spawning sub-agents
with provenance headers and conversation-scoped tokens. This skill is for
**external** callers.

## The mental model (4 primitives)

| Primitive | What it is | Where it's defined |
|---|---|---|
| **Environment** | sandbox shape — apt packages, env_vars, repos to clone with secrets, networking allowlist, `setup_script` | per-tenant; PUT/POSTed via `/api/environments` |
| **Vault** | free-floating bag of encrypted secret **overrides**, picked per-conversation; layered over the env's secrets, vault wins on key collision | per-tenant; PUT/POSTed via `/api/vaults` |
| **Agent** | named runtime config: `runtime` (claude/codex/gemini), `model`, optional `system` prompt, optional `environment_id`, optional `skills`, optional `mcp_servers` | per-tenant; PUT/POSTed via `/api/agents` |
| **Conversation** | one running instance of an agent in a freshly provisioned sprite; SSE-streamable; supports multi-turn | per-conversation; created via `POST /api/conversations`, lives until `/terminate` |

`POST /api/conversations` is the hot path: pick an agent (and optionally a vault),
pass a prompt, get a conversation id back. Poll status, then drain the SSE
stream for the final answer.

## Authentication

Everything under `/api/*` requires `Authorization: Bearer <FOUNTAIN_API_KEY>`.

```bash
export FOUNTAIN_BASE_URL=https://managoat.com
export FOUNTAIN_API_KEY=<key>
```

Mint a key with `fountain auth login` (writes `~/.fountain/credentials`) or
`fountain keys create` (prints raw key for scripting / CI). API keys carry the
full blast radius of the owning user — treat them like passwords.

> **Use the API path**: `$FOUNTAIN_BASE_URL/api/conversations`. The retired
> browser path `$FOUNTAIN_BASE_URL/conversations` returns 404.

## The CLI is usually the right call

The Go CLI hides the curl/jq/SSE boilerplate. If `fountain` is on PATH and
the user has logged in, prefer it.

```sh
# discover
fountain agent list
fountain env list
fountain vault list
fountain conv list

# do work
fountain run <agent-name> -p "your prompt"           # create + stream a conversation
fountain run <agent-name> -p "..." --vault alice     # run under alice's credentials
fountain conv show <conv-id>                         # see status, runtime, vault, etc.
fountain conv interrupt <conv-id>                    # stop the running turn, keep the sandbox
fountain conv terminate <conv-id>                    # destroy the sprite

# manage declaratively
fountain apply -f fountain.yml                       # reconcile a manifest file
fountain apply -f ./agent-specs/                     # walk a dir, apply every *.yml

# secrets
fountain vault set-secret alice GITHUB_TOKEN ghp_...
```

Install:

```sh
brew install managoat/tap/fountain
# or download from https://github.com/managoat/fountain/releases/latest
```

## The two API patterns you'll actually use

### A. Spawn one and block until it answers

```bash
AGENT_ID=$(curl -s "$FOUNTAIN_BASE_URL/api/agents" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  | jq -r '.data[] | select(.name=="researcher") | .id')

CONV=$(curl -s -X POST "$FOUNTAIN_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg a "$AGENT_ID" --arg p "$PROMPT" '{agent_id:$a, prompt:$p}')" \
  | jq -r .data.id)

# poll until terminal
while :; do
  s=$(curl -s "$FOUNTAIN_BASE_URL/api/conversations/$CONV" \
    -H "Authorization: Bearer $FOUNTAIN_API_KEY" | jq -r .data.status)
  case "$s" in running|pending) sleep 2 ;; *) break ;; esac
done

# replay-only stream drain
curl -sN --max-time 5 \
  "$FOUNTAIN_BASE_URL/api/conversations/$CONV/stream?streams=stdout&wait=false" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
| awk '/^data: /{sub(/^data: /,""); print}' \
| jq -r '.data | fromjson? | select(.type=="result") | .result' \
| tail -n1
```

### B. Fan out N agents in parallel

```bash
prompts=("Audit auth module" "Audit billing module" "Audit telemetry module")

ids=$(printf '%s\n' "${prompts[@]}" | xargs -n1 -P8 -I{} sh -c '
  curl -s -X POST "$1/api/conversations" \
    -H "Authorization: Bearer $2" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg a "$3" --arg p "$4" "{agent_id:\$a, prompt:\$p}")" \
  | jq -r .data.id
' _ "$FOUNTAIN_BASE_URL" "$FOUNTAIN_API_KEY" "$AGENT_ID" {})

# wait for all
echo "$ids" | xargs -n1 -P10 -I{} sh -c '
  while :; do
    s=$(curl -s "$1/api/conversations/$3" -H "Authorization: Bearer $2" | jq -r .data.status)
    case "$s" in running|pending) sleep 2 ;; *) break ;; esac
  done
' _ "$FOUNTAIN_BASE_URL" "$FOUNTAIN_API_KEY" {}

# gather
while IFS= read -r conv; do
  echo "=== $conv ==="
  curl -sN --max-time 5 \
    "$FOUNTAIN_BASE_URL/api/conversations/$conv/stream?streams=stdout&wait=false" \
    -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  | awk '/^data: /{sub(/^data: /,""); print}' \
  | jq -r '.data | fromjson? | select(.type=="result") | .result' \
  | tail -n1
done <<<"$ids"
```

## SSE wire format (so you don't have to discover it)

`GET /api/conversations/:id/stream` produces lines like:

```
id: 2694
event: output
data: {"data":"{\"type\":\"result\",...}","stream":"stdout","stage":"turn",...}
```

**Two layers of JSON.** `awk` strips the `data: ` prefix; jq parses the
**outer** object; only the inner `.data` field is a JSON-encoded string that
needs `fromjson` to peel. **Single fromjson, not double** — jq parses the awk
output automatically.

Stream params:
- `?streams=stdout,stderr,stage` — comma-separated allow-list of event categories. Empty/missing = all.
- `?wait=false` — close immediately after replaying buffered events. **Always pass this for gather.** Default keeps the stream open ~60s for live tailing.
- `Last-Event-ID: <int>` header — resume after this id.

## Per-runtime: where the final answer lives

Pull `runtime` once per conversation, then pick the matching filter:

```bash
RT=$(curl -s "$FOUNTAIN_BASE_URL/api/conversations/$CONV" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" | jq -r .data.runtime)
```

| runtime  | filter (the part **after** `.data \| fromjson?`)                       | text path                          |
| -------- | ---------------------------------------------------------------------- | ---------------------------------- |
| claude   | `select(.type=="result")`                                              | `.result`                          |
| codex    | `select(.type=="item.completed" and .item.type=="agent_message")`      | `.item.text`                       |
| gemini   | `select(.type=="message" and .role=="assistant")`                      | `.content` *(last one)*            |

## Multi-turn

```bash
curl -s -X POST "$FOUNTAIN_BASE_URL/api/conversations/$CONV/prompts" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" -H "Content-Type: application/json" \
  -d '{"prompt":"Now compare that to the worker service."}'
```

Then poll status / drain the stream the same way. The runtime session resumes
— the agent remembers turn 1. The vault (if any) is baked in at creation; you
can't change it mid-conversation.

## Manifest (`fountain apply`) — declarative agent/env/vault config

For more than a handful of agents, manage them as YAML and reconcile via CLI.

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
  secrets:
    GITHUB_TOKEN: ${GH_PAT}                                  # operator-shell env var
    POSTHOG_API_KEY: op://Work/PostHog/api_key               # 1Password
    NPM_TOKEN: bws://11111111-1111-1111-1111-111111111111    # Bitwarden Secrets Manager
    DATABASE_URL: infisical://abc/prod/api/DATABASE_URL      # Infisical
---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: alice
spec:
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
  environment: my-project            # resolved to environment_id at apply time
  system: "You are a research assistant. Cite primary sources."
  skills: [fountain]                 # mounts an additional skill into the sprite
  mcp_servers:
    everything:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-everything"]
```

Apply:

```sh
GH_PAT=ghp_... fountain apply -f fountain.yml
# or
fountain apply -f fountain.yml --var GH_PAT=ghp_...
```

Rules:
- `metadata.name` is the upsert key. Existing resource → PUT. New → POST.
- Reconciliation order is **envs → vaults → agents**, so cross-references resolve by name.
- Secret values in `spec.secrets` accept `${VAR}`, `op://...`, `bws://...`, `infisical://...`.
- Apply-time secret resolution is **scoped to `spec.secrets` only**. Other fields (system prompts, mcp_servers headers, etc.) use `${VAR}` at **provision time**, against the merged env+vault secret map.
- `$${VAR}` writes a literal `${VAR}` (escape).

## Endpoint summary

| method | path | what |
| --- | --- | --- |
| GET | `/api/agents` | list |
| POST | `/api/agents` | create |
| GET/PUT/DELETE | `/api/agents/:id` | one |
| GET/POST | `/api/environments` | list/create |
| GET/PUT/DELETE | `/api/environments/:id` | one |
| POST | `/api/environments/:id/secrets` | add a secret |
| DELETE | `/api/environments/:id/secrets/:key` | remove |
| GET/POST | `/api/vaults` | list/create |
| GET/PUT/DELETE | `/api/vaults/:id` | one |
| POST | `/api/vaults/:id/secrets` | add a secret |
| DELETE | `/api/vaults/:id/secrets/:key` | remove |
| GET | `/api/conversations` | list |
| POST | `/api/conversations` | start (provisions a sprite, queues turn 1) |
| GET | `/api/conversations/:id` | one |
| GET | `/api/conversations/:id/stream` | SSE event stream |
| POST | `/api/conversations/:id/prompts` | follow-up prompt (turn 2+) |
| POST | `/api/conversations/:id/interrupt` | stop the running turn, keep the sandbox |
| POST | `/api/conversations/:id/terminate` | destroy the sprite |
| DELETE | `/api/conversations/:id` | terminate + remove DB row |

Full spec: `$FOUNTAIN_BASE_URL/api/openapi.json` (machine-readable) or
`$FOUNTAIN_BASE_URL/api/docs` (Swagger UI, click "Authorize" to try inline).

## Response envelope

All non-stream endpoints:

```json
{ "data": { ... } }    // or { "data": [ ... ] } for lists
```

Errors:

```json
{ "errors": [{"title": "...", "message": "...", "source": {"pointer": "/field"}}] }
```

## Important

- **Use `/api/...`.** The retired browser `/conversations` path returns 404. Browser console paths such as `/agents` require a session, not an API key.
- **`wait=false` for gather** — without it your `curl --max-time 5` sits idle for the full timeout. With it, the SSE stream closes the moment the replay drains.
- **Parallelize spawn / poll / gather** with `xargs -P` — one provision takes ~5–15s, no reason to do them sequentially.
- **Costs add up.** Every conversation provisions a real sandbox. Terminate when you're done if you don't need the sandbox to persist.
- **API key blast radius.** A `FOUNTAIN_API_KEY` carries the owning user's full permissions — it can create/delete every agent, env, vault, conversation, and API key on that account. Don't paste it into prompts or commit it.
- **Inside a sprite, use the other skill.** Conversations spawned **from inside** a sprite use `$FOUNTAIN_TOKEN` (per-conversation, auto-injected) and the `X-Fountain-Parent-Conversation-Id` header for provenance — not `$FOUNTAIN_API_KEY`.

## Further reading

- Guided tour, end to end: `$FOUNTAIN_BASE_URL/docs/tour`
- API reference: `$FOUNTAIN_BASE_URL/docs/api`
- Full doc bundle for LLMs: `$FOUNTAIN_BASE_URL/llms-full.txt`
- OpenAPI spec: `$FOUNTAIN_BASE_URL/api/openapi.json`
- Source: https://github.com/managoat/fountain
