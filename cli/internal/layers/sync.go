package layers

import (
	"context"
	"sync"
)

// Keep individual file durability, but overlap storage round trips. At most
// eight files are syncing and eight await a worker; every accepted file is
// closed and every worker joined before extraction returns, including failure.
type syncFile interface {
	Sync() error
	Close() error
}
type fileSyncer struct {
	ctx     context.Context
	files   chan syncFile
	workers sync.WaitGroup
	mu      sync.Mutex
	err     error
}

func newFileSyncer(ctx context.Context) *fileSyncer {
	s := &fileSyncer{ctx: ctx, files: make(chan syncFile, 8)}
	for range 8 {
		s.workers.Go(func() {
			for f := range s.files {
				err := s.ctx.Err()
				if err == nil {
					err = f.Sync()
				}
				closeErr := f.Close()
				if err == nil {
					err = closeErr
				}
				s.mu.Lock()
				if s.err == nil {
					s.err = err
				}
				s.mu.Unlock()
			}
		})
	}
	return s
}
func (s *fileSyncer) failure() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err
}

// enqueue takes ownership even when it refuses a file.
func (s *fileSyncer) enqueue(f syncFile) error {
	if err := s.failure(); err != nil {
		_ = f.Close()
		return err
	}
	select {
	case <-s.ctx.Done():
		_ = f.Close()
		return s.ctx.Err()
	case s.files <- f:
		return nil
	}
}
func (s *fileSyncer) finish() error {
	close(s.files)
	s.workers.Wait()
	if err := s.failure(); err != nil {
		return err
	}
	return s.ctx.Err()
}
