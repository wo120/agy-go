package sidecarui

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/antigravity-mobile/bridge/internal/agyreader"
	"github.com/antigravity-mobile/bridge/internal/brainwatcher"
	"github.com/antigravity-mobile/bridge/internal/cmdrunner"
	"github.com/antigravity-mobile/bridge/internal/config"
	"github.com/antigravity-mobile/bridge/internal/hubserver"
	"github.com/antigravity-mobile/bridge/internal/notifier"
	"github.com/antigravity-mobile/bridge/internal/quotamonitor"
	"github.com/antigravity-mobile/bridge/internal/statestore"
	"github.com/antigravity-mobile/bridge/internal/tpsmonitor"
	"github.com/antigravity-mobile/bridge/internal/tsfunnel"
)

type stubTunnel struct {
	st tsfunnel.Status
}

func (s *stubTunnel) Status() tsfunnel.Status { return s.st }
func (s *stubTunnel) Enable() error {
	s.st.Enabled = true
	s.st.State = tsfunnel.StateNeedsLogin
	s.st.AuthURL = "https://login.tailscale.com/a/test123"
	return nil
}
func (s *stubTunnel) Disable() error {
	s.st.Enabled = false
	s.st.State = tsfunnel.StateDisabled
	s.st.AuthURL = ""
	return nil
}
func (s *stubTunnel) Logout() error { return s.Disable() }
func (s *stubTunnel) Endpoints() []string {
	if s.st.FunnelURL != "" {
		return []string{s.st.FunnelURL}
	}
	return nil
}

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
	tpsMon := tpsmonitor.NewMonitor(filepath.Join(tmp, "daemon"), st)
	hub.SetTPSMonitor(tpsMon)
	_ = st.RecordTPSSamples([]statestore.TPSSample{
		{
			ConversationID: "conv-ui",
			StepIndex:      2,
			CreatedAtUnix:  time.Now().Unix() - 20,
			PoolID:         "gemini",
			Model:          "gemini-4-neon",
			ModelDisplay:   "Gemini 4 Neon (High)",
			OutputTokens:   1500,
			TTFTMs:         5000,
			StreamingMs:    10000,
		},
	})

	uiSrv := New(hub, filepath.Join(tmp, "config.json"), "secret_ui_tok")
	ts := httptest.NewServer(uiSrv.Handler())
	defer ts.Close()

	// GET / returns HTML page with TPS monitoring card
	resp, err := http.Get(ts.URL + "/")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("GET / failed: status=%d err=%v", resp.StatusCode, err)
	}
	htmlBytes, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if !strings.Contains(string(htmlBytes), "输出速度监控 (TPS · 5h)") {
		t.Fatalf("expected Sidecar HTML to contain TPS monitor card")
	}
	if !strings.Contains(string(htmlBytes), `headers: { "x-sidecar-token": SIDECAR_TOKEN }`) ||
		!strings.Contains(string(htmlBytes), "escHtml(e)") ||
		!strings.Contains(string(htmlBytes), "escHtml(p.displayName)") {
		t.Fatalf("expected Sidecar HTML to include token header on /api/status and HTML escaping")
	}

	// GET /api/status without sidecar token rejected with 401 (prevents local token theft)
	unauthStatusResp, err := http.Get(ts.URL + "/api/status")
	if err != nil || unauthStatusResp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 on /api/status without token, got status=%d err=%v", unauthStatusResp.StatusCode, err)
	}
	_ = unauthStatusResp.Body.Close()

	// GET /api/status with valid x-sidecar-token returns live TPS snapshot
	stReq, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/status", nil)
	stReq.Header.Set("x-sidecar-token", "secret_ui_tok")
	stResp, err := http.DefaultClient.Do(stReq)
	if err != nil || stResp.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/status failed: status=%d err=%v", stResp.StatusCode, err)
	}
	var stBody struct {
		TPS *tpsmonitor.TPSSnapshot `json:"tps"`
	}
	if err := json.NewDecoder(stResp.Body).Decode(&stBody); err != nil {
		t.Fatalf("decode /api/status: %v", err)
	}
	_ = stResp.Body.Close()
	if stBody.TPS == nil || stBody.TPS.StreamTPS != 150.0 || stBody.TPS.E2ETPS != 100.0 || len(stBody.TPS.Models) != 1 {
		t.Fatalf("unexpected TPS payload in /api/status: %+v", stBody.TPS)
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

	// Tunnel enable endpoint requires sidecar token and returns updated authUrl state
	hub.SetTunnel(&stubTunnel{st: tsfunnel.Status{State: tsfunnel.StateDisabled, Hostname: "agy-test"}})
	resp4, err := http.Post(ts.URL+"/api/tunnel/enable", "application/json", strings.NewReader("{}"))
	if err != nil || resp4.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 on /api/tunnel/enable without token, got %d err=%v", resp4.StatusCode, err)
	}
	req5, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/tunnel/enable", strings.NewReader("{}"))
	req5.Header.Set("x-sidecar-token", "secret_ui_tok")
	resp5, err := http.DefaultClient.Do(req5)
	if err != nil || resp5.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 on /api/tunnel/enable with token, got %d err=%v", resp5.StatusCode, err)
	}
}
