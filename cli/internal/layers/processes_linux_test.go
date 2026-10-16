package layers

import (
	"os/exec"
	"path/filepath"
	"testing"
)

func TestQuiescentRejectsSurvivingBackgroundWorkAndTampering(t *testing.T) {
	baseline := filepath.Join(t.TempDir(), "processes")
	result, err := ProcessSnapshot(baseline)
	if err != nil {
		t.Fatal(err)
	}
	child := exec.Command("sleep", "30")
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { child.Process.Kill(); child.Wait() }()
	if _, err := Quiescent(baseline, result.SHA256); err != ErrArchive {
		t.Fatalf("background work was accepted: %v", err)
	}
	if _, err := Quiescent(baseline, "wrong"); err != ErrBinding {
		t.Fatal(err)
	}
}
