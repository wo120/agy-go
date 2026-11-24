package hubserver

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
	_ "modernc.org/sqlite"

	"github.com/antigravity-mobile/bridge/internal/agyreader"
	"github.com/antigravity-mobile/bridge/internal/brainwatcher"
	"github.com/antigravity-mobile/bridge/internal/cmdrunner"
	"github.com/antigravity-mobile/bridge/internal/config"
	"github.com/antigravity-mobile/bridge/internal/notifier"
	"github.com/antigravity-mobile/bridge/internal/quotamonitor"
	"github.com/antigravity-mobile/bridge/internal/statestore"
)

func TestRPCFileSandboxAndMuxWS(t *testing.T) {
	tmp := t.TempDir()
	agyDir := filepath.Join(tmp, "antigravity")
	brainConv := filepath.Join(agyDir, "brain", "conv-1")
	logsDir := filepath.Join(brainConv, ".system_generated", "logs")
	_ = os.MkdirAll(logsDir, 0o755)
	_ = os.MkdirAll(filepath.Join(agyDir, "daemon"), 0o755)

	// Seed Antigravity native DB fixture
	agyDBPath := filepath.Join(agyDir, "conversation_summaries.db")
	db, err := sql.Open("sqlite", agyDBPath)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`
		CREATE TABLE conversation_summaries (
			conversation_id TEXT PRIMARY KEY,
			title TEXT NOT NULL DEFAULT "",
			preview TEXT NOT NULL DEFAULT "",
			step_count INTEGER NOT NULL DEFAULT 0,
			last_modified_time DATETIME NOT NULL,
			workspace_uris TEXT NOT NULL,
			status TEXT NOT NULL DEFAULT "",
			source TEXT NOT NULL DEFAULT "",
			parent_conversation_id TEXT NOT NULL DEFAULT "",
			nesting_depth INTEGER NOT NULL DEFAULT 0,
			not_fully_idle NUMERIC NOT NULL DEFAULT 0,
			killed NUMERIC NOT NULL DEFAULT 0,
			last_user_input_time DATETIME NOT NULL,
			last_user_input_step_index INTEGER NOT NULL DEFAULT -1
		);
		CREATE TABLE conversation_parents (conversation_id TEXT PRIMARY KEY, parent_id TEXT NOT NULL) WITHOUT ROWID;
		INSERT INTO conversation_summaries VALUES
			('conv-1', 'Antigravity iOS App', '完成架构设计', 4, '2026-11-24 12:35:00+00:00', '["file:///tmp"]', 'CASCADE_RUN_STATUS_IDLE', '', '', 0, 0, 0, '2026-11-24 12:34:00+00:00', 2);
	`)
	_ = db.Close()
	if err != nil {
		t.Fatal(err)
	}

	_ = os.WriteFile(filepath.Join(brainConv, "plan.md"), []byte("# Spec\nOK"), 0o644)
	_ = os.WriteFile(filepath.Join(logsDir, "transcript.jsonl"), []byte(
		`{"step_index":0,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T12:35:00Z","model":"gemini-4-neon-xhigh","input_tokens":1000,"output_tokens":200,"content":"完成架构设计"}`+"\n",
	), 0o644)

	cfg := &config.Config{
		HostName:         "ClawStation",
		AntigravityDir:   agyDir,
		BootstrapToken:   "agy_live_testtoken",
		SubscriptionTier: "Google AI Ultra",
		Gemini5hBudget:   10000,
		Gemini7dBudget:   100000,
		Claude5hBudget:   10000,
		Claude7dBudget:   100000,
	}
	store, err := statestore.Open(filepath.Join(tmp, "bridge_state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	reader := agyreader.New(agyDBPath)
	watcher := brainwatcher.New(filepath.Join(agyDir, "brain"), store, brainwatcher.EventCallbacks{})
	_ = watcher.ScanAll()
	quota, err := quotamonitor.NewMonitor(store, cfg.SubscriptionTier, cfg.Gemini5hBudget, cfg.Gemini7dBudget, cfg.Claude5hBudget, cfg.Claude7dBudget)
	if err != nil {
		t.Fatal(err)
	}
	runner := cmdrunner.New(filepath.Join(agyDir, "bin", "agentapi"), filepath.Join(agyDir, "daemon"))
	notif := notifier.NewManager(store)

	srv := New(cfg, store, reader, watcher, quota, runner, notif)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// 1. Unauthorized rejected
	resp, err := http.Post(ts.URL+"/api/v1/rpc", "application/json", strings.NewReader(`{"method":"quota.get"}`))
	if err != nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got status=%d err=%v", resp.StatusCode, err)
	}

	// 2. Authenticated RPC sessions.list
	rpcReq := func(method string, params any) RPCResponse {
		b, _ := json.Marshal(map[string]any{"requestId": "r1", "method": method, "params": params})
		req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/rpc", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer agy_live_testtoken")
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Body.Close()
		var out RPCResponse
		if err := json.NewDecoder(r.Body).Decode(&out); err != nil {
			t.Fatal(err)
		}
		return out
	}

	listResp := rpcReq("sessions.list", map[string]any{"mode": "desktop"})
	if !listResp.OK {
		t.Fatalf("sessions.list failed: %+v", listResp)
	}

	// 3. Sandboxed artifact file content
	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/v1/files/content?convId=conv-1&path=plan.md", nil)
	req.Header.Set("Authorization", "Bearer agy_live_testtoken")
	fr, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer fr.Body.Close()
	var fileOut RPCResponse
	_ = json.NewDecoder(fr.Body).Decode(&fileOut)
	if !fileOut.OK {
		t.Fatalf("expected artifact read ok, got %+v", fileOut)
	}

	// 4. WebSocket Mux receives initial $global snapshot + ping/pong RTT
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/api/v1/mux"
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer agy_live_testtoken")
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, hdr)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer conn.Close()

	var snap MuxFrame
	if err := conn.ReadJSON(&snap); err != nil {
		t.Fatalf("read ws snapshot: %v", err)
	}
	if snap.Type != "snapshot" || snap.Channel != "$global" || snap.Seq != 1 {
		t.Fatalf("unexpected initial ws frame: %+v", snap)
	}

	if err := conn.WriteJSON(MuxFrame{Type: "ping", ClientTs: 12345}); err != nil {
		t.Fatal(err)
	}
	var pong MuxFrame
	if err := conn.ReadJSON(&pong); err != nil {
		t.Fatal(err)
	}
	if pong.Type != "pong" || pong.ClientTs != 12345 {
		t.Fatalf("unexpected pong frame: %+v", pong)
	}
}
