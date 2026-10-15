curl -sS -X POST "$FOUNTAIN_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"agent_id\": \"$FOUNTAIN_AGENT_ID\", \"prompt\": \"Which operating system and working directory are you in? Answer in one sentence.\"}"
