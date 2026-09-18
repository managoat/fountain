package runner

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// spriteHome is the home directory every Fountain provisioning script and
// runtime assumes (the Sprites base image; the E2B/Daytona images recreate
// it). The backend maps it to the sandbox directory in file paths, working
// directories, and command arguments, so those scripts land inside the
// sandbox without a Linux user of that name existing on this machine.
const spriteHome = "/home/sprite"

// suspendedMarker sits in a sandbox directory while it is parked: suspend
// stops its processes and leaves the marker, resume removes it.
const suspendedMarker = ".fountain-suspended"

// Process is the Backend of ADR 0022: a sandbox is a directory under Root,
// and its commands are processes on this machine, run as the daemon's user
// with HOME pointed at that directory.
//
// Trusted mode, and the only mode this backend has. There is no VM, no
// container, no egress policy between the agent and the machine — which is
// documented rather than mitigated, because the machine is the user's own.
type Process struct {
	Root     string
	RealHome string
	Log      Logger

	mu       sync.Mutex
	sessions map[string]*Session // by session id
	seq      int
}

// NewProcess builds the process backend over root, creating it if needed.
func NewProcess(root string, log Logger) (*Process, error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, fmt.Errorf("create sandbox root %s: %w", root, err)
	}
	home, _ := os.UserHomeDir()
	return &Process{Root: root, RealHome: home, Log: log, sessions: map[string]*Session{}}, nil
}

// ── sandboxes ────────────────────────────────────────────────────────────────

func (p *Process) dir(name string) (string, error) {
	if name == "" || strings.ContainsAny(name, "/\\") || name == "." || name == ".." ||
		strings.HasPrefix(name, ".") {
		return "", invalid("bad sandbox name")
	}
	return filepath.Join(p.Root, name), nil
}

// existingDir is dir plus a presence check.
func (p *Process) existingDir(name string) (string, error) {
	dir, err := p.dir(name)
	if err != nil {
		return "", err
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return "", notFound("no sandbox " + name)
	}
	return dir, nil
}

// Create implements Backend.
func (p *Process) Create(req Request) (map[string]any, func(), error) {
	dir, err := p.dir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	// Idempotent-adopting: an existing directory is the same sandbox.
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, nil, unavailable(err.Error())
	}
	return map[string]any{}, nil, nil
}

// Get implements Backend.
func (p *Process) Get(req Request) (map[string]any, func(), error) {
	dir, err := p.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	status := "running"
	if _, err := os.Stat(filepath.Join(dir, suspendedMarker)); err == nil {
		status = "suspended"
	}
	return map[string]any{"status": status, "path": dir}, nil, nil
}

// Destroy implements Backend.
func (p *Process) Destroy(req Request) (map[string]any, func(), error) {
	dir, err := p.dir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	p.stopSessions(req.Name)
	p.mu.Lock()
	for id, s := range p.sessions {
		if s.sandbox == req.Name {
			delete(p.sessions, id)
		}
	}
	p.mu.Unlock()
	// Already gone is ok.
	if err := os.RemoveAll(dir); err != nil {
		return nil, nil, unavailable(err.Error())
	}
	return map[string]any{}, nil, nil
}

