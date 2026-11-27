package hubserver

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"github.com/antigravity-mobile/bridge/internal/agyreader"
	"github.com/antigravity-mobile/bridge/internal/brainwatcher"
	"github.com/antigravity-mobile/bridge/internal/cmdrunner"
	"github.com/antigravity-mobile/bridge/internal/config"
	"github.com/antigravity-mobile/bridge/internal/filesandbox"
	"github.com/antigravity-mobile/bridge/internal/notifier"
	"github.com/antigravity-mobile/bridge/internal/quotamonitor"
	"github.com/antigravity-mobile/bridge/internal/statestore"
	"github.com/antigravity-mobile/bridge/internal/tpsmonitor"
	"github.com/antigravity-mobile/bridge/internal/tsfunnel"
)

// TunnelProvider abstracts the embedded remote 5G tunnel (Tailscale tsnet + Funnel).
type TunnelProvider interface {
	Status() tsfunnel.Status
	Enable() error
	Disable() error
	Logout() error
	Endpoints() []string
}

const ProtocolVersion = 1

// SessionCard combines Antigravity's read-only summary with brain stats and sidecar metadata.
type SessionCard struct {
	ConversationID   string                  `json:"conversationId"`
	Title            string                  `json:"title"`
	Preview          string                  `json:"preview"`
	StepCount        int                     `json:"stepCount"`
	LastModifiedUnix int64                   `json:"lastModifiedUnix"`
	Workspace        agyreader.WorkspaceInfo `json:"workspace"`
	Status           string                  `json:"status"`
	Running          bool                    `json:"running"`
	SubagentCount    int                     `json:"subagentCount"`
	ArtifactCount    int                     `json:"artifactCount"`
	Model            string                  `json:"model,omitempty"`
	ModelDisplay     string                  `json:"modelDisplay,omitempty"`
	Pinned                  bool                    `json:"pinned"`
	PinnedOrder             int                     `json:"pinnedOrder"`
	Unread                  bool                    `json:"unread"`
	NeedsConfirm            bool                    `json:"needsConfirm"`
	PendingInteractionCount int                     `json:"pendingInteractionCount,omitempty"`
}

// ProjectGroup groups sessions by workspace when mode == "project".
type ProjectGroup struct {
	Workspace        agyreader.WorkspaceInfo `json:"workspace"`
	LatestActiveUnix int64                   `json:"latestActiveUnix"`
	Sessions         []SessionCard           `json:"sessions"`
}

// RPCRequest is the uniform envelope for POST /api/v1/rpc.
type RPCRequest struct {
	RequestID string          `json:"requestId"`
	Method    string          `json:"method"`
	Params    json.RawMessage `json:"params"`
}

// RPCError provides stable machine-readable error codes separated from transport errors.
type RPCError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// RPCResponse is always returned with HTTP 200 for authenticated requests.
type RPCResponse struct {
	RequestID string    `json:"requestId"`
	OK        bool      `json:"ok"`
	Data      any       `json:"data,omitempty"`
	Error     *RPCError `json:"error,omitempty"`
}

// MuxFrame is the JSON wire envelope for /api/v1/mux WebSocket traffic.
type MuxFrame struct {
	Type          string          `json:"type"` // "auth"|"ping"|"pong"|"sub"|"unsub"|"snapshot"|"event"|"alert"|"error"
	Token         string          `json:"token,omitempty"`
	Channel       string          `json:"channel,omitempty"`
	Generation    string          `json:"generation,omitempty"`
	Seq           int64           `json:"seq,omitempty"`
	Event         string          `json:"event,omitempty"`
	ClientTs      int64           `json:"clientTs,omitempty"`
	ServerTs      int64           `json:"serverTs,omitempty"`
	DesktopOnline *bool           `json:"desktopOnline,omitempty"`
	Data          any             `json:"data,omitempty"`
	Alert         *notifier.Alert `json:"alert,omitempty"`
	Error         *RPCError       `json:"error,omitempty"`
}

type wsClient struct {
	conn   *websocket.Conn
	send   chan MuxFrame
	authed bool
	mu     sync.RWMutex
	subs   map[string]bool
	seq    atomic.Int64
}

// Server wires all bridge components behind HTTP RPC, sandboxed file APIs, and WS Mux.
type Server struct {
	cfg      *config.Config
	store    *statestore.Store
	reader   *agyreader.Reader
	watcher  *brainwatcher.Watcher
	quota    *quotamonitor.Monitor
	tps      *tpsmonitor.Monitor
	runner   *cmdrunner.Runner
	notifier *notifier.Manager
	tunnel   TunnelProvider

	generation       string
	upgrader         websocket.Upgrader
	wsAuthTimeoutDur time.Duration

	tokenMu sync.RWMutex

	clientsMu sync.RWMutex
	clients   map[*wsClient]struct{}

	idemMu    sync.Mutex
	idemCache map[string]RPCResponse
	idemOrder []string

	runningMu    sync.Mutex
	runningSince map[string]int64

	quotaSigMu   sync.Mutex
	lastQuotaSig string

	tpsSigMu   sync.Mutex
	lastTPSSig string

	pendingMu      sync.RWMutex
	pendingByConv  map[string][]cmdrunner.PendingInteraction
	pendingAlerted map[string]struct{}
	pendingSyncAt  time.Time
}

// New constructs the HTTP/WebSocket bridge server.
func New(
	cfg *config.Config,
	store *statestore.Store,
	reader *agyreader.Reader,
	watcher *brainwatcher.Watcher,
	quota *quotamonitor.Monitor,
	runner *cmdrunner.Runner,
	notif *notifier.Manager,
) *Server {
	return &Server{
		cfg:          cfg,
		store:        store,
		reader:       reader,
		watcher:      watcher,
		quota:        quota,
		runner:       runner,
		notifier:     notif,
		generation:       fmt.Sprintf("gen_%d", time.Now().UnixNano()),
		wsAuthTimeoutDur: 5 * time.Second,
		upgrader: websocket.Upgrader{
			CheckOrigin:       func(*http.Request) bool { return true },
			EnableCompression: true,
		},
		clients:        make(map[*wsClient]struct{}),
		idemCache:      make(map[string]RPCResponse),
		runningSince:   make(map[string]int64),
		pendingByConv:  make(map[string][]cmdrunner.PendingInteraction),
		pendingAlerted: make(map[string]struct{}),
	}
}

// Handler returns the configured http.Handler with all v1 endpoints mounted.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/health", s.handleHealth)
	mux.HandleFunc("/api/v1/rpc", s.withAuth(s.handleRPC))
	mux.HandleFunc("/api/v1/files/content", s.withAuth(s.handleFileContent))
	mux.HandleFunc("/api/v1/files/raw", s.withAuth(s.handleFileRaw))
	mux.HandleFunc("/api/v1/mux", s.handleMuxWS)
	mux.HandleFunc("/internal/hook", s.withAuth(s.handleInternalHook))
	return mux
}

