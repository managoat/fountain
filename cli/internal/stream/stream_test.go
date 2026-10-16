package stream

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/managoat/managoat/cli/internal/sse"
)

func TestRolloutRecovery(t *testing.T) {
	for _, outage := range []time.Duration{30 * time.Second, 120 * time.Second} {
		t.Run(outage.String(), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				start := time.Now()
				calls := 0
				delivered := 0
				open := func(ctx context.Context, cursor string) (io.ReadCloser, error) {
					calls++
					if calls == 1 {
						return io.NopCloser(strings.NewReader("id: 7\nevent: output\ndata: {}\n\n")), nil
					}
					if cursor != "7" {
						t.Fatalf("lost cursor: %q", cursor)
					}
					if time.Since(start) < outage {
						return nil, errors.New("HTTP 503")
					}
					return io.NopCloser(strings.NewReader("id: 7\nevent: output\ndata: {}\n\nid: 8\nevent: stage\ndata: {}\n\n")), nil
				}
				err := Follow(context.Background(), open, time.Minute, "c1", "", func(ev sse.Event) (bool, error) { delivered++; return ev.ID == 8, nil })
				if err != nil || delivered != 2 {
					t.Fatalf("error=%v delivered=%d", err, delivered)
				}
			})
		})
	}
}

func TestRecoveryCancellation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		time.AfterFunc(100*time.Millisecond, cancel)
		start := time.Now()
		err := Follow(ctx, func(context.Context, string) (io.ReadCloser, error) { return nil, errors.New("503") }, time.Minute, "c1", "", func(sse.Event) (bool, error) { return false, nil })
		if !errors.Is(err, context.Canceled) || time.Since(start) != 100*time.Millisecond {
			t.Fatalf("%v after %s", err, time.Since(start))
		}
	})
}

func TestEmptyConnectionsExhaustRecovery(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		start := time.Now()
		err := FollowWithRecovery(context.Background(), func(context.Context, string) (io.ReadCloser, error) { return io.NopCloser(strings.NewReader("")), nil }, time.Minute, 30*time.Second, "c1", "7", func(sse.Event) (bool, error) { return false, nil })
		if err == nil || time.Since(start) != 30*time.Second {
			t.Fatalf("%v after %s", err, time.Since(start))
		}
	})
}

func TestRecoveryDeadlineDoesNotStopAHealthyStream(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		open := func(ctx context.Context, _ string) (io.ReadCloser, error) {
			reader, writer := io.Pipe()
			go func() {
				defer writer.Close()
				_, _ = io.WriteString(writer, ": heartbeat\n\n")
				time.Sleep(time.Minute)
				if ctx.Err() != nil {
					t.Errorf("healthy stream cancelled: %v", ctx.Err())
				}
				_, _ = io.WriteString(writer, "id: 8\nevent: stage\ndata: {}\n\n")
			}()
			return reader, nil
		}
		err := FollowWithRecovery(context.Background(), open, 2*time.Minute, 10*time.Second, "c1", "", func(ev sse.Event) (bool, error) { return ev.ID == 8, nil })
		if err != nil {
			t.Fatal(err)
		}
	})
}

func TestPermanentAttachmentFailureDoesNotRetry(t *testing.T) {
	calls := 0
	denied := errors.New("HTTP 403")
	err := Follow(context.Background(), func(context.Context, string) (io.ReadCloser, error) { calls++; return nil, Permanent(denied) }, time.Minute, "c1", "", func(sse.Event) (bool, error) { return false, nil })
	if err == nil || calls != 1 {
		t.Fatalf("calls=%d err=%v", calls, err)
	}
}

func TestMalformedEventDoesNotAdvanceCursor(t *testing.T) {
	body := "id: 99\nevent: output\ndata: {broken\n\nid: 2\nevent: stage\ndata: {}\n\n"
	var seen []int
	err := Follow(context.Background(), func(context.Context, string) (io.ReadCloser, error) {
		return io.NopCloser(strings.NewReader(body)), nil
	}, time.Minute, "c1", "", func(ev sse.Event) (bool, error) { seen = append(seen, ev.ID); return true, nil })
	if err != nil || len(seen) != 1 || seen[0] != 2 {
		t.Fatalf("err=%v seen=%v", err, seen)
	}
}