// List implements Backend.
func (p *Process) List() (map[string]any, func(), error) {
	entries, err := os.ReadDir(p.Root)
	if err != nil {
		return nil, nil, unavailable(err.Error())
	}
	names := []string{}
	for _, e := range entries {
		if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return map[string]any{"names": names}, nil, nil
}

// Suspend implements Backend.
func (p *Process) Suspend(req Request) (map[string]any, func(), error) {
	dir, err := p.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	// Parking = stop what is running, keep the disk. Nothing else costs
	// anything on a machine that stays up.
	p.stopSessions(req.Name)
	if err := os.WriteFile(filepath.Join(dir, suspendedMarker), nil, 0o600); err != nil {
		return nil, nil, unavailable(err.Error())
	}
	return map[string]any{}, nil, nil
}

// Resume implements Backend.
func (p *Process) Resume(req Request) (map[string]any, func(), error) {
	dir, err := p.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	_ = os.Remove(filepath.Join(dir, suspendedMarker))
	return map[string]any{}, nil, nil
}

// ── files ────────────────────────────────────────────────────────────────────

// mapPath resolves a path Fountain names into the sandbox: `/home/sprite/…`
// and relative paths land inside the sandbox directory; other absolute paths
// are the host's (trusted mode — /tmp is /tmp).
func mapPath(dir, p string) string {
	switch {
	case p == spriteHome:
		return dir
	case strings.HasPrefix(p, spriteHome+"/"):
		return filepath.Join(dir, strings.TrimPrefix(p, spriteHome+"/"))
	case p == "~":
		return dir
	case strings.HasPrefix(p, "~/"):
		return filepath.Join(dir, p[2:])
	case filepath.IsAbs(p):
		return p
	case p == "":
		return dir
	default:
		return filepath.Join(dir, p)
	}
}

// mapArg rewrites the literal /home/sprite wherever it appears in a command
// or argument, so `bin=/home/sprite/.local/bin/x` in a `bash -lc` script
// resolves inside the sandbox too.
func mapArg(dir, arg string) string {
	return strings.ReplaceAll(arg, spriteHome, dir)
}

// WriteFile implements Backend.
func (p *Process) WriteFile(req Request) (map[string]any, func(), error) {
	dir, err := p.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	data, err := base64.StdEncoding.DecodeString(req.Data)
	if err != nil {
		return nil, nil, invalid("data is not base64")
	}
	target := mapPath(dir, req.Path)
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return nil, nil, writeFailed(err.Error())
	}
	mode := os.FileMode(0o644)
	if req.Mode != nil {
		mode = os.FileMode(*req.Mode)
	}
	if err := os.WriteFile(target, data, mode); err != nil {
		return nil, nil, writeFailed(err.Error())
	}
	// WriteFile's mode is subject to umask; a requested mode is a promise.
	if req.Mode != nil {
		_ = os.Chmod(target, mode)
	}
	return map[string]any{}, nil, nil
}

// ── commands ─────────────────────────────────────────────────────────────────

// command builds the exec.Cmd for a request inside a sandbox: HOME is the
// sandbox, PATH gains the sandbox's own bin dirs, npm installs globally into
// the sandbox, and the request's env pairs win over all of it.
func (p *Process) command(ctx context.Context, dir string, req Request) *exec.Cmd {
	args := make([]string, len(req.Args))
	for i, a := range req.Args {
		args[i] = mapArg(dir, a)
	}
	env := p.env(dir, req.Env)
	// os/exec resolves a bare command name against the *daemon's* PATH; the
	// agent CLIs provisioning installs live on the sandbox's PATH
	// (`<sandbox>/.local/bin`, `.npm-global/bin`), so resolve there.
	cmd := exec.CommandContext(ctx, lookPath(mapArg(dir, req.Cmd), env), args...)
	cmd.Dir = mapPath(dir, req.Dir)
	if st, err := os.Stat(cmd.Dir); err != nil || !st.IsDir() {
		cmd.Dir = dir
	}
	cmd.Env = env
	return cmd
}

// lookPath resolves name against the PATH inside env (not the process's).
// A name that resolves nowhere is returned unchanged so the failure reads
// as "not found" when the command runs.
func lookPath(name string, env []string) string {
	if strings.Contains(name, "/") {
		return name
	}
	for _, kv := range env {
		if !strings.HasPrefix(kv, "PATH=") {
			continue
		}
		for _, p := range filepath.SplitList(strings.TrimPrefix(kv, "PATH=")) {
			if p == "" {
				continue
			}
			candidate := filepath.Join(p, name)
			if st, err := os.Stat(candidate); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
				return candidate
			}
		}
		break
	}
	return name
}

func (p *Process) env(dir string, pairs [][]string) []string {
	base := map[string]string{}
	order := []string{}
	set := func(k, v string) {
		if _, ok := base[k]; !ok {
			order = append(order, k)
		}
		base[k] = v
	}
	for _, kv := range os.Environ() {
		if i := strings.IndexByte(kv, '='); i > 0 {
			set(kv[:i], kv[i+1:])
		}
	}
	sandboxBins := strings.Join([]string{
		filepath.Join(dir, ".local", "bin"),
		filepath.Join(dir, ".npm-global", "bin"),
		filepath.Join(dir, ".bun", "bin"),
	}, string(os.PathListSeparator))
	extra := []string{}
	for _, path := range []string{"/opt/homebrew/bin", "/usr/local/bin", filepath.Join(p.RealHome, ".local", "bin"), filepath.Join(p.RealHome, ".bun", "bin")} {
		if st, err := os.Stat(path); err == nil && st.IsDir() && !strings.Contains(base["PATH"], path) {
			extra = append(extra, path)
		}
	}
	path := sandboxBins + string(os.PathListSeparator) + base["PATH"]
	if len(extra) > 0 {
		path += string(os.PathListSeparator) + strings.Join(extra, string(os.PathListSeparator))
	}
	set("PATH", path)
	set("HOME", dir)
	set("npm_config_prefix", filepath.Join(dir, ".npm-global"))
	if _, ok := base["npm_config_cache"]; !ok && p.RealHome != "" {
		set("npm_config_cache", filepath.Join(p.RealHome, ".npm"))
	}
	set("FOUNTAIN_SANDBOX_DIR", dir)
	for _, kv := range pairs {
		if len(kv) == 2 {
			set(kv[0], kv[1])
		}
	}
	out := make([]string, 0, len(order))
	for _, k := range order {
		out = append(out, k+"="+base[k])
	}
	return out
}

