package runner

// Backend is what a sandbox is made of on this machine.
//
// The daemon owns the wire — it frames requests, routes them, and renders
// replies — and a Backend owns the substance: what `create` brings into
// being, where a command runs, and what a session's output is journaled
// into. `fountain runner` ships one (Process, a directory and local
// processes, ADR 0022); a microVM backend is the reason this seam exists.
//
// Every method returns the same triple as Daemon.Handle: the reply's
// result, an optional `after` to run once the reply has been written, and
// an error. Errors must be *OpError with one of the contract's codes
// (notFound, invalid, unavailable, …); anything else reaches Fountain as
// `provider`, which the taxonomy classifies transient.
//
// The obligations below are Fountain's, not Go's — no compiler checks them
// and getting one wrong is how a sandbox holding an agent's memory gets
// destroyed. `Managoat.Sandbox`'s moduledoc (the managoat_sandbox hex
// package) is the normative statement and `Managoat.Sandbox.ConformanceCase`
// is its executable form; this is the same contract, said once more on the
// side that has to honour it.
type Backend interface {
	// Create brings a sandbox into being, or adopts the one already there.
	// Idempotent by contract: Fountain retries a create whose reply it lost,
	// and a second create must never discard the first one's disk.
	Create(req Request) (map[string]any, func(), error)

	// Get reports {"status": "running"|"suspended"}. It must answer
	// not_found only for a sandbox that definitively is not there, and
	// unavailable for everything transient — Fountain gives up a parked
	// disk on not_found, so a flaky answer here loses the agent's memory.
	Get(req Request) (map[string]any, func(), error)

	// Destroy removes the sandbox and stops whatever it was running.
	// Already-gone is success.
	Destroy(req Request) (map[string]any, func(), error)

	// List names every sandbox this backend holds, or refuses. Fountain's
	// reaper deletes against this view, so a partial list that looks whole
	// is the worst shape of wrong available here.
	List() (map[string]any, func(), error)

	// Suspend parks the sandbox: stop what runs, keep the disk. Resume
	// wakes it with the same disk — a resume onto a fresh one is data loss,
	// not a degradation.
	Suspend(req Request) (map[string]any, func(), error)
	Resume(req Request) (map[string]any, func(), error)

	// WriteFile writes req.Data (base64) to req.Path, creating parents. A
	// requested mode is a promise, not a hint.
	WriteFile(req Request) (map[string]any, func(), error)

	// Exec runs a command to completion and returns {"output", "code"}. It
	// never reports failure as an error: a command that exits nonzero, that
	// times out, or that could not start at all is a readable exit code.
	// An error means the sandbox was unreachable.
	Exec(req Request) (map[string]any, func(), error)

	// Spawn starts a streaming command and returns {"session_id"}. Its
	// `after` attaches the requester, which replays the session's journal
	// from byte zero tagged `replay_for` — never before the reply is on the
	// wire. Exactly one terminal frame per session, and it carries the
	// command's real exit code: a stream that ends without one is read by
	// Fountain as exit 0, which turns a failure into a success.
	Spawn(req Request, emit Emitter) (map[string]any, func(), error)

	// Stdin writes to a live session. Total: a write to a session that has
	// already exited is command_exited, never a crash and never a hang.
	Stdin(req Request) (map[string]any, func(), error)
	StdinClose(req Request) (map[string]any, func(), error)

	// Detach stops emitting a session's frames without stopping the
	// session. Detaching from something already gone is success.
	Detach(req Request) (map[string]any, func(), error)

	// ListSessions describes the sandbox's sessions, newest first — a
	// reattach after a Fountain deploy takes the first one.
	ListSessions(req Request) (map[string]any, func(), error)

	// Attach re-joins a session; like Spawn, the replay is in `after`.
	Attach(req Request, emit Emitter) (map[string]any, func(), error)

	// StopAll terminates every live session. The daemon calls it on the way
	// down: sessions belong to this process, and saying so beats leaving
	// orphans writing into a closed pipe.
	StopAll()
}
