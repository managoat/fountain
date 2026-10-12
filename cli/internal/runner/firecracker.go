package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// guestSandbox is the sandbox name used *inside* every microVM.
//
// The guest agent serves the ordinary Process backend rooted at /home, so
// the one sandbox it holds is "sprite" and its directory is /home/sprite —
// which makes the backend's /home/sprite path mapping the identity. A
// provisioning script that writes /home/sprite/.env writes exactly there,
// the way it does on Sprites and E2B, with no rewriting on either
// side of the vsock.
const guestSandbox = "sprite"

// FirecrackerConfig is what the microVM backend needs from the operator.
type FirecrackerConfig struct {
	Root        string // per-sandbox state: the rootfs copy, the sockets, the log
	Binary      string // the firecracker executable
	Kernel      string // an uncompressed kernel image (vmlinux)
	BaseRootfs  string // the ext4 image every sandbox starts as a copy of
	VCPUs       int
	MemoryMiB   int
	Net         *FCNet
	BootTimeout time.Duration
}

// Firecracker is the Backend of ADR 0036: a sandbox is a microVM, its disk
// is a private copy of a base image, and its commands run inside the guest.
//
// The host half of this file is VM lifecycle — create, boot, park, destroy.
// Everything else is forwarded over vsock to `fountain runner-guest`, which
// answers it with a Process backend. That is the whole trick: the wire
// protocol never mentions directories, so the same implementation that is
// the trusted-mode runner on the host is the in-VM agent unchanged.
type Firecracker struct {
	cfg FirecrackerConfig
	log Logger

	mu        sync.Mutex
	vms       map[string]*microVM
	bootGates map[string]*sync.Mutex // per sandbox, held across a boot
	sessions  map[string]string      // session id → sandbox name
}

type microVM struct {
	name string
	dir  string
	meta vmMeta
	api  *fcAPI
	proc *os.Process
	link *guestLink
}

// vmMeta is the sandbox's identity on the host network, written down so a
// daemon restart rebuilds the same VM rather than a different one.
type vmMeta struct {
	Tap string `json:"tap"`
	IP  string `json:"ip"`
}

// NewFirecracker validates the configuration and builds the backend. It
// checks the things that would otherwise fail one boot at a time, an hour
// later, as a timeout.
func NewFirecracker(cfg FirecrackerConfig, log Logger) (*Firecracker, error) {
	if cfg.Net == nil {
		return nil, errors.New("firecracker backend: no network configuration")
	}
	// What the operator typed is checked before what the machine has, so a
	// misspelled path is reported as a misspelled path rather than as a
	// missing kernel on a host that also has no KVM.
	for _, required := range []struct{ flag, path string }{
		{"--fc-kernel", cfg.Kernel},
		{"--fc-rootfs", cfg.BaseRootfs},
	} {
		if required.path == "" {
			return nil, fmt.Errorf("firecracker backend: %s is required", required.flag)
		}
		if _, err := os.Stat(required.path); err != nil {
			return nil, fmt.Errorf("firecracker backend: %s: %w", required.flag, err)
		}
	}
	if cfg.Binary == "" {
		cfg.Binary = "firecracker"
	}
	if _, err := exec.LookPath(cfg.Binary); err != nil {
		return nil, fmt.Errorf("firecracker backend: %w", err)
	}
	if _, err := os.Stat("/dev/kvm"); err != nil {
		return nil, fmt.Errorf("firecracker backend: /dev/kvm: %w", err)
	}
	if cfg.VCPUs <= 0 {
		cfg.VCPUs = 2
	}
	if cfg.MemoryMiB <= 0 {
		cfg.MemoryMiB = 2048
	}
	if cfg.BootTimeout <= 0 {
		cfg.BootTimeout = 60 * time.Second
	}
	if err := os.MkdirAll(cfg.Root, 0o700); err != nil {
		return nil, fmt.Errorf("create sandbox root %s: %w", cfg.Root, err)
	}
	return &Firecracker{
		cfg:       cfg,
		log:       log,
		vms:       map[string]*microVM{},
		bootGates: map[string]*sync.Mutex{},
		sessions:  map[string]string{},
	}, nil
}

// ── sandbox lifecycle ────────────────────────────────────────────────────────

func (f *Firecracker) dir(name string) (string, error) {
	if name == "" || strings.ContainsAny(name, "/\\") || name == "." || name == ".." ||
		strings.HasPrefix(name, ".") {
		return "", invalid("bad sandbox name")
	}
	return filepath.Join(f.cfg.Root, name), nil
}

