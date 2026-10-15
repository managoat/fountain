curl -sS -X POST "$MANAGOAT_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"agent_id\": \"$MANAGOAT_AGENT_ID\", \"prompt\": \"Which operating system and working directory are you in? Answer in one sentence.\"}"
