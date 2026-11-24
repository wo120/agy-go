package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/antigravity-mobile/bridge/internal/config"
)

func TestRunHookIOForwardingAndFiltering(t *testing.T) {
	var mu sync.Mutex
	var received []map[string]any

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/internal/hook" || r.Header.Get("Authorization") != "Bearer agy_live_hook" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		var payload map[string]any
		_ = json.NewDecoder(r.Body).Decode(&payload)
		mu.Lock()
		received = append(received, payload)
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	defer ts.Close()

	cfg := &config.Config{
		ListenAddr:     strings.TrimPrefix(ts.URL, "http://"),
		BootstrapToken: "agy_live_hook",
	}

	// 1. Normal stop -> forwards TASK_COMPLETED and outputs "{}"
	var out bytes.Buffer
	runHookIO(cfg, "stop", strings.NewReader(`{"conversationId":"c1","terminationReason":"NO_TOOL_CALL"}`), &out)
	if strings.TrimSpace(out.String()) != "{}" {
		t.Fatalf("expected {} stdout, got %q", out.String())
	}

	// 2. USER_CANCELED stop -> suppressed, still outputs "{}"
	out.Reset()
	runHookIO(cfg, "stop", strings.NewReader(`{"conversationId":"c1","terminationReason":"USER_CANCELED"}`), &out)
	if strings.TrimSpace(out.String()) != "{}" {
		t.Fatalf("expected {} stdout on cancel, got %q", out.String())
	}

	// 3. PostToolUse ask_question -> forwards NEED_CONFIRM
	out.Reset()
	runHookIO(cfg, "post-tool-use", strings.NewReader(`{"conversationId":"c2","toolCall":{"name":"ask_question"}}`), &out)
	if strings.TrimSpace(out.String()) != "{}" {
		t.Fatalf("expected {} stdout on ask_question, got %q", out.String())
	}

	// 4. PostToolUse read_file -> ignored
	out.Reset()
	runHookIO(cfg, "post-tool-use", strings.NewReader(`{"conversationId":"c2","toolCall":{"name":"read_file"}}`), &out)

	mu.Lock()
	defer mu.Unlock()
	if len(received) != 2 {
		t.Fatalf("expected 2 forwarded hook alerts, got %d: %+v", len(received), received)
	}
	if received[0]["kind"] != "TASK_COMPLETED" || received[0]["conversationId"] != "c1" {
		t.Fatalf("unexpected first hook payload: %+v", received[0])
	}
	if received[1]["kind"] != "NEED_CONFIRM" || received[1]["conversationId"] != "c2" {
		t.Fatalf("unexpected second hook payload: %+v", received[1])
	}
}
