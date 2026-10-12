package cmd

import (
	"encoding/json"
	"testing"
)

// Table test decoding the exact JSON each server view renders into the CLI
// struct that consumes it. The fixtures are hardcoded copies of what the
// Elixir renders — if a field is renamed or an envelope added on the server,
// the corresponding case here must be updated in the same PR.
//
// Sources:
//   - created / index: apps/fountain/lib/fountain_web/controllers/api_key_json.ex
//   - auth/me:         apps/fountain/lib/fountain_web/controllers/auth_me_controller.ex
func TestDecodeServerJSONShapes(t *testing.T) {
	t.Run("ApiKeyJSON.created is flat with prefix", func(t *testing.T) {
		// ApiKeyJSON.created/1: %{id:, name:, key:, prefix:, created_at:}
		fixture := `{
			"id": "0198c9a2-1111-7222-8333-444455556666",
			"name": "ci",
			"key": "ftn_test_0000000000000000",
			"prefix": "ftn_test_0000",
			"created_at": "2026-08-03T10:00:00"
		}`
		var got apiKeyCreated
		if err := json.Unmarshal([]byte(fixture), &got); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if got.Key != "ftn_test_0000000000000000" {
			t.Errorf("key: got %q", got.Key)
		}
		if got.Prefix != "ftn_test_0000" {
			t.Errorf("prefix: got %q — the server field is `prefix`, not `key_prefix`", got.Prefix)
		}
		if got.Name != "ci" || got.ID == "" || got.CreatedAt == "" {
			t.Errorf("metadata: %+v", got)
		}
	})

	t.Run("ApiKeyJSON.index is a data envelope of summaries", func(t *testing.T) {
		// ApiKeyJSON.index/1: %{data: [%{id:, name:, prefix:, created_at:,
		// last_used_at:, scopes:, expires_at:}]}
		fixture := `{"data": [{
			"id": "0198c9a2-aaaa-7bbb-8ccc-ddddeeeeffff",
			"name": "laptop",
			"prefix": "ftn_test_1111",
			"created_at": "2026-08-01T09:00:00",
			"last_used_at": "2026-08-03T08:30:00",
			"scopes": ["*"],
			"expires_at": null
		}]}`
		var got struct {
			Data []apiKeySummary `json:"data"`
		}
		if err := json.Unmarshal([]byte(fixture), &got); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if len(got.Data) != 1 {
			t.Fatalf("want 1 key, got %d", len(got.Data))
		}
		k := got.Data[0]
		if k.Prefix != "ftn_test_1111" {
			t.Errorf("prefix: got %q — the server field is `prefix`, not `key_prefix`", k.Prefix)
		}
		if k.Name != "laptop" || k.LastUsedAt != "2026-08-03T08:30:00" {
			t.Errorf("summary: %+v", k)
		}
	})

	t.Run("auth/me is flat", func(t *testing.T) {
		// AuthMeController.show/2: json(conn, %{id:, email:, role:,
		// email_verified:, ...}) — no envelope.
		fixture := `{
			"id": "0198c9a2-1234-7890-abcd-ef0123456789",
			"email": "dev@example.com",
			"role": "user",
			"email_verified": true
		}`
		var got authMe
		if err := json.Unmarshal([]byte(fixture), &got); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if got.Email != "dev@example.com" || got.Role != "user" {
			t.Errorf("auth/me: %+v", got)
		}
	})
}
