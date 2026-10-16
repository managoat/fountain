package layers

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

type testSyncFile struct {
	sync  func() error
	close func() error
}

func (f testSyncFile) Sync() error  { return f.sync() }
func (f testSyncFile) Close() error { return f.close() }

func TestFileSyncsOverlapAndFinishWaitsForEveryClose(t *testing.T) {
	s := newFileSyncer(context.Background())
	started := make(chan struct{}, 8)
	release := make(chan struct{})
	var closed atomic.Int32
	for range 8 {
		if err := s.enqueue(testSyncFile{
			sync:  func() error { started <- struct{}{}; <-release; return nil },
			close: func() error { closed.Add(1); return nil },
		}); err != nil {
			t.Fatal(err)
		}
	}
	for range 8 {
		select {
		case <-started:
		case <-time.After(5 * time.Second):
			close(release)
			_ = s.finish()
			t.Fatal("syncs did not overlap")
		}
	}
	done := make(chan error, 1)
	go func() {
		err := s.finish()
		if closed.Load() != 8 {
			err = errors.New("finish returned before every close")
		}
		done <- err
	}()
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestFileSyncFailureStillClosesEveryFile(t *testing.T) {
	for _, onClose := range []bool{false, true} {
		s := newFileSyncer(context.Background())
		failure := errors.New("storage failure")
		var closed atomic.Int32
		for range 32 {
			_ = s.enqueue(testSyncFile{
				sync: func() error {
					if !onClose {
						return failure
					}
					return nil
				},
				close: func() error {
					closed.Add(1)
					if onClose {
						return failure
					}
					return nil
				},
			})
		}
		if err := s.finish(); !errors.Is(err, failure) {
			t.Fatalf("failure lost: %v", err)
		}
		if closed.Load() != 32 {
			t.Fatalf("closed %d files", closed.Load())
		}
	}
}

func TestCanceledFileSyncClosesWithoutStartingIO(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	s := newFileSyncer(ctx)
	var closed, synced atomic.Int32
	for range 32 {
		_ = s.enqueue(testSyncFile{
			sync:  func() error { synced.Add(1); return nil },
			close: func() error { closed.Add(1); return nil },
		})
	}
	err := s.finish()
	if !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if closed.Load() != 32 || synced.Load() != 0 {
		t.Fatalf("closed=%d synced=%d", closed.Load(), synced.Load())
	}
}
