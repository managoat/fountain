package runner

// Opt-in characterization loaded with Go's overlay option, outside normal CI.
// Passing demonstrates the existing timeout gaps; this is not a fix test.

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFilesRunnerExecChild(t *testing.T) {
	if os.Getenv("FOUNTAIN_FILES_PROBE_CHILD") != "1" {
		t.Skip("only the isolated probe subprocess runs this helper")
	}
	args := os.Args[len(os.Args)-3:]
	release, marker, cleanup := args[0], args[1], args[2]
	// Every child has its own hard local deadline, including failed probes.
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(cleanup); err == nil {
			return
		}
		if _, err := os.Stat(release); err == nil {
			if err := os.WriteFile(marker, []byte("child still running\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestFilesRunnerExecTimeoutProbe(t *testing.T) {
	for _, detachedOutput := range []bool{true, false} {
		t.Run(fmt.Sprintf("detached_output=%v", detachedOutput), func(t *testing.T) {
			d := newDaemon(t)
			rec := newRecorder()
			do(t, d, Request{Op: "create", Name: "probe"}, rec)
			directory := t.TempDir()
			release := filepath.Join(directory, "release")
			marker := filepath.Join(directory, "marker")
			cleanup := filepath.Join(directory, "cleanup")
			t.Cleanup(func() {
				_ = os.WriteFile(cleanup, nil, 0o600)
			})
			redirect := ""
			if detachedOutput {
				redirect = " >/dev/null 2>&1"
			}
			script := `"$1" -test.run='^TestFilesRunnerExecChild$' -- "$2" "$3" "$4"` + redirect + ` & wait`
			timeout := 100
			type outcome struct {
				result map[string]any
				err    error
			}
			done := make(chan outcome, 1)
			started := time.Now()
			go func() {
				result, _, err := d.Handle(Request{
					Op: "exec", Name: "probe", Cmd: "sh",
					Args: []string{"-c", script, "probe", os.Args[0], release, marker, cleanup},
					Env:  [][]string{{"FOUNTAIN_FILES_PROBE_CHILD", "1"}}, TimeoutMS: &timeout,
				}, rec)
				done <- outcome{result, err}
			}()

			if detachedOutput {
				select {
				case out := <-done:
					if out.err != nil || out.result["code"] == 0 {
						t.Fatalf("expected timeout exit: %+v", out)
					}
					t.Logf("EVIDENCE runner: parent returned code=%v after %s", out.result["code"], time.Since(started))
				case <-time.After(3 * time.Second):
					t.Fatal("probe did not receive a parent timeout")
				}
			} else {
				select {
				case out := <-done:
					t.Fatalf("expected inherited pipe to outlive the timeout: %+v", out)
				case <-time.After(500 * time.Millisecond):
					t.Log("EVIDENCE runner: timeout=100ms, exec still waiting at 500ms while child holds pipe")
				}
			}

			if err := os.WriteFile(release, nil, 0o600); err != nil {
				t.Fatal(err)
			}
			until := time.Now().Add(3 * time.Second)
			for {
				if _, err := os.Stat(marker); err == nil {
					t.Log("EVIDENCE runner: descendant executed after the parent timeout")
					break
				}
				if time.Now().After(until) {
					t.Fatal("child did not demonstrate execution after timeout")
				}
				time.Sleep(5 * time.Millisecond)
			}
			if !detachedOutput {
				select {
				case out := <-done:
					if out.err != nil || out.result["code"] == 0 {
						t.Fatalf("expected eventual nonzero exit: %+v", out)
					}
				case <-time.After(3 * time.Second):
					t.Fatal("exec did not finish after child released its pipe")
				}
			}
		})
	}
}
