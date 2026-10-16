// Package stream consumes a Fountain SSE conversation stream, surviving the
// disconnects the server produces by design.
//
// It was extracted from the CLI's `managoat run` path when `managoat acp`
// needed the same behaviour (#701). The loop is the part worth having exactly
// once: it encodes #398, where treating io.EOF as success made the CLI report
// a finished turn while the agent was still working. A second copy in the ACP
// adapter would be a second chance to reintroduce that, in the surface where
// it is hardest to notice — an editor showing a conversation that quietly
// stopped updating.
//
// What the loop does NOT decide is what an event *means*. Callers pass a
// Handler, because the CLI wants exit codes and human lines while the ACP
// adapter wants protocol notifications and a stop reason.
package stream

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"time"

	"github.com/managoat/managoat/cli/internal/env"
	"github.com/managoat/managoat/cli/internal/sse"
)

// Opener opens an SSE body, resuming after lastEventID when non-empty.
//
// Behind an interface so the reconnect logic can be tested without a server:
// the bug this package exists to prevent only appears across a disconnect,
// which is exactly the part that is awkward to reach through a real client.
type Opener func(ctx context.Context, lastEventID string) (io.ReadCloser, error)

// Permanent marks an attachment error that reconnecting cannot repair.
func Permanent(err error) error { return permanentError{err} }

type permanentError struct{ error }

func (e permanentError) Unwrap() error { return e.error }

// Handler decides what an event means. Returning terminal ends the follow;
// the error it returns (if any) is what Follow returns, so a handler reports a
// failed turn by returning (true, err) and a clean end by returning (true, nil).
type Handler func(ev sse.Event) (terminal bool, err error)

const (
	// DefaultIdle is how long to wait with no bytes at all before giving up.
	// The server closes its SSE loop after 60s of quiet, so this has to be
	// comfortably longer than that or every reconnect would look idle.
	DefaultIdle = 30 * time.Minute

	// DefaultRecovery bounds a deployment outage, independently of stream idle time.
	DefaultRecovery = 3 * time.Minute
)

// ErrIdleTimeout is returned when nothing arrived for the idle window. It is
// explicit rather than a silent success on purpose (#398).
var ErrIdleTimeout = errors.New("no output received")

// Backoff is a variable so tests do not have to sit through real sleeps to
// exercise the retry path.
var Backoff = func(attempt int) time.Duration {
	return min(time.Duration(attempt)*time.Second, 5*time.Second)
}

// IdleTimeout reads the idle window from the environment, falling back to
// DefaultIdle, so the wait can be widened without a rebuild.
func IdleTimeout() time.Duration {
	if v := env.Get("MANAGOAT_STREAM_IDLE_TIMEOUT"); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs > 0 {
			return time.Duration(secs) * time.Second
		}
	}
	return DefaultIdle
}

// Follow consumes an SSE stream until the handler calls an event terminal,
// reconnecting when the server closes the connection.
//
// A disconnect resumes from the last event id, so output produced while
// disconnected is replayed rather than lost, and only a terminal event or a
// genuine timeout ends the loop.
//
// A cancelled ctx ends the follow at the next event or reconnect.
//
// lastEventID seeds the first connection. Callers that pass the stream head
// skip the server's full-history replay — without that, the first `turn`/`done`
// in the replay of a prior turn ends the follow before the current turn has
// started (#398). convID appears only in the idle-timeout message, which is
// read by a human deciding whether to reattach.
func Follow(ctx context.Context, open Opener, idle time.Duration, convID, lastEventID string, h Handler, notify ...func(int, time.Duration, error)) error {
	return FollowWithRecovery(ctx, open, idle, RecoveryTimeout(), convID, lastEventID, h, notify...)
}

// RecoveryTimeout is the maximum reconnect interval, in seconds in the environment.
func RecoveryTimeout() time.Duration {
	if secs, err := strconv.Atoi(env.Get("MANAGOAT_STREAM_RECOVERY_TIMEOUT")); err == nil && secs > 0 {
		return time.Duration(secs) * time.Second
	}
	return DefaultRecovery
}