// Create implements Backend. Idempotent-adopting in two senses: a sandbox
// whose VM is already up is returned as it stands, and one whose disk is on
// the host but whose VM is not running is booted onto that disk. The second
// is the ordinary path after a daemon restart, and the disk is the agent's
// memory, so it must never be replaced with a fresh copy.
func (f *Firecracker) Create(req Request) (map[string]any, func(), error) {
	dir, err := f.dir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, nil, unavailable(err.Error())
	}
	if _, err := f.ensureRunning(req.Name); err != nil {
		return nil, nil, err
	}
	return map[string]any{}, nil, nil
}

// Get implements Backend. The status comes from Firecracker rather than
// from anything the daemon remembers, and a sandbox whose disk is present
// with no VM behind it is parked, not missing — reporting not_found there
// would tell Fountain to give up a disk that is sitting on this machine.
//
// `path` is what a process *inside* this sandbox calls its home, which is
// the one thing Fountain uses it for: `Fountain.Sandbox.Runner.host_path/2`
// rewrites the ACP `cwd` through it, and an agent CLI validates that path in
// band before it will start a session. On the process backend the two
// coincide, because the sandbox is a directory and /home/sprite is an alias
// for it. In a microVM they do not: /home/sprite is literal, and handing
// over the host's state directory names something that exists on the wrong
// side of the machine boundary. The host directory rides along under
// `host_dir` for an operator reading a log; nothing consumes it.
func (f *Firecracker) Get(req Request) (map[string]any, func(), error) {
	dir, err := f.dir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return nil, nil, notFound("no sandbox " + req.Name)
	}
	status := "suspended"
	if vm := f.lookup(req.Name); vm != nil && vm.alive() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		state, err := vm.api.instanceState(ctx)
		if err != nil {
			// The disk is here and the VM is up; a control socket that will
			// not answer right now is transient, and saying not_found would
			// be a lie with teeth.
			return nil, nil, unavailable(err.Error())
		}
		if state == "Running" {
			status = "running"
		}
	}
	return map[string]any{"status": status, "path": spriteHome, "host_dir": dir}, nil, nil
}

// Destroy implements Backend. Already-gone is success.
func (f *Firecracker) Destroy(req Request) (map[string]any, func(), error) {
	dir, err := f.dir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	f.mu.Lock()
	vm := f.vms[req.Name]
	delete(f.vms, req.Name)
	f.mu.Unlock()
	f.forgetSessions(req.Name)

	meta := vmMeta{}
	if vm != nil {
		meta = vm.meta
		vm.stop(f.log)
	} else {
		meta, _ = readMeta(dir)
	}
	if meta.Tap != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		deleteTap(ctx, meta.Tap)
		cancel()
	}
	if err := os.RemoveAll(dir); err != nil {
		return nil, nil, unavailable(err.Error())
	}
	return map[string]any{}, nil, nil
}

