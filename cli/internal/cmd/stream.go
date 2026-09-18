package cmd

import (
	"context"
	"errors"
	"io"
	"time"

	"github.com/managoat/fountain/cli/internal/stream"
)

// streamOpener opens an SSE body, resuming after lastEventID when non-empty.
type streamOpener = stream.Opener

// The follow loop itself lives in internal/stream — `fountain acp` needs the
// same reconnect behaviour, and #398 is not a bug worth having two chances to
// reintroduce. What stays here is what the CLI means by an event: exit codes,
// the human lines, and the terminal outcomes below.
var (
	errIdleTimeout = stream.ErrIdleTimeout

	// Terminal outcomes that must surface as a non-zero exit (#398). Before
	// this, `turn`/`failed`, `provision`/`failed` and a `turn`/`done` with a
	// non-zero exit_code all returned nil, so `fountain run` in CI reported
	// success for a crashed agent or a sandbox that never came up.
	errTurnFailed       = errors.New("turn failed")
	errProvisionFailed  = errors.New("provisioning failed — the sandbox never started")
	errReattachFailed   = errors.New("reattach failed — the sandbox could not be re-armed")
	errSandboxExpired   = errors.New("sandbox hit its max lifetime")
	errPromptNotStarted = errors.New("prompt was not started — send it again shortly")
)

// streamIdleTimeout allows the wait to be widened or narrowed without a rebuild.
func streamIdleTimeout() time.Duration { return stream.IdleTimeout() }

// followStream consumes an SSE stream until the turn reaches a terminal state,
// printing output as it goes. See internal/stream for the reconnect semantics
// and handleEvent (conv.go) for what the CLI does with each event.
func followStream(open streamOpener, idle time.Duration, convID, lastEventID string) error {
	return stream.Follow(context.Background(), open, idle, convID, lastEventID, handleEvent)
}

// Compile-time proof the opener signature has not drifted from the package it
// now comes from; the alias above would otherwise fail far from here.
var _ func(context.Context, string) (io.ReadCloser, error) = (streamOpener)(nil)
