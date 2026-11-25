//go:build !windows

package procutil

import (
	"errors"
	"syscall"
)

// IsPIDAlive reports whether a process with the given PID currently exists.
func IsPIDAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