// List implements Backend.
func (f *Firecracker) List() (map[string]any, func(), error) {
	entries, err := os.ReadDir(f.cfg.Root)
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

// Suspend implements Backend by pausing the VM: the guest stops being
// scheduled, its processes keep their state, and the disk is untouched.
// This is the park a microVM makes cheap and a directory cannot — a turn
// interrupted by an idle sweep resumes where it was rather than restarting.
//
// The memory stays resident, which is the honest limitation: parking frees
// CPU, not RAM. Snapshotting it to disk is the follow-up that would.
func (f *Firecracker) Suspend(req Request) (map[string]any, func(), error) {
	if _, err := f.existing(req.Name); err != nil {
		return nil, nil, err
	}
	vm := f.lookup(req.Name)
	if vm == nil || !vm.alive() {
		return map[string]any{}, nil, nil // nothing running: already parked
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := vm.api.pause(ctx); err != nil {
		return nil, nil, unavailable(err.Error())
	}
	return map[string]any{}, nil, nil
}

// Resume implements Backend.
func (f *Firecracker) Resume(req Request) (map[string]any, func(), error) {
	if _, err := f.existing(req.Name); err != nil {
		return nil, nil, err
	}
	if _, err := f.ensureRunning(req.Name); err != nil {
		return nil, nil, err
	}
	return map[string]any{}, nil, nil
}

func (f *Firecracker) existing(name string) (string, error) {
	dir, err := f.dir(name)
	if err != nil {
		return "", err
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return "", notFound("no sandbox " + name)
	}
	return dir, nil
}

// ── forwarded ops ────────────────────────────────────────────────────────────

// forward hands a request to the guest agent, waking the VM first. Every op
// below is the guest's to answer: inside the VM they are the same Process
// backend that serves a trusted-mode runner, which is why none of them is
// reimplemented here.
func (f *Firecracker) forward(req Request, emit Emitter) (map[string]any, func(), error) {
	name := req.Name
	if name == "" {
		// stdin, stdin_close, detach and attach name a session, not a
		// sandbox, so the host has to know which VM the session lives in.
		var err error
		if name, err = f.sandboxOfSession(req.SessionID); err != nil {
			return nil, nil, err
		}
	}
	vm, err := f.ensureRunning(name)
	if err != nil {
		return nil, nil, err
	}
	// Inside the VM the sandbox is always "sprite"; the Fountain-minted name
	// identifies the machine, not the directory.
	if req.Name != "" {
		req.Name = guestSandbox
	}
	result, after, err := vm.link.call(context.Background(), req, emit)
	if sid, ok := result["session_id"].(string); ok && sid != "" {
		f.mu.Lock()
		f.sessions[sid] = name
		f.mu.Unlock()
	}
	return result, after, err
}

// sandboxOfSession finds which VM a session lives in. Sessions are the
// guest's; the host keeps only this mapping, recorded when a spawn or attach
// reply names one.
//
// It deliberately outlives a dropped link. A socket that blips while the VM
// stays up leaves the guest holding its sessions, and forgetting the mapping
// there would answer a later stdin with not_found — a permanent error for a
// session that is still running.
func (f *Firecracker) sandboxOfSession(sessionID string) (string, error) {
	if sessionID == "" {
		return "", invalid("no sandbox and no session id")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	name, ok := f.sessions[sessionID]
	if !ok {
		return "", notFound("no session " + sessionID)
	}
	return name, nil
}

// forgetSessions drops the mapping for a sandbox that is going away.
func (f *Firecracker) forgetSessions(name string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for sid, owner := range f.sessions {
		if owner == name {
			delete(f.sessions, sid)
		}
	}
}

// WriteFile implements Backend.
func (f *Firecracker) WriteFile(req Request) (map[string]any, func(), error) {
	return f.forward(req, nil)
}

// Exec implements Backend.
func (f *Firecracker) Exec(req Request) (map[string]any, func(), error) {
	return f.forward(req, nil)
}

// Spawn implements Backend.
func (f *Firecracker) Spawn(req Request, emit Emitter) (map[string]any, func(), error) {
	return f.forward(req, emit)
}

// Stdin implements Backend.
func (f *Firecracker) Stdin(req Request) (map[string]any, func(), error) {
	return f.forward(req, nil)
}

// StdinClose implements Backend.
func (f *Firecracker) StdinClose(req Request) (map[string]any, func(), error) {
	return f.forward(req, nil)
}

// Detach implements Backend.
func (f *Firecracker) Detach(req Request) (map[string]any, func(), error) {
	result, after, err := f.forward(req, nil)
	var op *OpError
	if errors.As(err, &op) && op.Code == "not_found" {
		// Detaching from something already gone is fine — including a VM
		// that is no longer there to ask.
		return map[string]any{}, nil, nil
	}
	return result, after, err
}

// ListSessions implements Backend.
func (f *Firecracker) ListSessions(req Request) (map[string]any, func(), error) {
	return f.forward(req, nil)
}

// Attach implements Backend.
func (f *Firecracker) Attach(req Request, emit Emitter) (map[string]any, func(), error) {
	return f.forward(req, emit)
}

// StopAll implements Backend. Every VM is a child of this process, so they
// go when it goes; stopping them deliberately is what gets the guest's page
// cache onto the disk that is the agent's memory.
func (f *Firecracker) StopAll() {
	f.mu.Lock()
	vms := make([]*microVM, 0, len(f.vms))
	for _, vm := range f.vms {
		vms = append(vms, vm)
	}
	f.vms = map[string]*microVM{}
	f.mu.Unlock()
	for _, vm := range vms {
		vm.stop(f.log)
	}
}

// ── booting ──────────────────────────────────────────────────────────────────

func (f *Firecracker) lookup(name string) *microVM {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.vms[name]
}

// ensureRunning is the wake path: boot a VM that is not there, resume one
// that is paused, and return one that is already running. Everything that
// touches a guest goes through it, so a sandbox Fountain never explicitly
// resumed still answers — the way a Sprites sandbox wakes on the next exec.
func (f *Firecracker) ensureRunning(name string) (*microVM, error) {
	// One boot at a time per sandbox. Two conversations starting together
	// would otherwise each spawn a firecracker process on the same API
	// socket, and the second would fail on a path the first already owns.
	gate := f.bootGate(name)
	gate.Lock()
	defer gate.Unlock()

	f.mu.Lock()
	vm, known := f.vms[name]
	f.mu.Unlock()

	if known && vm.alive() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		state, err := vm.api.instanceState(ctx)
		if err != nil {
			return nil, unavailable(err.Error())
		}
		if state == "Paused" {
			if err := vm.api.resume(ctx); err != nil {
				return nil, unavailable(err.Error())
			}
		}
		return vm, nil
	}

	vm, err := f.boot(name)
	if err != nil {
		var op *OpError
		if errors.As(err, &op) {
			return nil, err
		}
		return nil, unavailable(err.Error())
	}
	f.mu.Lock()
	f.vms[name] = vm
	f.mu.Unlock()
	return vm, nil
}

// bootGate is the per-sandbox lock ensureRunning holds across a boot.
func (f *Firecracker) bootGate(name string) *sync.Mutex {
	f.mu.Lock()
	defer f.mu.Unlock()
	gate, ok := f.bootGates[name]
	if !ok {
		gate = &sync.Mutex{}
		f.bootGates[name] = gate
	}
	return gate
}

// boot brings one microVM up from the sandbox's own disk and blocks until
// its agent answers. A VM that boots but whose agent never speaks is a
// failure, not a sandbox: it would accept a create and then hang every turn.
func (f *Firecracker) boot(name string) (*microVM, error) {
	dir, err := f.dir(name)
	if err != nil {
		return nil, err
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return nil, notFound("no sandbox " + name)
	}

	meta, err := f.ensureMeta(name, dir)
	if err != nil {
		return nil, err
	}
	rootfs := filepath.Join(dir, "rootfs.ext4")
	if err := ensureRootfsCopy(f.cfg.BaseRootfs, rootfs); err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), f.cfg.BootTimeout)
	defer cancel()

	if err := ensureTap(ctx, meta.Tap, f.cfg.Net.Bridge); err != nil {
		return nil, err
	}

	apiSock := filepath.Join(dir, "firecracker.sock")
	vsockUDS := filepath.Join(dir, "vsock.sock")
	// Firecracker refuses to start on a socket path that already exists, and
	// a previous VM's leftovers are exactly the case a restart hits.
	_ = os.Remove(apiSock)
	_ = os.Remove(vsockUDS)

	logFile, err := os.OpenFile(filepath.Join(dir, "firecracker.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return nil, err
	}
	defer func() { _ = logFile.Close() }()

	cmd := exec.Command(f.cfg.Binary, "--api-sock", apiSock)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	// Its own process group: stopping the VM must not depend on the daemon's
	// signal disposition, and must not reach the daemon.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	vm := &microVM{
		name: name,
		dir:  dir,
		meta: meta,
		api:  newFCAPI(apiSock),
		proc: cmd.Process,
		link: newGuestLink(vsockUDS, f.log),
	}
	// Reap the process rather than leaving a zombie once it exits.
	go func() { _ = cmd.Wait() }()

	if err := f.configure(ctx, vm, rootfs, vsockUDS); err != nil {
		vm.stop(f.log)
		return nil, err
	}
	if err := f.waitForAgent(ctx, vm); err != nil {
		vm.stop(f.log)
		return nil, err
	}
	f.log.Info("runner: microVM up", "sandbox", name, "ip", meta.IP, "tap", meta.Tap)
	return vm, nil
}

