package procutil

import (
	"os"
	"testing"
)

func TestIsPIDAlive(t *testing.T) {
	if !IsPIDAlive(os.Getpid()) {
		t.Fatalf("expected current process PID %d to be alive", os.Getpid())
	}
	if IsPIDAlive(0) || IsPIDAlive(-1) {
		t.Fatalf("expected non-positive PIDs to be reported as not alive")
	}
}
