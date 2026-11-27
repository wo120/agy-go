package hubserver

import (
	"bytes"
	"compress/gzip"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	_ "modernc.org/sqlite"

	"github.com/antigravity-mobile/bridge/internal/agyreader"
	"github.com/antigravity-mobile/bridge/internal/brainwatcher"
	"github.com/antigravity-mobile/bridge/internal/cmdrunner"
	"github.com/antigravity-mobile/bridge/internal/config"
	"github.com/antigravity-mobile/bridge/internal/notifier"
	"github.com/antigravity-mobile/bridge/internal/quotamonitor"
	"github.com/antigravity-mobile/bridge/internal/statestore"
	"github.com/antigravity-mobile/bridge/internal/tpsmonitor"
	"github.com/antigravity-mobile/bridge/internal/tsfunnel"
)

type fakeTunnel struct {
	st tsfunnel.Status
}

func (f *fakeTunnel) Status() tsfunnel.Status { return f.st }
func (f *fakeTunnel) Enable() error           { f.st.Enabled = true; f.st.State = tsfunnel.StateRunning; return nil }
func (f *fakeTunnel) Disable() error          { f.st.Enabled = false; f.st.State = tsfunnel.StateDisabled; return nil }
func (f *fakeTunnel) Logout() error           { return f.Disable() }
func (f *fakeTunnel) Endpoints() []string {
	if f.st.FunnelURL != "" {
		return []string{f.st.FunnelURL}
	}
	return nil
}

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
	tpsMon := tpsmonitor.NewMonitor(filepath.Join(agyDir, "daemon"), store)
	srv.SetTPSMonitor(tpsMon)
	_ = store.RecordTPSSamples([]statestore.TPSSample{
		{
			ConversationID: "conv-1",
			StepIndex:      1,
			CreatedAtUnix:  time.Now().Unix() - 30,
			PoolID:         "gemini",
			Model:          "gemini-4-neon",
			ModelDisplay:   "Gemini 4 Neon (High)",
			OutputTokens:   1200,
			TTFTMs:         4000,
			StreamingMs:    8000,
		},
	})
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

	// 5. Large sessions.get supports gzip compression and filters GENERIC noise
	bigPad := strings.Repeat("x", 2048)
	_ = os.WriteFile(filepath.Join(logsDir, "transcript.jsonl"), []byte(
		`{"step_index":0,"source":"SYSTEM","type":"GENERIC","status":"DONE","created_at":"2026-11-24T12:34:00Z","content":"`+bigPad+`"}`+"\n"+
			`{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T12:35:00Z","model":"gemini-4-neon-xhigh","content":"`+bigPad+`"}`+"\n",
	), 0o644)

	gzBody, _ := json.Marshal(map[string]any{
		"requestId": "r-gz",
		"method":    "sessions.get",
		"params":    map[string]any{"conversationId": "conv-1", "limit": 80},
	})
	gzReq, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/rpc", bytes.NewReader(gzBody))
	gzReq.Header.Set("Authorization", "Bearer agy_live_testtoken")
	gzReq.Header.Set("Accept-Encoding", "gzip")
	rawClient := &http.Client{Transport: &http.Transport{DisableCompression: true}}
	gzResp, err := rawClient.Do(gzReq)
	if err != nil {
		t.Fatalf("sessions.get gzip req: %v", err)
	}
	defer gzResp.Body.Close()
	if gzResp.Header.Get("Content-Encoding") != "gzip" {
		t.Fatalf("expected Content-Encoding: gzip, got %q", gzResp.Header.Get("Content-Encoding"))
	}
	gr, err := gzip.NewReader(gzResp.Body)
	if err != nil {
		t.Fatalf("gzip reader: %v", err)
	}
	defer gr.Close()
	var sessOut struct {
		OK   bool `json:"ok"`
		Data struct {
			Steps []brainwatcher.TranscriptStep `json:"steps"`
		} `json:"data"`
	}
	if err := json.NewDecoder(gr).Decode(&sessOut); err != nil {
		t.Fatalf("decode gzipped sessions.get: %v", err)
	}
	if !sessOut.OK || len(sessOut.Data.Steps) != 1 || sessOut.Data.Steps[0].StepIndex != 1 {
		t.Fatalf("expected 1 compacted visible step (index 1), got %+v", sessOut)
	}
	if sessOut.Data.Steps[0].StreamTPS != 150.0 || sessOut.Data.Steps[0].E2ETPS != 100.0 || sessOut.Data.Steps[0].TTFTMs != 4000 {
		t.Fatalf("expected step 1 enriched with TPS/TTFT, got %+v", sessOut.Data.Steps[0])
	}

	// 5b. tps.get RPC returns 5h snapshot and latest turn
	tpsBody, _ := json.Marshal(map[string]any{
		"requestId": "r-tps",
		"method":    "tps.get",
		"params":    map[string]any{"refresh": false},
	})
	tpsReq, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/rpc", bytes.NewReader(tpsBody))
	tpsReq.Header.Set("Authorization", "Bearer agy_live_testtoken")
	tpsResp, err := http.DefaultClient.Do(tpsReq)
	if err != nil {
		t.Fatalf("tps.get req: %v", err)
	}
	defer tpsResp.Body.Close()
	var tpsOut struct {
		OK   bool                   `json:"ok"`
		Data tpsmonitor.TPSSnapshot `json:"data"`
	}
	if err := json.NewDecoder(tpsResp.Body).Decode(&tpsOut); err != nil {
		t.Fatalf("decode tps.get: %v", err)
	}
	if !tpsOut.OK || tpsOut.Data.StreamTPS != 150.0 || tpsOut.Data.E2ETPS != 100.0 || tpsOut.Data.Latest == nil {
		t.Fatalf("unexpected tps.get output: %+v", tpsOut)
	}

	// 6. Attached TunnelProvider injects public Funnel HTTPS endpoint into pairing payload
	srv.SetTunnel(&fakeTunnel{
		st: tsfunnel.Status{
			Enabled:   true,
			State:     tsfunnel.StateRunning,
			Hostname:  "agy-clawstation",
			FunnelURL: "https://agy-clawstation.tail123.ts.net",
		},
	})
	summary := srv.StatusSummary(t.Context())
	eps, _ := summary["endpoints"].([]string)
	foundFunnel := false
	for _, ep := range eps {
		if ep == "https://agy-clawstation.tail123.ts.net" {
			foundFunnel = true
		}
	}
	if !foundFunnel {
		t.Fatalf("expected Funnel URL injected into endpoints, got %v", eps)
	}
}

