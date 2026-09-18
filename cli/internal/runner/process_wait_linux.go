package runner

import (
	"errors"

	"golang.org/x/sys/unix"
)

// waitForExecExit waits for a terminal state without reaping the child. The
// unreaped group leader pins its PID until group cleanup has finished.
func waitForExecExit(pid int) error {
	var info unix.Siginfo
	for {
		err := unix.Waitid(unix.P_PID, pid, &info, unix.WEXITED|unix.WNOWAIT, nil)
		if !errors.Is(err, unix.EINTR) {
			return err
		}
	}
}

func killExecGroup(pid int) error {
	return unix.Kill(-pid, unix.SIGKILL)
}