func (f *Firecracker) configure(ctx context.Context, vm *microVM, rootfs, vsockUDS string) error {
	if err := vm.api.waitAPI(ctx); err != nil {
		return err
	}
	guest := net.ParseIP(vm.meta.IP)
	bootArgs := strings.Join([]string{
		"console=ttyS0",
		"reboot=k",
		"panic=1",
		"pci=off",
		f.cfg.Net.bootIP(guest),
	}, " ")
	if err := vm.api.setMachineConfig(ctx, f.cfg.VCPUs, f.cfg.MemoryMiB); err != nil {
		return err
	}
	if err := vm.api.setBootSource(ctx, f.cfg.Kernel, bootArgs); err != nil {
		return err
	}
	if err := vm.api.setRootDrive(ctx, rootfs); err != nil {
		return err
	}
	if err := vm.api.setNetwork(ctx, vm.meta.Tap, macFor(guest)); err != nil {
		return err
	}
	// Guest CID 3 for every VM: each has its own host-side socket, so the
	// address only has to be unique inside the guest.
	if err := vm.api.setVsock(ctx, 3, vsockUDS); err != nil {
		return err
	}
	return vm.api.start(ctx)
}

// waitForAgent blocks until `fountain runner-guest` answers a ping, and says
// what is wrong if it never does. A rootfs that does not start the agent is
// the most likely first-run mistake, so the error names it.
func (f *Firecracker) waitForAgent(ctx context.Context, vm *microVM) error {
	var last error
	for {
		attempt, cancel := context.WithTimeout(ctx, 5*time.Second)
		_, _, err := vm.link.call(attempt, Request{ID: vm.link.probeID(), Op: "ping"}, nil)
		cancel()
		if err == nil {
			return nil
		}
		last = err
		select {
		case <-ctx.Done():
			return fmt.Errorf("the microVM booted but its agent never answered (%v); "+
				"the base rootfs must start `fountain runner-guest` at boot", last)
		case <-time.After(250 * time.Millisecond):
		}
	}
}

