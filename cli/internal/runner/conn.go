package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Config is what a runner needs to connect.
type Config struct {
	BaseURL string // https://fountain.example — the socket is /api/runners/ws
	Token   string // the user's API key (full scope)
	Name    string // unique per account
	Root    string // sandbox root on this machine
	Version string // reported to Fountain

	// Keepalive. Zero means the defaults below; tests shorten them.
	PingEvery   time.Duration
	PingTimeout time.Duration
}

// A host that suspends (a sprite between requests, a laptop lid) leaves the
// socket half-open: Read never returns, and Fountain has long since marked
// the runner offline. An unanswered ping closes the socket so Run reconnects.
const (
	defaultPingEvery   = 10 * time.Second
	defaultPingTimeout = 5 * time.Second
)

// Permanent is returned by Run when reconnecting cannot help: a rejected
// credential, runners disabled on the instance, a bad name.
type Permanent struct{ Reason string }

func (p *Permanent) Error() string { return p.Reason }

// wsEmitter serializes frames onto one socket.
type wsEmitter struct {
	mu   sync.Mutex
	conn *websocket.Conn
	ctx  context.Context
	log  Logger
}

func (e *wsEmitter) Emit(f Frame) {
	e.mu.Lock()
	defer e.mu.Unlock()
	ctx, cancel := context.WithTimeout(e.ctx, 30*time.Second)
	defer cancel()
	if err := e.conn.Write(ctx, websocket.MessageText, Marshal(f)); err != nil {
		e.log.Debug("runner: write failed", "err", err)
	}
}

// Run connects, serves until the socket drops, and reconnects with backoff
// until ctx ends. It returns nil on ctx cancellation and *Permanent when
// retrying is pointless.
func Run(ctx context.Context, cfg Config, d *Daemon, log Logger) error {
	attempt := 0
	for {
		err := serve(ctx, cfg, d, log)
		if ctx.Err() != nil {
			return nil
		}
		var perm *Permanent
		if errors.As(err, &perm) {
			return err
		}
		if err == nil {
			attempt = 0
		} else {
			attempt++
		}
		delay := backoff(attempt)
		log.Warn("runner: disconnected; reconnecting", "in", delay.String(), "err", errString(err))
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(delay):
		}
	}
}

func errString(err error) string {
	if err == nil {
		return "closed"
	}
	return err.Error()
}

// backoff is 1s, 2s, 4s … capped at 30s.
func backoff(attempt int) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	d := time.Second << uint(attempt-1)
	if d > 30*time.Second {
		d = 30 * time.Second
	}
	return d
}

// SocketURL is the WebSocket URL for a base URL and runner identity.
func SocketURL(cfg Config) (string, error) {
	u, err := url.Parse(strings.TrimRight(cfg.BaseURL, "/"))
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	default:
		return "", fmt.Errorf("base URL must be http(s), got %q", cfg.BaseURL)
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/api/runners/ws"
	host, _ := os.Hostname()
	q := url.Values{}
	q.Set("name", cfg.Name)
	q.Set("hostname", host)
	q.Set("os", runtime.GOOS)
	q.Set("arch", runtime.GOARCH)
	q.Set("version", cfg.Version)
	q.Set("root", cfg.Root)
	u.RawQuery = q.Encode()
	return u.String(), nil
}

func serve(ctx context.Context, cfg Config, d *Daemon, log Logger) error {
	target, err := SocketURL(cfg)
	if err != nil {
		return &Permanent{Reason: err.Error()}
	}
	dialCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	conn, resp, err := websocket.Dial(dialCtx, target, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + cfg.Token}},
	})
	if err != nil {
		if resp != nil {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			switch resp.StatusCode {
			case http.StatusUnauthorized, http.StatusForbidden:
				return &Permanent{Reason: fmt.Sprintf("Fountain refused the API key (%d): %s", resp.StatusCode, strings.TrimSpace(string(body)))}
			case http.StatusNotFound:
				return &Permanent{Reason: "self-hosted runners are disabled on this Fountain instance"}
			case http.StatusBadRequest:
				return &Permanent{Reason: fmt.Sprintf("Fountain rejected the runner (%d): %s", resp.StatusCode, strings.TrimSpace(string(body)))}
			case http.StatusConflict:
				return fmt.Errorf("a runner named %q is already connected for this account", cfg.Name)
			}
			return fmt.Errorf("connect: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
		}
		return fmt.Errorf("connect: %w", err)
	}
	defer conn.CloseNow()
	// ACP turns can carry large tool output; the server caps its own frames.
	conn.SetReadLimit(64 << 20)

	log.Info("runner: connected", "name", cfg.Name, "url", cfg.BaseURL, "root", cfg.Root)
	emitter := &wsEmitter{conn: conn, ctx: ctx, log: log}
	pingCtx, stopPing := context.WithCancel(ctx)
	defer stopPing()
	go keepAlive(pingCtx, conn, cfg, log)

	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			status := websocket.CloseStatus(err)
			switch status {
			case 4409:
				return fmt.Errorf("a runner named %q is already connected for this account", cfg.Name)
			case 4404:
				return errors.New("this runner was deleted in Fountain; it will re-register on reconnect")
			case websocket.StatusNormalClosure, websocket.StatusGoingAway:
				return nil
			}
			return err
		}
		var req Request
		if err := json.Unmarshal(data, &req); err != nil {
			log.Warn("runner: bad frame", "err", err)
			continue
		}
		go dispatch(d, req, emitter, log)
	}
}

// keepAlive pings until ctx ends, and closes the socket when a ping goes
// unanswered. Pongs arrive through serve's Read loop.
func keepAlive(ctx context.Context, conn *websocket.Conn, cfg Config, log Logger) {
	every, timeout := cfg.PingEvery, cfg.PingTimeout
	if every <= 0 {
		every = defaultPingEvery
	}
	if timeout <= 0 {
		timeout = defaultPingTimeout
	}
	tick := time.NewTicker(every)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		pingCtx, cancel := context.WithTimeout(ctx, timeout)
		err := conn.Ping(pingCtx)
		cancel()
		if err != nil {
			if ctx.Err() == nil {
				log.Warn("runner: ping unanswered; reconnecting", "err", err)
				conn.CloseNow()
			}
			return
		}
	}
}

func dispatch(d *Daemon, req Request, emit *wsEmitter, log Logger) {
	result, after, err := d.Handle(req, emit)
	if err != nil {
		var op *OpError
		if !errors.As(err, &op) || op.Code == "unavailable" || op.Code == "provider" {
			log.Warn("runner: request failed", "op", req.Op, "name", req.Name, "err", err)
		}
	}
	// The reply goes out under the emitter's lock, and `after` (a journal
	// replay) only starts once it has: order on the wire is reply, replay,
	// live — the order Fountain depends on.
	emit.Emit(Reply(req.ID, result, err))
	if after != nil {
		after()
	}
}
