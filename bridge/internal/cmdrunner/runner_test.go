package cmdrunner

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type fakeExec struct {
	lastArgs []string
	lastEnv  []string
	resp     []byte
}

func (f *fakeExec) Run(_ context.Context, _ string, args []string, env []string, _ string) ([]byte, error) {
	f.lastArgs = args
	f.lastEnv = env
	return f.resp, nil
}

func TestRunnerDiscoverAndSend(t *testing.T) {
	tmp := t.TempDir()
	daemonDir := filepath.Join(tmp, "daemon")
	_ = os.MkdirAll(daemonDir, 0o755)
	fakeBin := filepath.Join(tmp, "agentapi")
	_ = os.WriteFile(fakeBin, []byte("#!/bin/sh\n"), 0o755)

	r := New(fakeBin, daemonDir)
	r.pidAliveFn = func(pid int) bool { return pid == 4242 }

	// No hub json -> offline
	if _, err := r.SendMessage(context.Background(), "conv-1", "hi"); !errors.Is(err, ErrDesktopOffline) {
		t.Fatalf("expected ErrDesktopOffline, got %v", err)
	}

	// Write live hub metadata
	_ = os.WriteFile(filepath.Join(daemonDir, "hub_4242.json"), []byte(`{"pid":4242,"httpPort":51234}`), 0o600)
	fx := &fakeExec{resp: []byte(`{"conversation_id":"conv-new"}`)}
	r.exec = fx

	if !r.IsDesktopOnline() {
		t.Fatal("expected desktop online")
	}

	res, err := r.NewConversation(context.Background(), NewConversationOptions{Prompt: "build", Title: "Test", Model: "pro"})
	if err != nil {
		t.Fatalf("NewConversation: %v", err)
	}
	if res.ConversationID != "conv-new" {
		t.Fatalf("expected conv-new, got %+v", res)
	}
	if len(fx.lastEnv) != 1 || fx.lastEnv[0] != "ANTIGRAVITY_LS_ADDRESS=127.0.0.1:51234" {
		t.Fatalf("unexpected env: %v", fx.lastEnv)
	}
}