// ensureMeta reads the sandbox's network identity, allocating one the first
// time. It is written to the sandbox's own directory so a daemon restart
// rebuilds the same VM on the same address.
func (f *Firecracker) ensureMeta(name, dir string) (vmMeta, error) {
	if meta, err := readMeta(dir); err == nil {
		return meta, nil
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	taken := map[string]bool{}
	entries, _ := os.ReadDir(f.cfg.Root)
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if meta, err := readMeta(filepath.Join(f.cfg.Root, e.Name())); err == nil {
			taken[meta.IP] = true
		}
	}
	for _, candidate := range f.cfg.Net.hostAddresses() {
		if taken[candidate.String()] {
			continue
		}
		meta := vmMeta{Tap: tapName(name), IP: candidate.String()}
		blob, err := json.Marshal(meta)
		if err != nil {
			return vmMeta{}, err
		}
		if err := os.WriteFile(filepath.Join(dir, "vm.json"), blob, 0o600); err != nil {
			return vmMeta{}, err
		}
		return meta, nil
	}
	return vmMeta{}, fmt.Errorf("no free address left in %s", f.cfg.Net.Subnet)
}

func readMeta(dir string) (vmMeta, error) {
	blob, err := os.ReadFile(filepath.Join(dir, "vm.json"))
	if err != nil {
		return vmMeta{}, err
	}
	var meta vmMeta
	if err := json.Unmarshal(blob, &meta); err != nil {
		return vmMeta{}, err
	}
	if meta.IP == "" || meta.Tap == "" {
		return vmMeta{}, errors.New("incomplete vm.json")
	}
	return meta, nil
}

// ensureRootfsCopy gives the sandbox its own disk. `cp --reflink=auto` makes
// that near-free on a filesystem with copy-on-write (XFS, Btrfs) and a full
// copy everywhere else, which is slower but never wrong. An existing copy is
// left alone: it is the agent's memory.
func ensureRootfsCopy(base, target string) error {
	if _, err := os.Stat(target); err == nil {
		return nil
	}
	tmp := target + ".partial"
	_ = os.Remove(tmp)
	if out, err := exec.Command("cp", "--reflink=auto", base, tmp).CombinedOutput(); err != nil {
		// Not every `cp` understands --reflink (BSD's does not), and not
		// every filesystem offers it. A slow copy is the fallback; failing
		// to provision is not.
		_ = os.Remove(tmp)
		if err := copyFile(base, tmp); err != nil {
			_ = os.Remove(tmp)
			return fmt.Errorf("copy base rootfs: %w (cp --reflink said: %s)", err, strings.TrimSpace(string(out)))
		}
	}
	// Renamed only once it is complete, so an interrupted copy is never
	// mistaken for a sandbox's disk on the next boot.
	return os.Rename(tmp, target)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	return out.Close()
}

// ── the VM handle ────────────────────────────────────────────────────────────

func (vm *microVM) alive() bool {
	if vm.proc == nil {
		return false
	}
	return vm.proc.Signal(syscall.Signal(0)) == nil
}

// stop shuts the VM down: flush the guest's writes, ask the VMM to exit,
// and kill it if it will not. The sync matters — the disk under this VM is
// what the next turn resumes from.
func (vm *microVM) stop(log Logger) {
	if vm.alive() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		if _, _, err := vm.link.call(ctx, Request{ID: vm.link.probeID(), Op: "exec", Name: guestSandbox, Cmd: "sync"}, nil); err != nil && log != nil {
			log.Debug("runner: could not sync the guest before stopping", "sandbox", vm.name, "err", err.Error())
		}
		cancel()
	}
	vm.link.close()
	if vm.proc == nil {
		return
	}
	_ = vm.proc.Signal(syscall.SIGTERM)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if !vm.alive() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = vm.proc.Kill()
}