// ConnectedClientCount returns the number of authenticated mobile WebSocket clients.
func (s *Server) ConnectedClientCount() int {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	count := 0
	for c := range s.clients {
		if c.isAuthed() {
			count++
		}
	}
	return count
}

// TriggerCustomAlert publishes an immediate alert (from Antigravity hooks, MCP tools, or Sidecar test button).
func (s *Server) TriggerCustomAlert(al notifier.Alert) {
	if al.AlertID == "" {
		al.AlertID = fmt.Sprintf("alt_%d", time.Now().UnixNano())
	}
	if al.Kind == "" {
		al.Kind = "NEED_CONFIRM"
	}
	if al.CreatedAt == 0 {
		al.CreatedAt = time.Now().Unix()
	}
	s.emitAlert(al)
}

// RotateBootstrapToken generates a fresh pairing token, persists it to configPath,
// updates paired_devices, and disconnects all active WebSocket clients immediately.
func (s *Server) RotateBootstrapToken(configPath string) (string, error) {
	tok, err := config.GenerateToken()
	if err != nil {
		return "", err
	}
	s.tokenMu.Lock()
	s.cfg.BootstrapToken = tok
	s.tokenMu.Unlock()
	_ = s.store.UpsertDevice("bootstrap", "Default Paired Device", config.HashToken(tok))
	if configPath != "" {
		if err := config.Save(configPath, s.cfg); err != nil {
			return "", err
		}
	}
	s.disconnectAllClients()
	return tok, nil
}

func (s *Server) disconnectAllClients() {
	s.clientsMu.RLock()
	conns := make([]*websocket.Conn, 0, len(s.clients))
	for c := range s.clients {
		conns = append(conns, c.conn)
	}
	s.clientsMu.RUnlock()
	for _, conn := range conns {
		_ = conn.Close()
	}
}

func (s *Server) currentBootstrapToken() string {
	s.tokenMu.RLock()
	defer s.tokenMu.RUnlock()
	return s.cfg.BootstrapToken
}

// SetTunnel attaches an optional remote tunnel provider (embedded Tailscale Funnel).
func (s *Server) SetTunnel(tp TunnelProvider) {
	s.tunnel = tp
}

// SetTPSMonitor attaches the output-speed (TPS) telemetry collector.
func (s *Server) SetTPSMonitor(m *tpsmonitor.Monitor) {
	s.tps = m
}

// EnableTunnel starts the embedded 5G remote tunnel.
func (s *Server) EnableTunnel() error {
	if s.tunnel == nil {
		return errors.New("tunnel provider not configured")
	}
	return s.tunnel.Enable()
}

// DisableTunnel stops the embedded 5G remote tunnel.
func (s *Server) DisableTunnel() error {
	if s.tunnel == nil {
		return nil
	}
	return s.tunnel.Disable()
}

// LogoutTunnel logs out and clears embedded Tailscale credentials.
func (s *Server) LogoutTunnel() error {
	if s.tunnel == nil {
		return nil
	}
	return s.tunnel.Logout()
}

// StatusSummary builds a live telemetry snapshot for the Antigravity Sidecar UI and MCP tools.
func (s *Server) StatusSummary(ctx context.Context) map[string]any {
	return s.StatusSummaryWithRefresh(ctx, false)
}

// StatusSummaryWithRefresh builds a telemetry snapshot, optionally bypassing provider caches.
func (s *Server) StatusSummaryWithRefresh(ctx context.Context, forceQuota bool) map[string]any {
	var snap *quotamonitor.QuotaSnapshot
	var err error
	if forceQuota {
		snap, err = s.quota.RefreshSnapshot(ctx)
	} else {
		snap, err = s.quota.Snapshot(ctx)
	}
	if err == nil && snap != nil {
		s.broadcastQuotaIfChanged(snap)
	}
	var extraEndpoints []string
	var tunnelStatus tsfunnel.Status
	if s.tunnel != nil {
		extraEndpoints = s.tunnel.Endpoints()
		tunnelStatus = s.tunnel.Status()
	} else {
		tunnelStatus = tsfunnel.Status{
			Enabled:  false,
			State:    tsfunnel.StateDisabled,
			Hostname: tsfunnel.SanitizeHostname(s.cfg.HostName),
		}
	}
	payload := s.cfg.BuildPairingPayloadWithExtra(s.currentBootstrapToken(), extraEndpoints)
	tpsSnap := s.tpsSnapshot(ctx, forceQuota)
	if tpsSnap != nil {
		s.broadcastTPSIfChanged(tpsSnap)
	}
	return map[string]any{
		"hostName":         s.cfg.HostName,
		"listenAddr":       s.cfg.ListenAddr,
		"desktopOnline":    s.runner.IsDesktopOnline(),
		"connectedClients": s.ConnectedClientCount(),
		"endpoints":        payload.Endpoints,
		"pairing":          payload,
		"tunnel":           tunnelStatus,
		"quota":            snap,
		"tps":              tpsSnap,
		"recentAlerts":     s.notifier.Recent(10),
	}
}

