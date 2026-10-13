package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/managoat/fountain/cli/config"
	"github.com/managoat/fountain/cli/credentials"
)

// newTestClient points the client at a httptest server via the env vars that
// sit at the top of config's precedence order.
func newTestClient(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	t.Setenv("FOUNTAIN_BASE_URL", srv.URL)
	t.Setenv("FOUNTAIN_API_KEY", "ftn_test_key")
	return New(credentials.Opts{})
}

func TestClientDo(t *testing.T) {
	t.Run("prefixes /api, sends bearer token and JSON body", func(t *testing.T) {
		var gotPath, gotAuth, gotContentType string
		var gotBody map[string]any
		c := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
			gotPath = r.URL.Path
			gotAuth = r.Header.Get("Authorization")
			gotContentType = r.Header.Get("Content-Type")
			json.NewDecoder(r.Body).Decode(&gotBody)
			w.Write([]byte(`{"id":"a1"}`))
		})

		var out map[string]any
		if err := c.Post("/agents", map[string]string{"name": "demo"}, &out); err != nil {
			t.Fatal(err)
		}
		if gotPath != "/api/agents" {
			t.Errorf("path = %q, want /api/agents", gotPath)
		}
		if gotAuth != "Bearer ftn_test_key" {
			t.Errorf("Authorization = %q", gotAuth)
		}
		if gotContentType != "application/json" {
			t.Errorf("Content-Type = %q", gotContentType)
		}
		if gotBody["name"] != "demo" {
			t.Errorf("body = %v", gotBody)
		}
		if out["id"] != "a1" {
			t.Errorf("out = %v", out)
		}
	})

	t.Run("GET sends no content-type and discards body into nil out", func(t *testing.T) {
		var gotContentType string
		var gotMethod string
		c := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
			gotMethod = r.Method
			gotContentType = r.Header.Get("Content-Type")
			w.Write([]byte(`{"ignored":true}`))
		})
		if err := c.Get("/conversations", nil); err != nil {
			t.Fatal(err)
		}
		if gotMethod != http.MethodGet || gotContentType != "" {
			t.Errorf("method %q content-type %q", gotMethod, gotContentType)
		}
	})

	t.Run("non-2xx returns HTTPError with decoded JSON body", func(t *testing.T) {
		c := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(503)
			w.Write([]byte(`{"error":"fleet_full","message":"every slot in use"}`))
		})
		err := c.Get("/conversations", nil)
		var he *HTTPError
		if !errors.As(err, &he) {
			t.Fatalf("err = %v, want *HTTPError", err)
		}
		if he.Status != 503 || StatusCode(err) != 503 {
			t.Errorf("status = %d, StatusCode = %d", he.Status, StatusCode(err))
		}
		body, ok := he.Body.(map[string]any)
		if !ok || body["error"] != "fleet_full" {
			t.Errorf("body = %v", he.Body)
		}
	})

	t.Run("non-JSON error body is kept as a string", func(t *testing.T) {
		c := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(502)
			w.Write([]byte("bad gateway"))
		})
		err := c.Get("/x", nil)
		var he *HTTPError
		if !errors.As(err, &he) {
			t.Fatalf("err = %v, want *HTTPError", err)
		}
		if he.Body != "bad gateway" {
			t.Errorf("body = %v", he.Body)
		}
	})

	t.Run("empty 2xx body with non-nil out is not an error", func(t *testing.T) {
		c := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(204)
		})
		var out map[string]any
		if err := c.Delete("/agents/a1", &out); err != nil {
			t.Fatal(err)
		}
		if out != nil {
			t.Errorf("out = %v, want untouched nil map", out)
		}
	})

	t.Run("missing API key fails before any request", func(t *testing.T) {
		called := false
		c := newTestClient(t, func(w http.ResponseWriter, r *http.Request) { called = true })
		t.Setenv("FOUNTAIN_API_KEY", "")
		credentials.SetPathOverride("/nonexistent/credentials")
		t.Cleanup(func() { credentials.SetPathOverride("") })

		err := c.Get("/x", nil)
		if !errors.Is(err, config.ErrNoAPIKey) {
			t.Fatalf("err = %v, want ErrNoAPIKey", err)
		}
		if called {
			t.Error("request was sent despite missing key")
		}
	})
}

func TestNewStreamRequest(t *testing.T) {
	t.Setenv("FOUNTAIN_BASE_URL", "https://stream.example")
	t.Setenv("FOUNTAIN_API_KEY", "ftn_test_key")
	c := New(credentials.Opts{})

	req, err := c.NewStreamRequest(context.Background(), "/conversations/c1/stream", "ev-42")
	if err != nil {
		t.Fatal(err)
	}
	if req.URL.String() != "https://stream.example/api/conversations/c1/stream" {
		t.Errorf("url = %s", req.URL)
	}
	if req.Header.Get("Accept") != "text/event-stream" {
		t.Errorf("Accept = %q", req.Header.Get("Accept"))
	}
	if req.Header.Get("Last-Event-ID") != "ev-42" {
		t.Errorf("Last-Event-ID = %q", req.Header.Get("Last-Event-ID"))
	}

	req, err = c.NewStreamRequest(context.Background(), "/x", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, present := req.Header["Last-Event-Id"]; present {
		t.Error("Last-Event-ID header set despite empty id")
	}
}