// Exec implements Backend.
func (p *Process) Exec(req Request) (map[string]any, func(), error) {
	dir, err := p.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	ctx := context.Background()
	if req.TimeoutMS != nil && *req.TimeoutMS > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(*req.TimeoutMS)*time.Millisecond)
		defer cancel()
	}
	cmd := p.command(ctx, dir, req)
	out, runErr := execProcessOutput(cmd, req.StderrToStdout)
	code := 0
	if runErr != nil {
		var exitErr *exec.ExitError
		switch {
		case errors.As(runErr, &exitErr):
			code = exitErr.ExitCode()
			if code < 0 {
				code = 137 // killed (timeout)
			}
		case errors.Is(runErr, exec.ErrWaitDelay):
			code = 124
			out = append(out, []byte("\nfountain runner: command output did not close\n")...)
		case errors.Is(ctx.Err(), context.DeadlineExceeded):
			code = 124
			out = append(out, []byte("\nfountain runner: command timed out\n")...)
		default:
			// Could not start at all (not found, not executable): data, not a
			// raise — the contract's "nonzero exit is readable".
			code = 127
			out = append(out, []byte(runErr.Error()+"\n")...)
		}
	}
	return map[string]any{
		"output": base64.StdEncoding.EncodeToString(out),
		"code":   code,
	}, nil, nil
}

// execOutputDrainTimeout bounds collection after the command exits. A process
// that leaves the command's group can otherwise hold its output pipe forever.
const execOutputDrainTimeout = 250 * time.Millisecond

