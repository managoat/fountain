package runner

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The helper's descendants are real processes so these tests detect both a
// surviving child and a child keeping the runner's output descriptor open.
func TestExecLifetimeHelper(t *testing.T) {
	mode := os.Getenv("FOUNTAIN_EXEC_LIFETIME_HELPER")
	if mode == "" {
		t.Skip("only invoked as a subprocess")
	}
	dir := os.Getenv("FOUNTAIN_EXEC_LIFETIME_DIR")
	if mode == "child" {
		if err := os.WriteFile(filepath.Join(dir, "child"), []byte(strconv.Itoa(os.Getpid())), 0o600); err != nil {
			t.Fatal(err)
		}
		// A test failure cannot leave a child running indefinitely.
		until := time.Now().Add(10 * time.Second)
		for time.Now().Before(until) {
			if _, err := os.Stat(filepath.Join(dir, "cleanup")); err == nil {
				os.Exit(0)
			}
			if _, err := os.Stat(filepath.Join(dir, "release")); err == nil {
				_ = os.WriteFile(filepath.Join(dir, "marker"), []byte("child executed"), 0o600)
				os.Exit(0)
			}
			time.Sleep(5 * time.Millisecond)
		}
		os.Exit(0)
	}
	child := exec.Command(os.Args[0], "-test.run=^TestExecLifetimeHelper$")
	child.Env = append(os.Environ(), "FOUNTAIN_EXEC_LIFETIME_HELPER=child")
	if os.Getenv("FOUNTAIN_EXEC_LIFETIME_REDIRECT") != "1" {
		child.Stdout, child.Stderr = os.Stdout, os.Stderr
	}
	if mode == "escape" {
		child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	until := time.Now().Add(3 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(dir, "child")); err == nil {
			break
		}
		if time.Now().After(until) {
			_ = child.Process.Kill()
			_ = child.Wait()
			t.Fatal("child did not become ready")
		}
		time.Sleep(time.Millisecond)
	}
	fmt.Println("ready")
	if mode == "stopped" {
		_ = syscall.Kill(os.Getpid(), syscall.SIGSTOP)
	}
	if mode == "timeout" || mode == "stopped" {
		_ = child.Wait()
	}
	os.Exit(0)
}

func TestExecStopsProcessGroup(t *testing.T) {
	for _, mode := range []string{"timeout", "success", "stopped"} {
		for _, redirect := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/redirect=%v", mode, redirect), func(t *testing.T) {
				d, rec, req, directory := execLifetimeRequest(t, mode, redirect)
				started := time.Now()
				result := do(t, d, req, rec)
				elapsed := time.Since(started)
				if elapsed > 2*time.Second {
					t.Fatalf("exec took %s after a 500ms deadline", elapsed)
				}
				if mode == "stopped" && elapsed < 450*time.Millisecond {
					t.Fatalf("stopped leader was treated as exited after %s", elapsed)
				}
				wantCode := 0
				if mode != "success" {
					wantCode = 137 // Preserve the existing killed-process exit code.
				}
				if result["code"] != wantCode {
					t.Fatalf("exit code = %v, want %d", result["code"], wantCode)
				}
				output, _ := base64.StdEncoding.DecodeString(result["output"].(string))
				if string(output) != "ready\n" {
					t.Fatalf("output = %q; child may never have started", output)
				}
				pid := execLifetimeChildPID(t, directory)
				until := time.Now().Add(time.Second)
				for !execLifetimeChildStopped(pid) {
					if time.Now().After(until) {
						t.Fatalf("child %d still running after exec returned", pid)
					}
					time.Sleep(5 * time.Millisecond)
				}
				if err := os.WriteFile(filepath.Join(directory, "release"), nil, 0o600); err != nil {
					t.Fatal(err)
				}
				if _, err := os.Stat(filepath.Join(directory, "marker")); !os.IsNotExist(err) {
					t.Fatalf("stopped child executed: %v", err)
				}
			})
		}
	}
}