func (s *Server) handleInternalHook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, errResp("METHOD_NOT_ALLOWED", "POST required"))
		return
	}
	var payload struct {
		Event          string   `json:"event"` // "stop" | "ask_question" | "notify"
		ConversationID string   `json:"conversationId"`
		Title          string   `json:"title"`
		Workspace      string   `json:"workspace"`
		Body           string   `json:"body"`
		Kind           string   `json:"kind"`
		QuickReplies   []string `json:"quickReplies"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 512*1024)).Decode(&payload); err != nil {
		writeJSON(w, http.StatusOK, errResp("INVALID_ARGS", "invalid hook payload"))
		return
	}

	title := payload.Title
	workspace := payload.Workspace
	if payload.ConversationID != "" && (title == "" || workspace == "") {
		if card, err := s.buildSessionCard(payload.ConversationID); err == nil {
			if title == "" {
				title = card.Title
			}
			if workspace == "" {
				workspace = card.Workspace.Label
			}
			if payload.Body == "" && card.Preview != "" {
				payload.Body = card.Preview
			}
		}
	}
	if title == "" {
		title = "AGY Go"
	}
	kind := payload.Kind
	if kind == "" {
		if payload.Event == "ask_question" {
			kind = "NEED_CONFIRM"
		} else {
			kind = "TASK_COMPLETED"
		}
	}
	body := payload.Body
	if body == "" {
		if kind == "NEED_CONFIRM" {
			body = "Agent 正在等待你的决策确认"
		} else {
			body = "本轮任务已执行完成，点击查看最新回复与产物"
		}
	}

	s.TriggerCustomAlert(notifier.Alert{
		Kind:           kind,
		ConversationID: payload.ConversationID,
		Title:          title,
		Workspace:      workspace,
		Body:           body,
		QuickReplies:   payload.QuickReplies,
	})
	writeJSON(w, http.StatusOK, okResp(map[string]any{"notified": true, "clients": s.ConnectedClientCount()}))
}

// OnStepsAppended bridges brainwatcher updates onto active WS channels and alert triggers.
func (s *Server) OnStepsAppended(convID string, steps []brainwatcher.TranscriptStep, stats brainwatcher.ConversationStats) {
	hasPlanner := false
	for _, st := range steps {
		if st.Type == "PLANNER_RESPONSE" {
			hasPlanner = true
			break
		}
	}
	visible := brainwatcher.CompactStepsForClient(steps)
	if hasPlanner && s.tps != nil {
		s.enrichStepsWithSpeed(context.Background(), convID, visible, true)
	}
	card, cardErr := s.buildSessionCard(convID)
	if len(visible) > 0 {
		payload := map[string]any{
			"conversationId": convID,
			"steps":          visible,
		}
		if cardErr == nil {
			payload["session"] = card
		}
		s.broadcast("session:"+convID, "step.upsert", payload)
	}
	if cardErr == nil {
		s.broadcast("$global", "session.summary", card)
		if stats.NeedsConfirm {
			al := notifier.Alert{
				AlertID:        fmt.Sprintf("alt_%s_%d", convID, stats.LatestStepIndex),
				Kind:           "NEED_CONFIRM",
				ConversationID: convID,
				Title:          card.Title,
				Workspace:      card.Workspace.Label,
				Body:           stats.ConfirmSnippet,
				QuickReplies:   stats.QuickReplies,
				CreatedAt:      time.Now().Unix(),
			}
			s.emitAlert(al)
		}
	}
	if snap, err := s.quota.RefreshSnapshot(context.Background()); err == nil {
		s.broadcastQuotaIfChanged(snap)
	}
	if hasPlanner {
		if tpsSnap := s.tpsSnapshot(context.Background(), false); tpsSnap != nil {
			s.broadcastTPSIfChanged(tpsSnap)
		}
	}
}

// OnArtifactChange notifies clients when a conversation's brain artifacts change.
func (s *Server) OnArtifactChange(convID string) {
	artifacts, _ := filesandbox.ListArtifacts(filepath.Join(s.cfg.AntigravityDir, "brain", convID))
	s.broadcast("session:"+convID, "artifact.changed", map[string]any{
		"conversationId": convID,
		"artifacts":      artifacts,
	})
	if card, err := s.buildSessionCard(convID); err == nil {
		s.broadcast("$global", "session.summary", card)
	}
}

// StartStatePoller periodically checks pending permission approvals, running->idle transitions, and live quota changes.
func (s *Server) StartStatePoller(ctx context.Context) {
	ticker := time.NewTicker(2 * time.Second)
	go func() {
		defer ticker.Stop()
		ticks := 0
		s.syncPendingInteractions(ctx, true)
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				s.syncPendingInteractions(ctx, true)
				ticks++
				if ticks%2 == 0 {
					s.checkCompletionTransitions()
				}
				if ticks%8 == 0 && s.ConnectedClientCount() > 0 {
					if snap, err := s.quota.RefreshSnapshot(ctx); err == nil && snap != nil {
						s.broadcastQuotaIfChanged(snap)
					}
					if tpsSnap := s.tpsSnapshot(ctx, true); tpsSnap != nil {
						s.broadcastTPSIfChanged(tpsSnap)
					}
				}
			}
		}
	}()
}

func pendingInteractionsSignature(list []cmdrunner.PendingInteraction) string {
	if len(list) == 0 {
		return ""
	}
	var b strings.Builder
	for _, item := range list {
		fmt.Fprintf(&b, "|%s:%d:%s", item.TrajectoryID, item.StepIndex, item.Kind)
		if item.Permission != nil {
			fmt.Fprintf(&b, ":%s:%s", item.Permission.Action, item.Permission.Target)
		}
	}
	return b.String()
}

func (s *Server) pendingForConversation(convID string) []cmdrunner.PendingInteraction {
	s.pendingMu.RLock()
	defer s.pendingMu.RUnlock()
	src := s.pendingByConv[convID]
	if len(src) == 0 {
		return []cmdrunner.PendingInteraction{}
	}
	out := make([]cmdrunner.PendingInteraction, len(src))
	copy(out, src)
	return out
}

func (s *Server) refreshPendingIfStale(ctx context.Context, maxAge time.Duration) {
	s.pendingMu.RLock()
	fresh := !s.pendingSyncAt.IsZero() && time.Since(s.pendingSyncAt) < maxAge
	s.pendingMu.RUnlock()
	if fresh {
		return
	}
	s.syncPendingInteractions(ctx, false)
}

func (s *Server) syncPendingInteractions(ctx context.Context, emitAlerts bool) {
	if s.runner == nil {
		return
	}
	live, err := s.runner.ListPendingInteractions(ctx)
	if err != nil {
		return
	}
	if live == nil {
		live = make(map[string][]cmdrunner.PendingInteraction)
	}

	s.pendingMu.Lock()
	prev := s.pendingByConv
	if prev == nil {
		prev = make(map[string][]cmdrunner.PendingInteraction)
	}
	if s.pendingAlerted == nil {
		s.pendingAlerted = make(map[string]struct{})
	}

	changedConvs := make(map[string][]cmdrunner.PendingInteraction)
	for convID, newList := range live {
		if pendingInteractionsSignature(prev[convID]) != pendingInteractionsSignature(newList) {
			cp := make([]cmdrunner.PendingInteraction, len(newList))
			copy(cp, newList)
			changedConvs[convID] = cp
		}
	}
	for convID, oldList := range prev {
		if len(oldList) > 0 && len(live[convID]) == 0 {
			changedConvs[convID] = []cmdrunner.PendingInteraction{}
		}
	}

	// Track newly discovered waiting interactions for push alert deduplication.
	activeKeys := make(map[string]struct{})
	var newAlerts []cmdrunner.PendingInteraction
	for convID, list := range live {
		for _, item := range list {
			key := fmt.Sprintf("%s:%d:%s", convID, item.StepIndex, item.Kind)
			activeKeys[key] = struct{}{}
			if _, seen := s.pendingAlerted[key]; !seen {
				s.pendingAlerted[key] = struct{}{}
				if emitAlerts {
					newAlerts = append(newAlerts, item)
				}
			}
		}
	}
	// Prune resolved keys so future waiting steps at the same index can alert again if needed.
	for key := range s.pendingAlerted {
		if _, alive := activeKeys[key]; !alive {
			delete(s.pendingAlerted, key)
		}
	}

	s.pendingByConv = live
	s.pendingSyncAt = time.Now()
	s.pendingMu.Unlock()

	for convID, list := range changedConvs {
		payload := map[string]any{
			"conversationId":      convID,
			"pendingInteractions": list,
		}
		card, cardErr := s.buildSessionCard(convID)
		if cardErr == nil {
			payload["session"] = card
		}
		s.broadcast("session:"+convID, "interaction.updated", payload)
		if cardErr == nil {
			s.broadcast("$global", "session.summary", card)
		}
	}

	for _, item := range newAlerts {
		s.emitPendingInteractionAlert(item)
	}
}

func (s *Server) emitPendingInteractionAlert(item cmdrunner.PendingInteraction) {
	title := "等待授权确认"
	workspace := ""
	if card, err := s.buildSessionCard(item.ConversationID); err == nil {
		if card.Title != "" {
			title = card.Title
		}
		workspace = card.Workspace.Label
	}
	body := "Agent 正在等待你的授权确认，点击进入手机端审批"
	if item.Kind == "permission" && item.Permission != nil {
		desc := item.Permission.ActionDescription
		if desc == "" {
			desc = item.Permission.Action
		}
		if item.Permission.Target != "" {
			body = fmt.Sprintf("请求授权：%s\n%s", desc, item.Permission.Target)
		} else if desc != "" {
			body = fmt.Sprintf("请求授权：%s", desc)
		}
	} else if item.Kind == "ask_question" && item.AskQuestion != nil && len(item.AskQuestion.Questions) > 0 {
		body = item.AskQuestion.Questions[0].Question
	}
	s.emitAlert(notifier.Alert{
		AlertID:        fmt.Sprintf("perm_%s_%d_%s", item.ConversationID, item.StepIndex, item.Kind),
		Kind:           "NEED_CONFIRM",
		ConversationID: item.ConversationID,
		Title:          title,
		Workspace:      workspace,
		Body:           body,
		CreatedAt:      time.Now().Unix(),
	})
}

func quotaSignature(snap *quotamonitor.QuotaSnapshot) string {
	if snap == nil {
		return ""
	}
	var b strings.Builder
	b.WriteString(snap.SubscriptionTier)
	for _, p := range snap.Pools {
		var r5, r7 int64
		if p.Reset5hAt != nil {
			r5 = *p.Reset5hAt
		}
		if p.Reset7dAt != nil {
			r7 = *p.Reset7dAt
		}
		fmt.Fprintf(&b, "|%s:%d:%d:%d:%d:%s", p.PoolID, p.Remaining5hPct, r5, p.Remaining7dPct, r7, p.Source)
	}
	return b.String()
}

func (s *Server) broadcastQuotaIfChanged(snap *quotamonitor.QuotaSnapshot) {
	if snap == nil {
		return
	}
	sig := quotaSignature(snap)
	s.quotaSigMu.Lock()
	changed := sig != s.lastQuotaSig
	if changed {
		s.lastQuotaSig = sig
	}
	s.quotaSigMu.Unlock()
	if changed {
		s.broadcast("$global", "quota.updated", snap)
	}
}

func (s *Server) tpsSnapshot(ctx context.Context, syncRecent bool) *tpsmonitor.TPSSnapshot {
	if s.tps == nil {
		return &tpsmonitor.TPSSnapshot{
			UpdatedAt:     time.Now().Unix(),
			WindowSeconds: tpsmonitor.Window5hSeconds,
			Models:        []tpsmonitor.ModelTPSStats{},
		}
	}
	if syncRecent {
		if raws, err := s.reader.ListRootSummaries(20); err == nil && len(raws) > 0 {
			refs := make([]tpsmonitor.ConversationRef, 0, len(raws))
			for _, r := range raws {
				refs = append(refs, tpsmonitor.ConversationRef{
					ConversationID:   r.ConversationID,
					LastModifiedUnix: r.LastModifiedUnix,
				})
			}
			s.tps.SyncRecent(ctx, refs)
		}
	}
	snap, err := s.tps.Snapshot(ctx)
	if err != nil {
		return &tpsmonitor.TPSSnapshot{
			UpdatedAt:     time.Now().Unix(),
			WindowSeconds: tpsmonitor.Window5hSeconds,
			Models:        []tpsmonitor.ModelTPSStats{},
		}
	}
	return snap
}

func (s *Server) enrichStepsWithSpeed(ctx context.Context, convID string, steps []brainwatcher.TranscriptStep, syncFirst bool) {
	if s.tps == nil || len(steps) == 0 {
		return
	}
	if syncFirst {
		var fallbackUnix int64
		if raw, err := s.reader.GetSummary(convID); err == nil && raw != nil {
			fallbackUnix = raw.LastModifiedUnix
		}
		_, _ = s.tps.SyncConversationWithFallback(ctx, convID, fallbackUnix)
	}
	speeds := s.tps.StepSpeedsForConversation(convID)
	if len(speeds) == 0 {
		return
	}
	for i := range steps {
		if sp, ok := speeds[steps[i].StepIndex]; ok {
			if steps[i].OutputTokens == 0 && sp.OutputTokens > 0 {
				steps[i].OutputTokens = sp.OutputTokens
			}
			steps[i].TTFTMs = sp.TTFTMs
			steps[i].StreamingMs = sp.StreamingMs
			steps[i].StreamTPS = sp.StreamTPS
			steps[i].E2ETPS = sp.E2ETPS
		}
	}
}

func tpsSignature(snap *tpsmonitor.TPSSnapshot) string {
	if snap == nil {
		return ""
	}
	latestKey := ""
	if snap.Latest != nil {
		latestKey = fmt.Sprintf("%s:%d:%.1f:%.1f", snap.Latest.ConversationID, snap.Latest.StepIndex, snap.Latest.StreamTPS, snap.Latest.E2ETPS)
	}
	return fmt.Sprintf("%d:%d:%d:%.1f:%.1f:%d|%s",
		snap.SampleCount, snap.StreamSamples, snap.OutputTokens, snap.StreamTPS, snap.E2ETPS, snap.AvgTTFTMs, latestKey)
}

func (s *Server) broadcastTPSIfChanged(snap *tpsmonitor.TPSSnapshot) {
	if snap == nil {
		return
	}
	sig := tpsSignature(snap)
	s.tpsSigMu.Lock()
	changed := sig != s.lastTPSSig
	if changed {
		s.lastTPSSig = sig
	}
	s.tpsSigMu.Unlock()
	if changed {
		s.broadcast("$global", "tps.updated", snap)
	}
}

func (s *Server) checkCompletionTransitions() {
	raws, err := s.reader.ListRootSummaries(50)
	if err != nil {
		return
	}
	now := time.Now().Unix()

	s.runningMu.Lock()
	defer s.runningMu.Unlock()

	for _, r := range raws {
		if r.Running {
			if _, ok := s.runningSince[r.ConversationID]; !ok {
				s.runningSince[r.ConversationID] = now
			}
		} else if startedAt, wasRunning := s.runningSince[r.ConversationID]; wasRunning {
			delete(s.runningSince, r.ConversationID)
			if now-startedAt >= 15 {
				preview := r.Preview
				if st, ok := s.watcher.GetStats(r.ConversationID); ok && st.LatestPreview != "" {
					preview = st.LatestPreview
				}
				if preview == "" {
					preview = "任务已执行完成，点击查看最新回复与产物"
				}
				s.emitAlert(notifier.Alert{
					AlertID:        fmt.Sprintf("done_%s_%d", r.ConversationID, r.StepCount),
					Kind:           "TASK_COMPLETED",
					ConversationID: r.ConversationID,
					Title:          r.Title,
					Workspace:      r.Workspace.Label,
					Body:           preview,
					CreatedAt:      now,
				})
			}
		}
	}
}

func (s *Server) emitAlert(al notifier.Alert) {
	s.notifier.Publish(al)
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	for c := range s.clients {
		if c.isSubscribed("$global") {
			c.trySend(MuxFrame{
				Type:       "alert",
				Channel:    "$global",
				Generation: s.generation,
				Seq:        c.seq.Add(1),
				Alert:      &al,
			})
		}
	}
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"version":       ProtocolVersion,
		"hostName":      s.cfg.HostName,
		"desktopOnline": s.runner.IsDesktopOnline(),
		"serverTs":      time.Now().UnixMilli(),
	})
}

func (s *Server) withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := extractBearer(r.Header.Get("Authorization"))
		if !s.validateToken(token) {
			writeJSON(w, http.StatusUnauthorized, RPCResponse{
				OK:    false,
				Error: &RPCError{Code: "UNAUTHORIZED", Message: "invalid or missing bearer token"},
			})
			return
		}
		next(w, r)
	}
}

func (s *Server) validateToken(token string) bool {
	if token == "" {
		return false
	}
	bootstrap := s.currentBootstrapToken()
	if bootstrap != "" && subtle.ConstantTimeCompare([]byte(token), []byte(bootstrap)) == 1 {
		return true
	}
	ok, err := s.store.ValidateTokenHash(config.HashToken(token))
	return err == nil && ok
}

func isValidConversationID(convID string) bool {
	convID = strings.TrimSpace(convID)
	if convID == "" || convID == "." || convID == ".." {
		return false
	}
	if strings.Contains(convID, "..") || strings.ContainsAny(convID, `/\`) {
		return false
	}
	for _, r := range convID {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

func (s *Server) handleRPC(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, RPCResponse{
			OK:    false,
			Error: &RPCError{Code: "METHOD_NOT_ALLOWED", Message: "POST required"},
		})
		return
	}

	var req RPCRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2*1024*1024)).Decode(&req); err != nil {
		writeJSON(w, http.StatusOK, RPCResponse{
			OK:    false,
			Error: &RPCError{Code: "INVALID_ARGS", Message: "malformed json request"},
		})
		return
	}

	// Idempotent deduplication for mutating commands.
	if req.RequestID != "" && isIdempotentMethod(req.Method) {
		if cached, ok := s.getIdempotent(req.RequestID); ok {
			writeJSON(w, http.StatusOK, cached)
			return
		}
	}

	resp := s.dispatchRPC(r.Context(), req)
	resp.RequestID = req.RequestID

	if req.RequestID != "" && isIdempotentMethod(req.Method) && resp.OK {
		s.saveIdempotent(req.RequestID, resp)
	}
	writeJSONForRequest(w, r, http.StatusOK, resp)
}

func (s *Server) dispatchRPC(ctx context.Context, req RPCRequest) RPCResponse {
	switch req.Method {
	case "host.info":
		ws, _ := s.reader.ListWorkspaces()
		tier := s.cfg.SubscriptionTier
		models := []quotamonitor.ModelOption{}
		if snap, err := s.quota.Snapshot(ctx); err == nil && snap != nil {
			if snap.SubscriptionTier != "" {
				tier = snap.SubscriptionTier
			}
			if len(snap.Models) > 0 {
				models = snap.Models
			}
		}
		return okResp(map[string]any{
			"hostName":         s.cfg.HostName,
			"protocolVersion":  ProtocolVersion,
			"desktopOnline":    s.runner.IsDesktopOnline(),
			"subscriptionTier": tier,
			"workspaces":       ws,
			"models":           models,
		})

	case "quota.get":
		snap, err := s.quota.RefreshSnapshot(ctx)
		if err != nil {
			return errResp("INTERNAL_ERROR", err.Error())
		}
		s.broadcastQuotaIfChanged(snap)
		return okResp(snap)

	case "tps.get":
		var p struct {
			Refresh *bool `json:"refresh"`
		}
		_ = json.Unmarshal(req.Params, &p)
		doSync := true
		if p.Refresh != nil {
			doSync = *p.Refresh
		}
		tpsSnap := s.tpsSnapshot(ctx, doSync)
		s.broadcastTPSIfChanged(tpsSnap)
		return okResp(tpsSnap)

	case "quota.calibrate":
		var in quotamonitor.CalibrationInput
		if err := json.Unmarshal(req.Params, &in); err != nil || in.PoolID == "" {
			return errResp("INVALID_ARGS", "poolId is required")
		}
		snap, err := s.quota.Calibrate(ctx, in)
		if err != nil {
			return errResp("INTERNAL_ERROR", err.Error())
		}
		s.quotaSigMu.Lock()
		s.lastQuotaSig = quotaSignature(snap)
		s.quotaSigMu.Unlock()
		s.broadcast("$global", "quota.updated", snap)
		return okResp(snap)

	case "sessions.list":
		var p struct {
			Mode  string `json:"mode"`
			Limit int    `json:"limit"`
		}
		_ = json.Unmarshal(req.Params, &p)
		if p.Mode == "" {
			p.Mode = "desktop"
		}
		if p.Limit <= 0 {
			p.Limit = 100
		}
		s.refreshPendingIfStale(ctx, 2*time.Second)
		data, err := s.buildSessionList(p.Mode, p.Limit)
		if err != nil {
			return errResp("INTERNAL_ERROR", err.Error())
		}
		return okResp(data)

	case "sessions.search":
		var p struct {
			Query string `json:"query"`
			Limit int    `json:"limit"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return errResp("INVALID_ARGS", "invalid search params")
		}
		hits, err := s.reader.Search(p.Query, p.Limit)
		if err != nil {
			return errResp("INTERNAL_ERROR", err.Error())
		}
		return okResp(map[string]any{"hits": hits})

	case "sessions.get":
		var p struct {
			ConversationID string `json:"conversationId"`
			BeforeStep     int    `json:"beforeStep"`
			Limit          int    `json:"limit"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil || !isValidConversationID(p.ConversationID) {
			return errResp("INVALID_ARGS", "valid conversationId is required")
		}
		s.refreshPendingIfStale(ctx, 1500*time.Millisecond)
		card, err := s.buildSessionCard(p.ConversationID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return errResp("SESSION_NOT_FOUND", "conversation not found")
			}
			return errResp("INTERNAL_ERROR", err.Error())
		}
		steps, hasMore, err := s.watcher.ReadStepsForClient(p.ConversationID, p.BeforeStep, p.Limit)
		if err != nil {
			return errResp("INTERNAL_ERROR", err.Error())
		}
		s.enrichStepsWithSpeed(ctx, p.ConversationID, steps, true)
		artifacts, _ := filesandbox.ListArtifacts(filepath.Join(s.cfg.AntigravityDir, "brain", p.ConversationID))
		return okResp(map[string]any{
			"session":             card,
			"steps":               steps,
			"hasMore":             hasMore,
			"artifacts":           artifacts,
			"pendingInteractions": s.pendingForConversation(p.ConversationID),
		})

	case "sessions.create":
		var opts cmdrunner.NewConversationOptions
		if err := json.Unmarshal(req.Params, &opts); err != nil || strings.TrimSpace(opts.Prompt) == "" {
			return errResp("INVALID_ARGS", "prompt is required")
		}
		res, err := s.runner.NewConversation(ctx, opts)
		if err != nil {
			if errors.Is(err, cmdrunner.ErrDesktopOffline) {
				return errResp("DESKTOP_OFFLINE", "Mac 端 Antigravity 桌面进程当前未运行，无法新建会话")
			}
			return errResp("COMMAND_FAILED", err.Error())
		}
		return okResp(res)

	case "sessions.sendMessage":
		var p struct {
			ConversationID string `json:"conversationId"`
			Content        string `json:"content"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil || !isValidConversationID(p.ConversationID) || strings.TrimSpace(p.Content) == "" {
			return errResp("INVALID_ARGS", "valid conversationId and content are required")
		}
		res, err := s.runner.SendMessage(ctx, p.ConversationID, p.Content)
		if err != nil {
			if errors.Is(err, cmdrunner.ErrDesktopOffline) {
				return errResp("DESKTOP_OFFLINE", "Mac 端 Antigravity 桌面进程当前未运行，无法发送消息（历史对话与产物仍可正常查阅）")
			}
			return errResp("COMMAND_FAILED", err.Error())
		}
		return okResp(res)

	case "sessions.respondInteraction":
		var dec cmdrunner.InteractionDecision
		if err := json.Unmarshal(req.Params, &dec); err != nil || !isValidConversationID(dec.ConversationID) || dec.StepIndex < 0 {
			return errResp("INVALID_ARGS", "valid conversationId and stepIndex are required")
		}
		if dec.Kind == "" {
			dec.Kind = "permission"
		}
		if dec.Kind != "permission" && dec.Kind != "ask_question" {
			return errResp("INVALID_ARGS", "kind must be permission or ask_question")
		}
		if err := s.runner.RespondInteraction(ctx, dec); err != nil {
			if errors.Is(err, cmdrunner.ErrDesktopOffline) {
				return errResp("DESKTOP_OFFLINE", "Mac 端 Antigravity 桌面进程当前未运行，无法提交授权决策")
			}
			return errResp("COMMAND_FAILED", err.Error())
		}
		s.syncPendingInteractions(ctx, false)
		respData := map[string]any{
			"handled":             true,
			"conversationId":      dec.ConversationID,
			"stepIndex":           dec.StepIndex,
			"pendingInteractions": s.pendingForConversation(dec.ConversationID),
		}
		if card, err := s.buildSessionCard(dec.ConversationID); err == nil {
			respData["session"] = card
		}
		return okResp(respData)

	case "sessions.pin":
		var p struct {
			ConversationID string `json:"conversationId"`
			Pinned         bool   `json:"pinned"`
			Order          int    `json:"order"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil || !isValidConversationID(p.ConversationID) {
			return errResp("INVALID_ARGS", "valid conversationId is required")
		}
		if err := s.store.SetPinned(p.ConversationID, p.Pinned, p.Order); err != nil {
			return errResp("INTERNAL_ERROR", err.Error())
		}
		if card, err := s.buildSessionCard(p.ConversationID); err == nil {
			s.broadcast("$global", "session.summary", card)
		}
		return okResp(map[string]any{"pinned": p.Pinned})

	case "sessions.markRead":
		var p struct {
			ConversationID string `json:"conversationId"`
			StepIndex      int    `json:"stepIndex"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil || !isValidConversationID(p.ConversationID) {
			return errResp("INVALID_ARGS", "valid conversationId is required")
		}
		if err := s.store.MarkRead(p.ConversationID, p.StepIndex); err != nil {
			return errResp("INTERNAL_ERROR", err.Error())
		}
		if card, err := s.buildSessionCard(p.ConversationID); err == nil {
			s.broadcast("$global", "session.summary", card)
		}
		return okResp(map[string]any{"ok": true})

	case "artifacts.list":
		var p struct {
			ConversationID string `json:"conversationId"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil || !isValidConversationID(p.ConversationID) {
			return errResp("INVALID_ARGS", "valid conversationId is required")
		}
		items, err := filesandbox.ListArtifacts(filepath.Join(s.cfg.AntigravityDir, "brain", p.ConversationID))
		if err != nil {
			return errResp("INTERNAL_ERROR", err.Error())
		}
		return okResp(map[string]any{"artifacts": items})

	case "alerts.list":
		return okResp(map[string]any{"alerts": s.notifier.Recent(50)})

	default:
		return errResp("UNKNOWN_METHOD", fmt.Sprintf("unsupported rpc method: %s", req.Method))
	}
}

func (s *Server) handleFileContent(w http.ResponseWriter, r *http.Request) {
	convID := strings.TrimSpace(r.URL.Query().Get("convId"))
	targetPath := strings.TrimSpace(r.URL.Query().Get("path"))
	offset, _ := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	limit, _ := strconv.ParseInt(r.URL.Query().Get("limit"), 10, 64)

	roots, err := s.allowedRootsForConversation(convID)
	if err != nil {
		writeJSON(w, http.StatusOK, errResp("SESSION_NOT_FOUND", "conversation not found"))
		return
	}

	// Allow relative artifact path within brain/<convID> as convenience.
	if targetPath != "" && !filepath.IsAbs(strings.TrimPrefix(targetPath, "file://")) {
		targetPath = filepath.Join(s.cfg.AntigravityDir, "brain", convID, targetPath)
	}

	page, err := filesandbox.ReadTextPage(targetPath, roots, offset, limit)
	if err != nil {
		code := "FILE_ERROR"
		if errors.Is(err, filesandbox.ErrPathForbidden) {
			code = "PATH_FORBIDDEN"
		}
		writeJSON(w, http.StatusOK, errResp(code, err.Error()))
		return
	}
	writeJSONForRequest(w, r, http.StatusOK, okResp(page))
}

func (s *Server) handleFileRaw(w http.ResponseWriter, r *http.Request) {
	convID := strings.TrimSpace(r.URL.Query().Get("convId"))
	targetPath := strings.TrimSpace(r.URL.Query().Get("path"))

	roots, err := s.allowedRootsForConversation(convID)
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	if targetPath != "" && !filepath.IsAbs(strings.TrimPrefix(targetPath, "file://")) {
		targetPath = filepath.Join(s.cfg.AntigravityDir, "brain", convID, targetPath)
	}

	f, fi, mimeType, err := filesandbox.OpenRaw(targetPath, roots)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, filesandbox.ErrPathForbidden) {
			status = http.StatusForbidden
		} else if errors.Is(err, filesandbox.ErrFileTooLarge) {
			status = http.StatusRequestEntityTooLarge
		}
		http.Error(w, err.Error(), status)
		return
	}
	defer f.Close()

	w.Header().Set("Content-Type", mimeType)
	http.ServeContent(w, r, fi.Name(), fi.ModTime(), f)
}

func (s *Server) allowedRootsForConversation(convID string) ([]string, error) {
	if !isValidConversationID(convID) {
		return nil, filesandbox.ErrPathForbidden
	}
	roots := []string{filepath.Join(s.cfg.AntigravityDir, "brain", convID)}
	if raw, err := s.reader.GetSummary(convID); err == nil {
		roots = append(roots, raw.WorkspaceRoots...)
	}
	return roots, nil
}

func (s *Server) handleMuxWS(w http.ResponseWriter, r *http.Request) {
	headerAuthed := s.validateToken(extractBearer(r.Header.Get("Authorization")))
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}

	c := &wsClient{
		conn:   conn,
		send:   make(chan MuxFrame, 64),
		authed: headerAuthed,
		subs:   make(map[string]bool),
	}

	s.clientsMu.Lock()
	s.clients[c] = struct{}{}
	s.clientsMu.Unlock()

	defer func() {
		s.clientsMu.Lock()
		delete(s.clients, c)
		s.clientsMu.Unlock()
		close(c.send)
		_ = conn.Close()
	}()

	go func() {
		for frame := range c.send {
			_ = conn.SetWriteDeadline(time.Now().Add(20 * time.Second))
			if err := conn.WriteJSON(frame); err != nil {
				_ = conn.Close()
				return
			}
		}
	}()

	// Auto-subscribe $global when authenticated via HTTP Authorization header.
	// Unauthenticated connections must complete first-frame auth before deadline.
	if c.isAuthed() {
		s.subscribeClient(c, "$global")
	} else {
		timeout := s.wsAuthTimeoutDur
		if timeout <= 0 {
			timeout = 5 * time.Second
		}
		_ = conn.SetReadDeadline(time.Now().Add(timeout))
	}

	for {
		var in MuxFrame
		if err := conn.ReadJSON(&in); err != nil {
			return
		}
		if !c.isAuthed() {
			if in.Type == "auth" && s.validateToken(in.Token) {
				c.setAuthed(true)
				_ = conn.SetReadDeadline(time.Time{})
				s.subscribeClient(c, "$global")
				continue
			}
			c.trySend(MuxFrame{
				Type:  "error",
				Error: &RPCError{Code: "UNAUTHORIZED", Message: "authentication required"},
			})
			return
		}

		switch in.Type {
		case "ping":
			online := s.runner.IsDesktopOnline()
			c.trySend(MuxFrame{
				Type:          "pong",
				ClientTs:      in.ClientTs,
				ServerTs:      time.Now().UnixMilli(),
				DesktopOnline: &online,
			})
		case "sub":
			if in.Channel != "" {
				if strings.HasPrefix(in.Channel, "session:") {
					convID := strings.TrimPrefix(in.Channel, "session:")
					if !isValidConversationID(convID) {
						c.trySend(MuxFrame{
							Type:  "error",
							Error: &RPCError{Code: "INVALID_ARGS", Message: "invalid session channel"},
						})
						continue
					}
				}
				s.subscribeClient(c, in.Channel)
			}
		case "unsub":
			c.mu.Lock()
			delete(c.subs, in.Channel)
			c.mu.Unlock()
		}
	}
}

func (s *Server) subscribeClient(c *wsClient, channel string) {
	if channel == "$global" {
		s.refreshPendingIfStale(context.Background(), 2*time.Second)
	} else if strings.HasPrefix(channel, "session:") {
		s.refreshPendingIfStale(context.Background(), 1500*time.Millisecond)
	}

	c.mu.Lock()
	c.subs[channel] = true
	c.mu.Unlock()

	var payload any
	if channel == "$global" {
		list, _ := s.buildSessionList("desktop", 100)
		snap, _ := s.quota.Snapshot(context.Background())
		tpsSnap := s.tpsSnapshot(context.Background(), false)
		payload = map[string]any{
			"hostName":      s.cfg.HostName,
			"desktopOnline": s.runner.IsDesktopOnline(),
			"quota":         snap,
			"tps":           tpsSnap,
			"sessions":      list,
			"unreadAlerts":  len(s.notifier.Recent(20)),
		}
	} else if strings.HasPrefix(channel, "session:") {
		convID := strings.TrimPrefix(channel, "session:")
		card, _ := s.buildSessionCard(convID)
		steps, hasMore, _ := s.watcher.ReadStepsForClient(convID, 0, 80)
		s.enrichStepsWithSpeed(context.Background(), convID, steps, true)
		artifacts, _ := filesandbox.ListArtifacts(filepath.Join(s.cfg.AntigravityDir, "brain", convID))
		payload = map[string]any{
			"session":             card,
			"steps":               steps,
			"hasMore":             hasMore,
			"artifacts":           artifacts,
			"pendingInteractions": s.pendingForConversation(convID),
		}
	}

	c.trySend(MuxFrame{
		Type:       "snapshot",
		Channel:    channel,
		Generation: s.generation,
		Seq:        c.seq.Add(1),
		Data:       payload,
	})
}

func (s *Server) broadcast(channel, event string, data any) {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	for c := range s.clients {
		if c.isSubscribed(channel) {
			c.trySend(MuxFrame{
				Type:       "event",
				Channel:    channel,
				Generation: s.generation,
				Seq:        c.seq.Add(1),
				Event:      event,
				Data:       data,
			})
		}
	}
}

func (c *wsClient) isAuthed() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.authed
}

func (c *wsClient) setAuthed(v bool) {
	c.mu.Lock()
	c.authed = v
	c.mu.Unlock()
}

func (c *wsClient) isSubscribed(channel string) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.authed && c.subs[channel]
}

func (c *wsClient) trySend(f MuxFrame) {
	select {
	case c.send <- f:
	default:
	}
}

func (s *Server) buildSessionList(mode string, limit int) (map[string]any, error) {
	raws, err := s.reader.ListRootSummaries(limit)
	if err != nil {
		return nil, err
	}
	metas, _ := s.store.GetAllSessionMeta()

	cards := make([]SessionCard, 0, len(raws))
	for _, raw := range raws {
		cards = append(cards, s.assembleCard(raw, metas[raw.ConversationID]))
	}

	var pinned, regular []SessionCard
	for _, c := range cards {
		if c.Pinned {
			pinned = append(pinned, c)
		} else {
			regular = append(regular, c)
		}
	}
	sort.Slice(pinned, func(i, j int) bool {
		if pinned[i].PinnedOrder != pinned[j].PinnedOrder {
			return pinned[i].PinnedOrder < pinned[j].PinnedOrder
		}
		return pinned[i].LastModifiedUnix > pinned[j].LastModifiedUnix
	})

	result := map[string]any{
		"mode":    mode,
		"pinned":  pinned,
		"regular": regular,
	}

	if mode == "project" {
		groupMap := make(map[string]*ProjectGroup)
		for _, c := range cards {
			key := c.Workspace.Kind + ":" + c.Workspace.Label
			g, ok := groupMap[key]
			if !ok {
				g = &ProjectGroup{Workspace: c.Workspace}
				groupMap[key] = g
			}
			g.Sessions = append(g.Sessions, c)
			if c.LastModifiedUnix > g.LatestActiveUnix {
				g.LatestActiveUnix = c.LastModifiedUnix
			}
		}
		groups := make([]ProjectGroup, 0, len(groupMap))
		for _, g := range groupMap {
			groups = append(groups, *g)
		}
		sort.Slice(groups, func(i, j int) bool {
			return groups[i].LatestActiveUnix > groups[j].LatestActiveUnix
		})
		result["groups"] = groups
	}

	return result, nil
}

func (s *Server) buildSessionCard(convID string) (SessionCard, error) {
	raw, err := s.reader.GetSummary(convID)
	if err != nil {
		return SessionCard{}, err
	}
	metas, _ := s.store.GetAllSessionMeta()
	return s.assembleCard(*raw, metas[convID]), nil
}

func (s *Server) assembleCard(raw agyreader.RawSummary, meta statestore.SessionMeta) SessionCard {
	preview := raw.Preview
	model := ""
	modelDisplay := ""
	needsConfirm := false
	latestStepIdx := raw.StepCount - 1
	latestIsUser := false

	if st, ok := s.watcher.GetStats(raw.ConversationID); ok {
		if st.LatestPreview != "" {
			preview = st.LatestPreview
		}
		model = st.LatestModel
		modelDisplay = st.LatestModelDisplay
		needsConfirm = st.NeedsConfirm
		if st.LatestStepIndex > latestStepIdx {
			latestStepIdx = st.LatestStepIndex
		}
		latestIsUser = st.LatestStepType == "USER_INPUT"
	}

	pendingCount := len(s.pendingForConversation(raw.ConversationID))
	if pendingCount > 0 {
		needsConfirm = true
	}

	artifacts, _ := filesandbox.ListArtifacts(filepath.Join(s.cfg.AntigravityDir, "brain", raw.ConversationID))
	unread := latestStepIdx > meta.LastReadStepIndex && meta.LastReadStepIndex >= 0 && !latestIsUser
	if meta.LastReadStepIndex < 0 && raw.StepCount > 0 && needsConfirm {
		unread = true
	}

	return SessionCard{
		ConversationID:          raw.ConversationID,
		Title:                   raw.Title,
		Preview:                 preview,
		StepCount:               raw.StepCount,
		LastModifiedUnix:        raw.LastModifiedUnix,
		Workspace:               raw.Workspace,
		Status:                  raw.Status,
		Running:                 raw.Running,
		SubagentCount:           raw.SubagentCount,
		ArtifactCount:           len(artifacts),
		Model:                   model,
		ModelDisplay:            modelDisplay,
		Pinned:                  meta.Pinned,
		PinnedOrder:             meta.PinnedOrder,
		Unread:                  unread,
		NeedsConfirm:            needsConfirm,
		PendingInteractionCount: pendingCount,
	}
}

func isIdempotentMethod(method string) bool {
	return method == "sessions.create" || method == "sessions.sendMessage" || method == "sessions.respondInteraction"
}

func (s *Server) getIdempotent(reqID string) (RPCResponse, bool) {
	s.idemMu.Lock()
	defer s.idemMu.Unlock()
	r, ok := s.idemCache[reqID]
	return r, ok
}

func (s *Server) saveIdempotent(reqID string, resp RPCResponse) {
	s.idemMu.Lock()
	defer s.idemMu.Unlock()
	if _, exists := s.idemCache[reqID]; exists {
		return
	}
	s.idemCache[reqID] = resp
	s.idemOrder = append(s.idemOrder, reqID)
	if len(s.idemOrder) > 500 {
		evict := s.idemOrder[0]
		s.idemOrder = s.idemOrder[1:]
		delete(s.idemCache, evict)
	}
}

func extractBearer(header string) string {
	const prefix = "Bearer "
	if len(header) > len(prefix) && strings.EqualFold(header[:len(prefix)], prefix) {
		return strings.TrimSpace(header[len(prefix):])
	}
	return ""
}

func okResp(data any) RPCResponse {
	return RPCResponse{OK: true, Data: data}
}

func errResp(code, msg string) RPCResponse {
	return RPCResponse{OK: false, Error: &RPCError{Code: code, Message: msg}}
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeJSONForRequest(w http.ResponseWriter, r *http.Request, status int, payload any) {
	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(payload); err != nil {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if buf.Len() > 1024 && r != nil && strings.Contains(strings.ToLower(r.Header.Get("Accept-Encoding")), "gzip") {
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Vary", "Accept-Encoding")
		w.WriteHeader(status)
		gz := gzip.NewWriter(w)
		_, _ = gz.Write(buf.Bytes())
		_ = gz.Close()
		return
	}
	w.WriteHeader(status)
	_, _ = w.Write(buf.Bytes())
}