// execProcessOutput owns the one-shot command's process group and output pipe.
// Cancellation kills the group, including ordinary children; parent exit also
// kills remaining group members before returning. Use Spawn for long-lived work.
//
// Process groups are not a security boundary: children can leave them using
// setsid/setpgid, and SIGKILL does not provide durable proof of quiescence after
// daemon loss. This is not the complete file-read/lifecycle exclusion protocol.
func execProcessOutput(cmd *exec.Cmd, stderrToStdout bool) ([]byte, error) {
	reader, writer, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	cmd.Stdout = writer
	if stderrToStdout {
		cmd.Stderr = writer
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	killGroup := func() error {
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.Cancel = killGroup
	if err := cmd.Start(); err != nil {
		_ = writer.Close()
		return nil, err
	}
	// Only child processes keep the write end. Use our own reader so Wait
	// observes the parent exiting without waiting for descendants' output.
	_ = writer.Close()
	var output bytes.Buffer
	drained := make(chan error, 1)
	go func() {
		_, err := io.Copy(&output, reader)
		drained <- err
	}()
	runErr := cmd.Wait()
	killErr := killGroup()
	if killErr != nil && !errors.Is(killErr, os.ErrProcessDone) {
		runErr = errors.Join(runErr, fmt.Errorf("stop command process group: %w", killErr))
	}
	timer := time.NewTimer(execOutputDrainTimeout)
	defer timer.Stop()
	select {
	case drainErr := <-drained:
		if drainErr != nil {
			runErr = errors.Join(runErr, drainErr)
		}
	case <-timer.C:
		// Closing our descriptor interrupts io.Copy even if an escaped child
		// still holds the write end. Join before reading its buffer.
		_ = reader.Close()
		<-drained
		runErr = errors.Join(runErr, exec.ErrWaitDelay)
	}
	return output.Bytes(), runErr
}

// ── sessions ─────────────────────────────────────────────────────────────────

// Spawn implements Backend.
func (p *Process) Spawn(req Request, emit Emitter) (map[string]any, func(), error) {
	dir, err := p.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	p.mu.Lock()
	p.seq++
	id := fmt.Sprintf("s-%d-%d", time.Now().Unix(), p.seq)
	p.mu.Unlock()

	cmd := p.command(context.Background(), dir, req)
	s, err := startSession(id, req.Name, cmd, req.Stdin, emit, p.Log)
	if err != nil {
		// Never a raise: a command that cannot start is a session that exited
		// 127 with the reason on stdout, so the owner reads it like any other
		// failed process.
		s = failedSession(id, req.Name, req.Cmd, err, emit)
	}
	p.mu.Lock()
	p.sessions[id] = s
	p.pruneLocked(req.Name)
	p.mu.Unlock()

	reqID := req.ID
	after := func() { s.attach(reqID, emit) }
	return map[string]any{"session_id": id}, after, nil
}

// pruneLocked bounds the finished sessions retained per sandbox for replay.
func (p *Process) pruneLocked(sandbox string) {
	const keep = 100
	var finished []*Session
	for _, s := range p.sessions {
		if s.sandbox == sandbox && s.exited() {
			finished = append(finished, s)
		}
	}
	if len(finished) <= keep {
		return
	}
	sort.Slice(finished, func(i, j int) bool { return finished[i].createdAt.Before(finished[j].createdAt) })
	for _, s := range finished[:len(finished)-keep] {
		delete(p.sessions, s.id)
	}
}

func (p *Process) session(id string) (*Session, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	s, ok := p.sessions[id]
	if !ok {
		return nil, notFound("no session " + id)
	}
	return s, nil
}

// Stdin implements Backend.
func (p *Process) Stdin(req Request) (map[string]any, func(), error) {
	s, err := p.session(req.SessionID)
	if err != nil {
		return nil, nil, err
	}
	data, err := base64.StdEncoding.DecodeString(req.Data)
	if err != nil {
		return nil, nil, invalid("data is not base64")
	}
	if err := s.write(data); err != nil {
		return nil, nil, err
	}
	return map[string]any{}, nil, nil
}

// StdinClose implements Backend.
func (p *Process) StdinClose(req Request) (map[string]any, func(), error) {
	s, err := p.session(req.SessionID)
	if err != nil {
		return nil, nil, err
	}
	s.closeStdin()
	return map[string]any{}, nil, nil
}

// Detach implements Backend.
func (p *Process) Detach(req Request) (map[string]any, func(), error) {
	s, err := p.session(req.SessionID)
	if err != nil {
		// Detaching from something that is gone is fine.
		return map[string]any{}, nil, nil
	}
	s.detach()
	return map[string]any{}, nil, nil
}

// ListSessions implements Backend.
func (p *Process) ListSessions(req Request) (map[string]any, func(), error) {
	if _, err := p.existingDir(req.Name); err != nil {
		return nil, nil, err
	}
	p.mu.Lock()
	var list []*Session
	for _, s := range p.sessions {
		if s.sandbox == req.Name {
			list = append(list, s)
		}
	}
	p.mu.Unlock()
	// Newest first: reattach takes the first session, and the turn in flight
	// is the most recent spawn.
	sort.Slice(list, func(i, j int) bool { return list[i].createdAt.After(list[j].createdAt) })
	out := make([]map[string]any, 0, len(list))
	for _, s := range list {
		out = append(out, s.describe())
	}
	return map[string]any{"sessions": out}, nil, nil
}

// Attach implements Backend.
func (p *Process) Attach(req Request, emit Emitter) (map[string]any, func(), error) {
	s, err := p.session(req.SessionID)
	if err != nil {
		return nil, nil, err
	}
	reqID := req.ID
	return map[string]any{"session_id": s.id}, func() { s.attach(reqID, emit) }, nil
}

// stopSessions terminates every live session of a sandbox (suspend/destroy).
func (p *Process) stopSessions(sandbox string) {
	p.mu.Lock()
	var live []*Session
	for _, s := range p.sessions {
		if s.sandbox == sandbox && !s.exited() {
			live = append(live, s)
		}
	}
	p.mu.Unlock()
	for _, s := range live {
		s.terminate(5 * time.Second)
	}
}

// StopAll implements Backend.
func (p *Process) StopAll() {
	p.mu.Lock()
	var live []*Session
	for _, s := range p.sessions {
		if !s.exited() {
			live = append(live, s)
		}
	}
	p.mu.Unlock()
	for _, s := range live {
		s.terminate(3 * time.Second)
	}
}