// FollowWithRecovery retries only attachment, never the request that submitted a prompt.
func FollowWithRecovery(ctx context.Context, open Opener, idle, recovery time.Duration, convID, lastEventID string, h Handler, notify ...func(int, time.Duration, error)) error {
	var lostAt time.Time
	failures := 0
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if lostAt.IsZero() {
			lostAt = time.Now()
		}
		attemptCtx, cancel := context.WithCancel(ctx)
		deadline := time.AfterFunc(max(time.Until(lostAt.Add(recovery)), 0), cancel)
		progress := false
		done, resumeID, err := once(attemptCtx, open, lastEventID, idle, h, func() {
			deadline.Stop()
			progress = true
		})
		deadline.Stop()
		cancel()
		if resumeID != "" {
			lastEventID = resumeID
		}
		if done {
			return err
		}
		var permanent permanentError
		if errors.As(err, &permanent) {
			return err
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if errors.Is(err, ErrIdleTimeout) {
			return fmt.Errorf("no output for %s — the turn may still be running; reattach with `managoat conv stream %s`", idle, convID)
		}
		if progress {
			lostAt = time.Time{}
			failures = 0
		}
		if lostAt.IsZero() {
			lostAt = time.Now()
		}
		remaining := time.Until(lostAt.Add(recovery))
		if remaining <= 0 {
			if err == nil {
				err = io.ErrUnexpectedEOF
			}
			return fmt.Errorf("stream temporarily unavailable for %s; reattach with `managoat conv stream %s` (after event %s): %w", recovery, convID, lastEventID, err)
		}
		failures++
		delay := min(Backoff(failures), remaining)
		if err != nil && len(notify) > 0 {
			notify[0](failures, delay, err)
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

// Once reads one connection to completion. It returns whether a terminal event
// was seen (with the handler's outcome as err — nil for a clean completion)
// and the id to resume from if the connection drops.
func Once(parent context.Context, open Opener, lastEventID string, idle time.Duration, h Handler) (bool, string, error) {
	return once(parent, open, lastEventID, idle, h, func() {})
}

func once(parent context.Context, open Opener, lastEventID string, idle time.Duration, h Handler, activityReceived func()) (bool, string, error) {
	// Derived from the caller's context, not Background: `managoat acp` ends a
	// follow when the editor goes away, and a loop that owned an independent
	// context would keep reading a stream nobody is listening to.
	ctx, cancel := context.WithCancel(parent)
	defer cancel()

	body, err := open(ctx, lastEventID)
	if err != nil {
		return false, "", err
	}
	defer body.Close()

	// Idle watchdog. A blocking Read cannot be given a deadline directly, so a
	// separate goroutine cancels the request context if nothing arrives.
	activity := make(chan struct{}, 1)
	idled := make(chan struct{})
	go watchIdle(ctx, cancel, activity, idled, idle)

	buf := make([]byte, 8192)
	var pending bytes.Buffer
	resumeID := lastEventID

	for {
		n, readErr := body.Read(buf)
		if n > 0 {
			activityReceived()
			select {
			case activity <- struct{}{}:
			default:
			}

			pending.Write(buf[:n])
			events, leftover := sse.Feed(pending.String())
			pending.Reset()
			pending.WriteString(leftover)

			for _, ev := range events {
				if ev.ID > 0 {
					if previous, _ := strconv.Atoi(resumeID); ev.ID <= previous {
						continue
					}
					resumeID = strconv.Itoa(ev.ID)
				}
				if terminal, termErr := h(ev); terminal {
					return true, resumeID, termErr
				}
			}
		}

		if readErr != nil {
			select {
			case <-idled:
				return false, resumeID, ErrIdleTimeout
			default:
			}
			if errors.Is(readErr, io.EOF) {
				return false, resumeID, nil
			}
			return false, resumeID, readErr
		}
	}
}

// watchIdle cancels the request context when nothing has arrived for `idle`.
// Cancelling is what actually unblocks the pending Read — closing `idled` alone
// would leave a genuinely stalled stream hanging forever, which is the failure
// this whole mechanism exists to remove.
func watchIdle(
	ctx context.Context,
	cancel context.CancelFunc,
	activity <-chan struct{},
	idled chan<- struct{},
	idle time.Duration,
) {
	timer := time.NewTimer(idle)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-activity:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(idle)
		case <-timer.C:
			close(idled)
			cancel()
			return
		}
	}
}
