package sidecarui

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/antigravity-mobile/bridge/internal/agyreader"
	"github.com/antigravity-mobile/bridge/internal/brainwatcher"
	"github.com/antigravity-mobile/bridge/internal/cmdrunner"
	"github.com/antigravity-mobile/bridge/internal/config"
	"github.com/antigravity-mobile/bridge/internal/hubserver"
	"github.com/antigravity-mobile/bridge/internal/notifier"
	"github.com/antigravity-mobile/bridge/internal/quotamonitor"
	"github.com/antigravity-mobile/bridge/internal/statestore"
)

func TestSidecarUIStatusAndTokenAuth(t *testing.T) {
	svg, err := BuildQRSVG(`{"v":1,"hostName":"Test"}`)
	if err != nil || !strings.Contains(svg, "<svg") || !strings.Contains(svg, "</svg>") {
		t.Fatalf("BuildQRSVG failed: err=%v", err)
	}

	tmp := t.TempDir()
	cfg := &config.Config{
		HostName:         "ClawStation",
		ListenAddr:       "0.0.0.0:8765",
		AntigravityDir:   tmp,
		BootstrapToken:   "agy_live_old",
		SubscriptionTier: "Google AI Ultra",
		Gemini5hBudget:   1000,
		Gemini7dBudget:   10000,
		Claude5hBudget:   1000,
		Claude7dBudget:   10000,
	}
	st, err := statestore.Open(filepath.Join(tmp, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	reader := agyreader.New(filepath.Join(tmp, "none.db"))
	watcher := brainwatcher.New(filepath.Join(tmp, "brain"), st, brainwatcher.EventCallbacks{})
	quota, _ := quotamonitor.NewMonitor(st, cfg.SubscriptionTier, 1000, 10000, 1000, 10000)
	runner := cmdrunner.New(filepath.Join(tmp, "agentapi"), filepath.Join(tmp, "daemon"))
	notif := notifier.NewManager(st)
	hub := hubserver.New(cfg, st, reader, watcher, quota, runner, notif)

	uiSrv := New(hub, filepath.Join(tmp, "config.json"), "secret_ui_tok")
	ts := httptest.NewServer(uiSrv.Handler())
	defer ts.Close()

	// GET / returns HTML page
	resp, err := http.Get(ts.URL + "/")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("GET / failed: status=%d err=%v", resp.StatusCode, err)
	}

	// POST without sidecar token rejected with 401
	resp2, err := http.Post(ts.URL+"/api/test-notify", "application/json", strings.NewReader("{}"))
	if err != nil || resp2.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 without token, got %d", resp2.StatusCode)
	}

	// POST with valid x-sidecar-token succeeds
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/test-notify", strings.NewReader(`{"title":"hi"}`))
	req.Header.Set("x-sidecar-token", "secret_ui_tok")
	resp3, err := http.DefaultClient.Do(req)
	if err != nil || resp3.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 with token, got %d err=%v", resp3.StatusCode, err)
	}
}
