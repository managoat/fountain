package layers

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func TestUploadChecksDigestOriginAndNeverFollowsRedirects(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, "/other", 307)
			return
		}
		body, _ := io.ReadAll(r.Body)
		if r.Method != "PUT" || string(body) != "ciphertext" || r.Header.Get("Proxy-Authorization") != "" {
			t.Error("bad upload")
		}
		w.WriteHeader(204)
	}))
	defer server.Close()
	file := filepath.Join(t.TempDir(), "sealed")
	os.WriteFile(file, []byte("ciphertext"), 0600)
	hash := digest([]byte("ciphertext"))
	result, err := upload(context.Background(), server.URL, server.URL, file, hash, limits(), server.Client().Transport)
	if err != nil || result.SHA256 != hash || result.Bytes != 10 {
		t.Fatal(result, err)
	}
	if _, err := upload(context.Background(), server.URL, server.URL, file, "wrong", limits(), server.Client().Transport); err == nil {
		t.Fatal("wrong digest accepted")
	}
	if _, err := upload(context.Background(), server.URL, "https://elsewhere.example", file, hash, limits(), server.Client().Transport); err == nil {
		t.Fatal("wrong origin accepted")
	}
	if requests.Load() != 1 {
		t.Fatal("invalid upload sent network request")
	}
	if _, err := upload(context.Background(), server.URL+"/redirect", server.URL, file, hash, limits(), server.Client().Transport); err == nil {
		t.Fatal("redirect accepted")
	}
	if requests.Load() != 2 {
		t.Fatal("redirect followed")
	}
}
