package cmd

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
)

func TestConversationCreateForwardsFileAndStdinWithoutFieldMappings(t *testing.T) {
	body := `{"agent_id":"agent-1","title":"","vault_id":null,"fresh":false,"images":[],"labels":{"source":"nightly"},"permission_policy":{"ask_timeout":0},"future_field":9007199254740993}`
	for _, source := range []string{"file", "stdin"} {
		for _, status := range []int{201, 202} {
			t.Run(source+http.StatusText(status), func(t *testing.T) {
				// A 202 is a sandbox request, not a conversation to follow.
				response := `{"data":{"id":"created","status":"idle"}}`
				if status == 202 {
					response = `{"data":{"id":"queued","status":"pending","kind":"start"}}`
				}
				var calls atomic.Int32
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					calls.Add(1)
					if r.Method != "POST" || r.URL.Path != "/api/conversations" {
						t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
					}
					if r.Header.Get("Authorization") != "Bearer test-key" {
						t.Error("missing API authentication")
					}
					got, _ := io.ReadAll(r.Body)
					var wantFields, gotFields map[string]json.RawMessage
					_ = json.Unmarshal([]byte(body), &wantFields)
					_ = json.Unmarshal(got, &gotFields)
					if !reflect.DeepEqual(wantFields, gotFields) {
						t.Errorf("body changed: %s", got)
					}
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(status)
					_, _ = io.WriteString(w, response)
				}))
				defer server.Close()
				t.Setenv("FOUNTAIN_BASE_URL", server.URL)
				t.Setenv("FOUNTAIN_API_KEY", "test-key")
				command := newConversationCreateCommand()
				var output bytes.Buffer
				command.SetOut(&output)
				path := "-"
				if source == "file" {
					path = filepath.Join(t.TempDir(), "request.json")
					if err := os.WriteFile(path, []byte(body), 0600); err != nil {
						t.Fatal(err)
					}
				} else {
					command.SetIn(strings.NewReader(body))
				}
				command.SetArgs([]string{"--file", path})
				if err := command.Execute(); err != nil {
					t.Fatal(err)
				}
				var compact bytes.Buffer
				if err := json.Compact(&compact, output.Bytes()); err != nil {
					t.Fatal(err)
				}
				if compact.String() != response {
					t.Fatalf("response changed: %s", output.String())
				}
				if calls.Load() != 1 {
					t.Fatalf("expected creation only, got %d requests", calls.Load())
				}
			})
		}
	}
}

func TestConversationCreateRejectsBadInputBeforeHTTP(t *testing.T) {
	for _, input := range []string{"", "{", "null", "[]", `{} {}`, `{} trailing`} {
		t.Run(input, func(t *testing.T) {
			command := newConversationCreateCommand()
			command.SetIn(strings.NewReader(input))
			command.SetOut(io.Discard)
			command.SetErr(io.Discard)
			command.SetArgs([]string{"--file", "-"})
			err := command.Execute()
			if err == nil || !strings.Contains(err.Error(), "JSON object") {
				t.Fatalf("got %v", err)
			}
		})
	}
	for _, args := range [][]string{
		{}, {"--file", filepath.Join(t.TempDir(), "missing")},
		{"--file", "-", "agent-name"}, {"--file", "-", "--prompt", "hi"},
	} {
		command := newConversationCreateCommand()
		command.SetOut(io.Discard)
		command.SetErr(io.Discard)
		command.SetArgs(args)
		if err := command.Execute(); err == nil {
			t.Fatalf("accepted %v", args)
		}
	}
}

func TestConversationCreateReturnsServerValidationError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = io.WriteString(w, `{"error":"invalid_prompt"}`)
	}))
	defer server.Close()
	t.Setenv("FOUNTAIN_BASE_URL", server.URL)
	t.Setenv("FOUNTAIN_API_KEY", "test-key")
	command := newConversationCreateCommand()
	command.SetIn(strings.NewReader(`{"agent_id":"a","prompt":""}`))
	var output bytes.Buffer
	command.SetOut(&output)
	command.SetErr(io.Discard)
	command.SetArgs([]string{"--file", "-"})
	if err := command.Execute(); err == nil || !strings.Contains(err.Error(), "invalid_prompt") {
		t.Fatalf("server validation was lost: %v", err)
	}
	if strings.Contains(output.String(), `"data"`) {
		t.Fatal("printed a successful response on failure")
	}
}
