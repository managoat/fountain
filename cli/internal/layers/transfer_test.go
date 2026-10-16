package layers

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestFetchStagesOnlyCompleteCiphertext(t *testing.T) {
	body := strings.Repeat("ciphertext", 100)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept-Encoding") != "identity" {
			t.Error("automatic compression allowed")
		}
		io.WriteString(w, body)
	}))
	defer server.Close()
	file := filepath.Join(t.TempDir(), "artifact")
	result, err := fetch(context.Background(), server.URL+"/layer?secret=never-log", server.URL, file, limits(), server.Client().Transport)
	if err != nil || result.SHA256 != digest([]byte(body)) || result.Bytes != int64(len(body)) {
		t.Fatalf("%+v %v", result, err)
	}
	contents, _ := os.ReadFile(file)
	if string(contents) != body {
		t.Fatal("incomplete artifact")
	}
	if _, err = fetch(context.Background(), server.URL, server.URL, file, limits(), server.Client().Transport); err == nil {
		t.Fatal("overwrote artifact")
	}
}
func TestFetchRejectsRedirectsLimitsAndErrors(t *testing.T) {
	var redirected atomic.Bool
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/redirect":
			http.Redirect(w, r, "/target", http.StatusFound)
		case "/target":
			redirected.Store(true)
			io.WriteString(w, "bad")
		case "/status":
			w.WriteHeader(403)
			io.WriteString(w, "secret=never-log")
		case "/encoding":
			w.Header().Set("Content-Encoding", "gzip")
			io.WriteString(w, "not ciphertext")
		case "/large":
			w.Header().Set("Content-Length", "10000")
			io.WriteString(w, strings.Repeat("x", 10000))
		case "/chunked":
			w.(http.Flusher).Flush()
			io.WriteString(w, strings.Repeat("x", 1000))
		case "/truncated":
			w.Header().Set("Content-Length", "100")
			io.WriteString(w, "short")
		case "/empty":
			w.WriteHeader(200)
		}
	}))
	defer server.Close()
	for _, name := range []string{"redirect", "status", "encoding", "large", "chunked", "truncated", "empty"} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			out := filepath.Join(dir, "artifact")
			l := limits()
			l.CipherBytes = 100
			_, err := fetch(context.Background(), server.URL+"/"+name+"?secret=never-log", server.URL, out, l, server.Client().Transport)
			if err != ErrTransfer {
				t.Fatalf("unsafe or verbose error: %v", err)
			}
			files, _ := os.ReadDir(dir)
			if len(files) != 0 {
				t.Fatalf("partial files remain: %v", files)
			}
		})
	}
	if redirected.Load() {
		t.Fatal("followed redirect")
	}
}
func TestFetchOriginAndDeadline(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer server.Close()
	for _, origin := range []string{"http://example.com", "https://other.example", server.URL + "/path", server.URL + "?query=bad"} {
		_, err := fetch(context.Background(), server.URL, origin, filepath.Join(t.TempDir(), "artifact"), limits(), server.Client().Transport)
		if err != ErrTransfer {
			t.Fatalf("accepted origin %q: %v", origin, err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := fetch(ctx, server.URL, server.URL, filepath.Join(t.TempDir(), "artifact"), limits(), server.Client().Transport)
	if err != ErrTransfer {
		t.Fatal(err)
	}
	l := limits()
	l.TimeoutSeconds = 1
	start := time.Now()
	_, err = fetch(context.Background(), server.URL, server.URL, filepath.Join(t.TempDir(), "artifact"), l, server.Client().Transport)
	if err != ErrTransfer || time.Since(start) > 3*time.Second {
		t.Fatalf("deadline not enforced: %v", err)
	}
}