func TestSecurityHardening(t *testing.T) {
	tmp := t.TempDir()
	agyDir := filepath.Join(tmp, "antigravity")
	_ = os.MkdirAll(filepath.Join(agyDir, "brain", "conv-1"), 0o755)
	_ = os.MkdirAll(filepath.Join(agyDir, "daemon"), 0o755)

	cfg := &config.Config{
		HostName:         "ClawStation",
		AntigravityDir:   agyDir,
		BootstrapToken:   "agy_live_initial_token",
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

	reader := agyreader.New(filepath.Join(agyDir, "none.db"))
	watcher := brainwatcher.New(filepath.Join(agyDir, "brain"), store, brainwatcher.EventCallbacks{})
	quota, _ := quotamonitor.NewMonitor(store, cfg.SubscriptionTier, 10000, 100000, 10000, 100000)
	runner := cmdrunner.New(filepath.Join(agyDir, "bin", "agentapi"), filepath.Join(agyDir, "daemon"))
	notif := notifier.NewManager(store)

	srv := New(cfg, store, reader, watcher, quota, runner, notif)
	srv.wsAuthTimeoutDur = 150 * time.Millisecond
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	rpcCall := func(token, method string, params any) (int, RPCResponse) {
		b, _ := json.Marshal(map[string]any{"requestId": "sec-1", "method": method, "params": params})
		req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/rpc", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Body.Close()
		var out RPCResponse
		_ = json.NewDecoder(r.Body).Decode(&out)
		return r.StatusCode, out
	}

	// 1. Conversation ID traversal rejected across RPC methods and WS sub
	for _, badID := range []string{"../", "../../etc", `a\b`, "a/b", "."} {
		for _, method := range []string{"sessions.get", "artifacts.list"} {
			status, out := rpcCall("agy_live_initial_token", method, map[string]any{"conversationId": badID})
			if status != http.StatusOK || out.OK || out.Error == nil || out.Error.Code != "INVALID_ARGS" {
				t.Fatalf("%s with %q: expected INVALID_ARGS, got status=%d resp=%+v", method, badID, status, out)
			}
		}
	}

	// 2. Authenticated WS connection rejects traversal channel subscription
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/api/v1/mux"
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer agy_live_initial_token")
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, hdr)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer conn.Close()

	var initSnap MuxFrame
	if err := conn.ReadJSON(&initSnap); err != nil {
		t.Fatalf("read initial snapshot: %v", err)
	}
	if err := conn.WriteJSON(MuxFrame{Type: "sub", Channel: "session:../../"}); err != nil {
		t.Fatal(err)
	}
	var errFrame MuxFrame
	if err := conn.ReadJSON(&errFrame); err != nil {
		t.Fatalf("expected error frame on traversal sub: %v", err)
	}
	if errFrame.Type != "error" || errFrame.Error == nil || errFrame.Error.Code != "INVALID_ARGS" {
		t.Fatalf("unexpected frame for traversal sub: %+v", errFrame)
	}

	// 3. RotateBootstrapToken disconnects existing WS clients and invalidates old token
	cfgPath := filepath.Join(tmp, "config.json")
	newTok, err := srv.RotateBootstrapToken(cfgPath)
	if err != nil || newTok == "" || newTok == "agy_live_initial_token" {
		t.Fatalf("RotateBootstrapToken failed: tok=%q err=%v", newTok, err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	var afterRotate MuxFrame
	if err := conn.ReadJSON(&afterRotate); err == nil {
		t.Fatalf("expected existing WS connection to be closed on token rotation, but read frame: %+v", afterRotate)
	}
	if st, _ := rpcCall("agy_live_initial_token", "alerts.list", map[string]any{}); st != http.StatusUnauthorized {
		t.Fatalf("expected old token to be rejected with 401, got %d", st)
	}
	if st, out := rpcCall(newTok, "alerts.list", map[string]any{}); st != http.StatusOK || !out.OK {
		t.Fatalf("expected new token to succeed, got status=%d resp=%+v", st, out)
	}

	// 4. Unauthenticated WS connection is closed after auth timeout
	unauthConn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("unauth ws dial: %v", err)
	}
	defer unauthConn.Close()
	_ = unauthConn.SetReadDeadline(time.Now().Add(2 * time.Second))
	var idleFrame MuxFrame
	if err := unauthConn.ReadJSON(&idleFrame); err == nil {
		t.Fatalf("expected unauthenticated idle WS to be closed by timeout, got frame: %+v", idleFrame)
	}
}

func TestPendingInteractionsRPCAndWSFlow(t *testing.T) {
	tmp := t.TempDir()
	agyDir := filepath.Join(tmp, "antigravity")
	brainConv := filepath.Join(agyDir, "brain", "conv-auth")
	logsDir := filepath.Join(brainConv, ".system_generated", "logs")
	_ = os.MkdirAll(logsDir, 0o755)
	_ = os.MkdirAll(filepath.Join(agyDir, "daemon"), 0o755)

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
			('conv-auth', '进程检查任务', '准备执行 ps 命令', 8, '2026-11-27 12:35:00+00:00', '["file:///tmp"]', 'CASCADE_RUN_STATUS_RUNNING', '', '', 0, 1, 0, '2026-11-27 12:34:00+00:00', 0);
	`)
	_ = db.Close()
	if err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(logsDir, "transcript.jsonl"), []byte(
		`{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-27T12:34:00Z","content":"检查进程"}`+"\n",
	), 0o644)

	resolved := false
	var gotHandleReq map[string]any
	lsSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/exa.language_server_pb.LanguageServerService/GetAllCascadeTrajectories":
			w.WriteHeader(http.StatusOK)
			if resolved {
				_, _ = w.Write([]byte(`{"trajectorySummaries":{"conv-auth":{"trajectoryId":"traj-1","waitingSteps":[]}}}`))
				return
			}
			_, _ = w.Write([]byte(`{
				"trajectorySummaries": {
					"conv-auth": {
						"trajectoryId": "traj-1",
						"waitingSteps": [
							{
								"stepIndex": 8,
								"step": {
									"type": "CORTEX_STEP_TYPE_GENERIC",
									"status": "CORTEX_STEP_STATUS_WAITING",
									"requestedInteraction": {
										"permission": {
											"resource": {"action": "command", "target": "ps -eo pid,comm,args"},
											"persistSuggestionType": "PERSIST_SUGGESTION_TYPE_SUGGESTED",
											"suggestedPersistPattern": "ps",
											"actionDescription": "检查当前运行进程",
											"shellName": "zsh"
										}
									}
								}
							}
						]
					}
				}
			}`))
		case "/exa.language_server_pb.LanguageServerService/HandleCascadeUserInteraction":
			_ = json.NewDecoder(r.Body).Decode(&gotHandleReq)
			resolved = true
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{}`))
		default:
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{}`))
		}
	}))
	defer lsSrv.Close()

	t.Setenv("ANTIGRAVITY_LS_ADDRESS", strings.TrimPrefix(lsSrv.URL, "http://"))
	t.Setenv("ANTIGRAVITY_CSRF_TOKEN", "csrf-test")

	cfg := &config.Config{
		HostName:         "ClawStation",
		AntigravityDir:   agyDir,
		BootstrapToken:   "agy_live_perm_test",
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
	quota, _ := quotamonitor.NewMonitor(store, cfg.SubscriptionTier, 10000, 100000, 10000, 100000)
	runner := cmdrunner.New(filepath.Join(agyDir, "bin", "agentapi"), filepath.Join(agyDir, "daemon"))
	notif := notifier.NewManager(store)

	srv := New(cfg, store, reader, watcher, quota, runner, notif)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// 1. Connect WS and subscribe to session:conv-auth; snapshot includes pendingInteractions
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/api/v1/mux"
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer agy_live_perm_test")
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, hdr)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer conn.Close()

	var globalSnap MuxFrame
	if err := conn.ReadJSON(&globalSnap); err != nil {
		t.Fatalf("read global snapshot: %v", err)
	}
	if err := conn.WriteJSON(MuxFrame{Type: "sub", Channel: "session:conv-auth"}); err != nil {
		t.Fatal(err)
	}
	var sessSnap MuxFrame
	if err := conn.ReadJSON(&sessSnap); err != nil {
		t.Fatalf("read session snapshot: %v", err)
	}
	snapMap := sessSnap.Data.(map[string]any)
	pendingList := snapMap["pendingInteractions"].([]any)
	if len(pendingList) != 1 {
		t.Fatalf("expected 1 pending interaction in session snapshot, got %+v", snapMap["pendingInteractions"])
	}
	sessionMap := snapMap["session"].(map[string]any)
	if sessionMap["needsConfirm"] != true || int(sessionMap["pendingInteractionCount"].(float64)) != 1 {
		t.Fatalf("expected needsConfirm=true and pendingInteractionCount=1, got %+v", sessionMap)
	}

	// 2. Submit permission decision via sessions.respondInteraction
	reqBody, _ := json.Marshal(map[string]any{
		"requestId": "perm-req-1",
		"method":    "sessions.respondInteraction",
		"params": map[string]any{
			"conversationId": "conv-auth",
			"stepIndex":      8,
			"kind":           "permission",
			"allow":          true,
			"scope":          "once",
		},
	})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/rpc", bytes.NewReader(reqBody))
	req.Header.Set("Authorization", "Bearer agy_live_perm_test")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var rpcOut struct {
		OK   bool `json:"ok"`
		Data struct {
			Handled             bool                           `json:"handled"`
			PendingInteractions []cmdrunner.PendingInteraction `json:"pendingInteractions"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&rpcOut); err != nil {
		t.Fatal(err)
	}
	if !rpcOut.OK || !rpcOut.Data.Handled || len(rpcOut.Data.PendingInteractions) != 0 {
		t.Fatalf("expected handled=true with 0 remaining interactions, got %+v", rpcOut)
	}
	if gotHandleReq == nil || gotHandleReq["cascadeId"] != "conv-auth" {
		t.Fatalf("expected HandleCascadeUserInteraction called for conv-auth, got %+v", gotHandleReq)
	}

	// 3. WS receives interaction.updated clearing the pending list
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	sawCleared := false
	for i := 0; i < 4; i++ {
		var frame MuxFrame
		if err := conn.ReadJSON(&frame); err != nil {
			break
		}
		if frame.Type == "event" && frame.Event == "interaction.updated" {
			dataMap := frame.Data.(map[string]any)
			if list, ok := dataMap["pendingInteractions"].([]any); ok && len(list) == 0 {
				sawCleared = true
				break
			}
		}
	}
	if !sawCleared {
		t.Fatal("expected WS interaction.updated event with empty pendingInteractions after approval")
	}
}
