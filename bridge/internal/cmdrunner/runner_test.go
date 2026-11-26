package cmdrunner

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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

	// No hub json -> offline (isolate from host ANTIGRAVITY_LS_ADDRESS env during unit test)
	t.Setenv("ANTIGRAVITY_LS_ADDRESS", "")
	t.Setenv("ANTIGRAVITY_AGENTAPI_EXE", "")
	if _, err := r.SendMessage(context.Background(), "conv-1", "hi"); !errors.Is(err, ErrDesktopOffline) {
		t.Fatalf("expected ErrDesktopOffline, got %v", err)
	}

	// Write live hub metadata
	_ = os.WriteFile(filepath.Join(daemonDir, "hub_4242.json"), []byte(`{"pid":4242,"httpPort":51234,"csrfToken":"tok-abc"}`), 0o600)
	fx := &fakeExec{resp: []byte(`{"response":{"newConversation":{"conversationId":"conv-new"}}}`)}
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
	if len(fx.lastEnv) != 2 || fx.lastEnv[0] != "ANTIGRAVITY_LS_ADDRESS=127.0.0.1:51234" || fx.lastEnv[1] != "ANTIGRAVITY_CSRF_TOKEN=tok-abc" {
		t.Fatalf("unexpected env: %v", fx.lastEnv)
	}
}

func TestSendMessageUsesSendUserCascadeMessage(t *testing.T) {
	var gotPath, gotCSRF, gotConnect string
	var gotBody struct {
		CascadeID string `json:"cascadeId"`
		Items     []struct {
			Text string `json:"text"`
		} `json:"items"`
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotCSRF = r.Header.Get("x-codeium-csrf-token")
		gotConnect = r.Header.Get("Connect-Protocol-Version")
		if err := json.NewDecoder(r.Body).Decode(&gotBody); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	tmp := t.TempDir()
	daemonDir := filepath.Join(tmp, "daemon")
	_ = os.MkdirAll(daemonDir, 0o755)
	port := strings.TrimPrefix(srv.URL, "http://127.0.0.1:")
	_ = os.WriteFile(filepath.Join(daemonDir, "hub_999.json"), []byte(`{"pid":999,"httpPort":`+port+`,"csrfToken":"csrf-xyz"}`), 0o600)

	t.Setenv("ANTIGRAVITY_LS_ADDRESS", "")
	t.Setenv("ANTIGRAVITY_CSRF_TOKEN", "")
	r := New("/nonexistent/agentapi", daemonDir)
	r.pidAliveFn = func(pid int) bool { return pid == 999 }

	res, err := r.SendMessage(context.Background(), "conv-user-1", "继续修复")
	if err != nil {
		t.Fatalf("SendMessage failed: %v", err)
	}
	if res.ConversationID != "conv-user-1" {
		t.Fatalf("unexpected result: %+v", res)
	}
	if gotPath != "/exa.language_server_pb.LanguageServerService/SendUserCascadeMessage" {
		t.Fatalf("expected SendUserCascadeMessage RPC path, got %q", gotPath)
	}
	if gotCSRF != "csrf-xyz" || gotConnect != "1" {
		t.Fatalf("unexpected headers: csrf=%q connect=%q", gotCSRF, gotConnect)
	}
	if gotBody.CascadeID != "conv-user-1" || len(gotBody.Items) != 1 || gotBody.Items[0].Text != "继续修复" {
		t.Fatalf("unexpected payload: %+v", gotBody)
	}

	// Non-2xx response must surface as error.
	errSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"code":"not_found"}`))
	}))
	defer errSrv.Close()
	t.Setenv("ANTIGRAVITY_LS_ADDRESS", strings.TrimPrefix(errSrv.URL, "http://"))
	if _, err := r.SendMessage(context.Background(), "missing", "hi"); err == nil || !strings.Contains(err.Error(), "404") {
		t.Fatalf("expected HTTP 404 error, got %v", err)
	}
}
