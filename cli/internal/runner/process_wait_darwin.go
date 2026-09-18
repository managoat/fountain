package runner

import (
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// darwinChildInfo is siginfo_t from <sys/signal.h>, for both supported 64-bit
// Darwin architectures. x/sys/unix does not expose a Darwin waitid wrapper.
type darwinChildInfo struct {
	signo  int32
	errno  int32
	code   int32
	pid    int32
	uid    uint32
	status int32
	addr   uintptr
	value  uintptr
	band   int64
	pad    [7]uint64
}

// waitForExecExit waits without reaping, keeping the leader's PID reserved
// until group cleanup finishes. Darwin can report a stop despite WEXITED
// (https://github.com/golang/go/issues/19314), so only terminal si_codes count.
func waitForExecExit(pid int) error {
	const pPID = 1 // idtype_t P_PID from <sys/wait.h>.
	for {
		var info darwinChildInfo
		_, _, errno := syscall.Syscall6(syscall.SYS_WAITID, pPID, uintptr(pid),
			uintptr(unsafe.Pointer(&info)), syscall.WEXITED|syscall.WNOWAIT, 0, 0)
		if errno == syscall.EINTR {
			continue
		}
		if errno != 0 {
			return errno
		}
		// CLD_EXITED, CLD_KILLED, CLD_DUMPED from <sys/signal.h>.
		if info.code >= 1 && info.code <= 3 {
			return nil
		}
		// WNOWAIT can leave the same nonterminal event pending. Avoid a
		// busy loop until the child resumes or cancellation kills it.
		time.Sleep(time.Millisecond)
	}
}

func killExecGroup(pid int) error {
	err := unix.Kill(-pid, unix.SIGKILL)
	if err != unix.EPERM {
		return err
	}
	// Darwin reports EPERM when the pinned zombie leader is the only
	// remaining member. Distinguish that from live members we cannot kill;
	// never silently accept a real permission failure. The unreaped leader
	// still reserves this group ID throughout the lookup.
	members, lookupErr := unix.SysctlKinfoProcSlice("kern.proc.pgrp", pid)
	if lookupErr != nil || len(members) == 0 {
		return err
	}
	const zombie = 5 // SZOMB from <sys/proc.h>.
	for _, member := range members {
		if member.Proc.P_stat != zombie {
			return err
		}
	}
	return nil
}
