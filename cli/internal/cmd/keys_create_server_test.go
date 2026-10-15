package cmd

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestKeysCreateDecodesServerResponse runs keysCreate against the exact JSON
// FountainWeb.ApiKeyJSON.created/1 renders
// (apps/fountain/lib/fountain_web/controllers/api_key_json.ex): a FLAT object
// with a `prefix` field — no `data` envelope, no `key_prefix`.
//
// This is the regression test for #398 part 1: the old decoder expected a
// `data` envelope, so every `managoat keys create` exited 1 after the key had
// been created server-side, and the plaintext key — returned only in this one
// response — was lost forever.
//
// This test deliberately references no CLI types, only the command function,
// so it compiles (and fails) against the pre-fix decoder.
func TestKeysCreateDecodesServerResponse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/auth/api-keys" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		// Byte-for-byte the shape of ApiKeyJSON.created/1.
		_, _ = w.Write([]byte(`{
			"id": "0198c9a2-1111-7222-8333-444455556666",
			"name": "ci",
			"key": "ftn_test_0000000000000000",
			"prefix": "ftn_test_0000",
			"created_at": "2026-08-03T10:00:00"
		}`))
	}))
	defer srv.Close()

	t.Setenv("MANAGOAT_BASE_URL", srv.URL)
	t.Setenv("MANAGOAT_API_KEY", "test-token")

	// The old decoder called Fatalf here (os.Exit(1)), which aborts the whole
	// test binary — i.e. this test fails loudly against the old code.
	if err := keysCreate("ci"); err != nil {
		t.Fatalf("keysCreate against the real server shape: %v", err)
	}
}