func TestExecBoundsOutputFromEscapedChild(t *testing.T) {
	d, rec, req, directory := execLifetimeRequest(t, "escape", false)
	// Even an exec without an execution timeout bounds output draining after
	// its parent exits. Escaping the group remains explicitly unsupported.
	req.TimeoutMS = nil
	started := time.Now()
	result := do(t, d, req, rec)
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("escaped output descriptor held exec for %s", elapsed)
	}
	if result["code"] != 124 {
		t.Fatalf("unclosed output reported code %v, want 124", result["code"])
	}
	output, _ := base64.StdEncoding.DecodeString(result["output"].(string))
	if !strings.Contains(string(output), "command output did not close") {
		t.Fatalf("missing output-drain error: %q", output)
	}
	pid := execLifetimeChildPID(t, directory)
	if execLifetimeChildStopped(pid) {
		t.Fatal("escaped child unexpectedly stopped; output-drain test is invalid")
	}
	if err := os.WriteFile(filepath.Join(directory, "release"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	until := time.Now().Add(time.Second)
	for {
		if _, err := os.Stat(filepath.Join(directory, "marker")); err == nil {
			break
		}
		if time.Now().After(until) {
			t.Fatal("escaped child did not prove it remained live")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func execLifetimeRequest(t *testing.T, mode string, redirect bool) (*Daemon, *recorder, Request, string) {
	t.Helper()
	d, rec := newDaemon(t), newRecorder()
	do(t, d, Request{Op: "create", Name: "sb"}, rec)
	directory := t.TempDir()
	t.Cleanup(func() {
		_ = os.WriteFile(filepath.Join(directory, "cleanup"), nil, 0o600)
		if data, err := os.ReadFile(filepath.Join(directory, "child")); err == nil {
			if pid, err := strconv.Atoi(string(data)); err == nil && !execLifetimeChildStopped(pid) {
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	})
	redirectEnv := "0"
	if redirect {
		redirectEnv = "1"
	}
	timeout := 500
	return d, rec, Request{
		Op: "exec", Name: "sb", Cmd: os.Args[0], Args: []string{"-test.run=^TestExecLifetimeHelper$"},
		TimeoutMS: &timeout,
		Env: [][]string{
			{"FOUNTAIN_EXEC_LIFETIME_HELPER", mode},
			{"FOUNTAIN_EXEC_LIFETIME_DIR", directory},
			{"FOUNTAIN_EXEC_LIFETIME_REDIRECT", redirectEnv},
		},
	}, directory
}

func execLifetimeChildPID(t *testing.T, directory string) int {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(directory, "child"))
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(string(data))
	if err != nil {
		t.Fatal(err)
	}
	return pid
}

func execLifetimeChildStopped(pid int) bool {
	if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
		return true
	}
	// Container PID 1 may retain a zombie after the parent is killed. A
	// zombie cannot execute or retain a pipe; it need not disappear to prove
	// the child stopped. macOS reaps these through launchd.
	if runtime.GOOS == "linux" {
		data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
		if err == nil {
			_, fields, ok := strings.Cut(string(data), ") ")
			return ok && strings.HasPrefix(fields, "Z ")
		}
	}
	return false
}

// A non-reaping wait must leave the child available for repeated observation
// and the final os/exec Wait. This pins the identity used by group signals.
func TestExecWaitKeepsLeaderUnreaped(t *testing.T) {
	cmd := exec.Command("sh", "-c", "exit 7")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	})
	for i := 0; i < 2; i++ {
		if err := waitForExecExit(cmd.Process.Pid); err != nil {
			t.Fatalf("non-reaping wait %d: %v", i, err)
		}
	}
	var exitErr *exec.ExitError
	if err := cmd.Wait(); !errors.As(err, &exitErr) || exitErr.ExitCode() != 7 {
		t.Fatalf("final wait lost the child's exit status: %v", err)
	}
}

func TestExecProcessGroupFencesCancellationBeforeReaping(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	calls := 0
	group := execProcessGroup{kill: func() error {
		calls++
		if calls == 1 {
			close(entered)
		}
		<-release
		return nil
	}}
	cancelled := make(chan error, 1)
	go func() { cancelled <- group.cancel() }()
	<-entered
	finished := make(chan error, 1)
	go func() { finished <- group.finish(true) }()
	select {
	case <-finished:
		t.Fatal("reaping became possible while cancellation was still signaling")
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	if err := <-cancelled; err != nil {
		t.Fatal(err)
	}
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("group signals = %d, want cancellation and final cleanup", calls)
	}
	// cmd.Wait may now reap and the numeric PGID may be reused. A context
	// callback delayed until this point must not touch it.
	if err := group.cancel(); !errors.Is(err, os.ErrProcessDone) {
		t.Fatalf("late cancellation = %v", err)
	}
	if calls != 2 {
		t.Fatal("late cancellation signaled after reaping was permitted")
	}
}

func TestExecProcessGroupDoesNotSignalLostChild(t *testing.T) {
	group := execProcessGroup{kill: func() error {
		t.Fatal("signaled a PID whose child ownership was lost")
		return nil
	}}
	if err := group.finish(false); err != nil {
		t.Fatal(err)
	}
	if err := group.cancel(); !errors.Is(err, os.ErrProcessDone) {
		t.Fatalf("cancellation after lost ownership = %v", err)
	}
}
