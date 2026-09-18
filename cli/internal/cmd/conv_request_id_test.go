package cmd

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
)

func TestPromptCommandsSendClientRequestID(t *testing.T) {
	const agentID = "00000000-0000-0000-0000-000000000001"
	for _, path := range [][]string{{"run"}, {"conv", "prompt"}} {
		for _, tc := range []struct {
			name string
			id   *string
		}{
			{name: "supplied", id: new(" plan-7-步骤-3 ")},
			{name: "omitted"},
			{name: "empty stays supplied", id: new("")},
		} {
			t.Run(strings.Join(path, " ")+"/"+tc.name, func(t *testing.T) {
				isRun := path[0] == "run"
				postPath := "/api/conversations/conv-1/prompts"
				want := map[string]any{"prompt": "do the thing", "images": []any{}}
				if isRun {
					postPath = "/api/conversations"
					want = map[string]any{"agent_id": agentID, "prompt": "do the thing"}
				}
				if tc.id != nil {
					want["client_request_id"] = *tc.id
				}
				var posts atomic.Int32
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					switch {
					case r.Method == http.MethodPost && r.URL.Path == postPath:
						posts.Add(1)
						var body map[string]any
						if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
							t.Error(err)
						}
						if !reflect.DeepEqual(body, want) {
							t.Errorf("POST body = %#v, want %#v", body, want)
						}
						w.Header().Set("Content-Type", "application/json")
						fmt.Fprint(w, `{"data":{"id":"conv-1"},"status":"queued"}`)
					case r.Method == http.MethodGet && r.URL.Path == "/api/conversations/conv-1/stream":
						w.Header().Set("Content-Type", "text/event-stream")
						if r.URL.Query().Get("wait") == "false" {
							fmt.Fprint(w, "id: 1\nevent: stage\ndata: {\"stage\":\"turn\",\"state\":\"done\"}\n\n")
							return
						}
						if !isRun && r.Header.Get("Last-Event-ID") != "1" {
							t.Errorf("follow cursor = %q, want 1", r.Header.Get("Last-Event-ID"))
						}
						fmt.Fprint(w, "id: 2\nevent: stage\ndata: {\"stage\":\"turn\",\"state\":\"done\"}\n\n")
					default:
						t.Errorf("unexpected request: %s %s", r.Method, r.URL)
						http.NotFound(w, r)
					}
				}))
				defer server.Close()
				t.Setenv("FOUNTAIN_BASE_URL", server.URL)
				t.Setenv("FOUNTAIN_API_KEY", "test-key")

				command := findCommand(rootCmd, path)
				// Exercise the registered flags and handler; restore the shared
				// command tree so later cases also prove omission.
				for _, name := range []string{"prompt", "client-request-id"} {
					flag := command.Flags().Lookup(name)
					if flag == nil {
						t.Fatalf("missing --%s", name)
					}
					value, changed := flag.Value.String(), flag.Changed
					t.Cleanup(func() {
						if err := flag.Value.Set(value); err != nil {
							t.Error(err)
						}
						flag.Changed = changed
					})
				}
				args := []string{"conv-1", "-p", "do the thing"}
				if isRun {
					args[0] = agentID
				}
				if tc.id != nil {
					args = append(args, "--client-request-id", *tc.id)
				}
				if err := command.ParseFlags(args); err != nil {
					t.Fatal(err)
				}
				if err := command.RunE(command, command.Flags().Args()); err != nil {
					t.Fatal(err)
				}
				if posts.Load() != 1 {
					t.Fatalf("sent %d prompts, want one", posts.Load())
				}
			})
		}
	}
}
