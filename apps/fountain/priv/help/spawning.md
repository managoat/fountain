# Spawning sub-agents from inside a sprite

Every conversation gets three env vars in its sprite:

- `FOUNTAIN_BASE_URL` — your Fountain server's public URL (e.g. `https://managoat.com`)
- `FOUNTAIN_TOKEN` — an API key the conversation can use to call back
- `FOUNTAIN_CONVERSATION_ID` — the spawning conversation's UUID, used to record provenance via `X-Fountain-Parent-Conversation-Id`

Plus the bundled **`fountain` skill** mounted under `~/.claude/skills/fountain/` (or the runtime equivalent). With those pieces, any agent inside a sprite can call back to the API and spawn more conversations.

## Patterns the agent will use

### Fan out

```bash
# Spawn N in parallel
ids=$(printf '%s\n' "First task" "Second task" "Third task" \
  | xargs -n1 -P8 -I{} sh -c '
    curl -s -X POST "$1/api/conversations" \
      -H "Authorization: Bearer $2" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg a "$3" --arg p "$4" "{agent_id:\$a, prompt:\$p}")" \
    | jq -r .data.id
  ' _ "$FOUNTAIN_BASE_URL" "$FOUNTAIN_TOKEN" "$AGENT_ID" {})

# Wait for all in parallel
echo "$ids" | xargs -n1 -P10 -I{} sh -c '
  while :; do
    s=$(curl -s "$1/api/conversations/$3" -H "Authorization: Bearer $2" | jq -r .data.status)
    case "$s" in running|pending) sleep 2 ;; *) break ;; esac
  done
' _ "$FOUNTAIN_BASE_URL" "$FOUNTAIN_TOKEN" {}

# Gather final answers
while IFS= read -r conv; do
  curl -sN --max-time 5 \
    "$FOUNTAIN_BASE_URL/api/conversations/$conv/stream?streams=stdout&wait=false" \
    -H "Authorization: Bearer $FOUNTAIN_TOKEN" \
  | awk '/^data: /{sub(/^data: /,""); print}' \
  | jq -r '.data | fromjson? | select(.type=="result") | .result' \
  | tail -n1
done <<<"$ids"
```

### Block-and-return-result

Same shape but for one conversation at a time. The full bash function is in the bundled skill — `cat ~/.claude/skills/fountain/SKILL.md` from inside any sprite.

## SSE wire format

```
id: 2694
event: output
data: {"data":"{\"type\":\"result\",...}","stream":"stdout","stage":"turn",...}

id: 2695
event: output
data: {"data":"{\"type\":\"assistant\",...}","stream":"stdout",...}
```

Two layers of JSON: outer is the SSE event envelope, inner is the runtime CLI's stream-json line. `awk` strips the `data:` prefix → jq parses the outer → `.data | fromjson` peels the inner. **Single fromjson, not double** — jq parses the awk output automatically.

## Per-runtime: where the final text lives

| runtime | jq selector for the terminal event | text path |
| --- | --- | --- |
| claude | `select(.type=="result")` | `.result` |
| codex | `select(.type=="item.completed" and .item.type=="agent_message")` | `.item.text` |
| gemini | `select(.type=="message" and .role=="assistant")` | `.content` (last one) |

## `wait=false` on the stream

The SSE endpoint normally holds open for ~60s waiting for new events. When the conversation is already done and you only want the replay, pass `wait=false` — it closes the moment the replay drains. Without it your `curl --max-time` sits idle for the full duration. **Always pass it for gather.**

## Security model — what to know

`FOUNTAIN_TOKEN` is a Fountain API key issued **per conversation**, scoped to the conversation's owning user. Fountain mints it at provision time, names the `api_keys` row `sprite:<short-conv-id>`, and stores its ID on the `conversations` row. The token rotates on every fresh provision or reattach (plaintext can't be recovered after a BEAM restart) and is revoked when the conversation terminates — kill the conversation, kill the key.

The token still carries the **same Fountain blast radius the owning user has** — anything inside the sprite can create/delete agents, list conversations, list keys, etc. on behalf of that user. Treat prompt injection on a sprite-bound agent as a full account takeover for that user; the per-conversation scoping bounds *how long* a leaked token stays live, not *what it can do* while it's live.

## Tunneling

For a sprite to call back, `FOUNTAIN_BASE_URL` must be reachable from inside the sprite — `localhost` won't do. Local-dev cleanest option: [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/install-and-setup/tunnel-guide/local/) or [ngrok](https://ngrok.com). In production: whatever your hosted URL is.
