package runner

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// A server that accepts the socket and then goes quiet, as Fountain looks
// from a host that was suspended: nothing answers a ping.
func TestServeReturnsWhenPingsGoUnanswered(t *testing.T) {
	answer := make(chan bool, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		if <-answer {
			// Reading is what answers pings.
			conn.Read(r.Context())
			return
		}
		<-r.Context().Done()
	}))
	defer srv.Close()

	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	d, err := New(t.TempDir(), log)
	if err != nil {
		t.Fatal(err)
	}
	cfg := Config{BaseURL: srv.URL, Token: "t", Name: "r", Root: t.TempDir(), PingEvery: 50 * time.Millisecond, PingTimeout: 100 * time.Millisecond}

	// Answered pings keep the socket up.
	answer <- true
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if err := serve(ctx, cfg, d, log); ctx.Err() == nil {
		t.Fatalf("serve returned while pings were answered: %v", err)
	}

	// Unanswered pings close it, so Run reconnects.
	answer <- false
	ctx2, cancel2 := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel2()
	start := time.Now()
	err = serve(ctx2, cfg, d, log)
	if ctx2.Err() != nil {
		t.Fatal("serve never noticed the silent server")
	}
	if err == nil {
		t.Fatal("serve returned nil; Run would treat a dead socket as a clean close")
	}
	if waited := time.Since(start); waited > time.Second {
		t.Fatalf("took %s to notice", waited)
	}
}
