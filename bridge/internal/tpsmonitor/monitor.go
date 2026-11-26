package tpsmonitor

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/antigravity-mobile/bridge/internal/procutil"
	"github.com/antigravity-mobile/bridge/internal/statestore"
)

const (
	Window5hSeconds int64 = 5 * 3600

	// MinStreamDurationMs and MinStreamOutputTokens filter single-chunk burst responses
	// where streamingDuration collapses to a few milliseconds and would otherwise produce
	// artificially inflated tok/s numbers.
	MinStreamDurationMs   int64 = 500
	MinStreamOutputTokens int64 = 30
)

// TPSTurn represents generation throughput metrics for a single completed planner turn.
type TPSTurn struct {
	ConversationID string  `json:"conversationId"`
	StepIndex      int     `json:"stepIndex"`
	CreatedAtUnix  int64   `json:"createdAtUnix"`
	PoolID         string  `json:"poolId"`
	Model          string  `json:"model"`
	ModelDisplay   string  `json:"modelDisplay"`
	OutputTokens   int64   `json:"outputTokens"`
	ThinkingTokens int64   `json:"thinkingTokens,omitempty"`
	ResponseTokens int64   `json:"responseTokens,omitempty"`
	TTFTMs         int64   `json:"ttftMs"`
	StreamingMs    int64   `json:"streamingMs"`
	StreamTPS      float64 `json:"streamTps"`
	E2ETPS         float64 `json:"e2eTps"`
}

// ModelTPSStats aggregates rolling 5h generation speed metrics for a single model variant.
type ModelTPSStats struct {
	Model          string  `json:"model"`
	ModelDisplay   string  `json:"modelDisplay"`
	PoolID         string  `json:"poolId"`
	SampleCount    int     `json:"sampleCount"`
	StreamSamples  int     `json:"streamSamples"`
	OutputTokens   int64   `json:"outputTokens"`
	StreamTPS      float64 `json:"streamTps"`
	E2ETPS         float64 `json:"e2eTps"`
	AvgTTFTMs      int64   `json:"avgTtftMs"`
	LastActiveUnix int64   `json:"lastActiveUnix"`
}

// TPSSnapshot is the unified speed telemetry contract shared by HTTP RPC, WS Mux, Sidecar UI, MCP, and CLI.
type TPSSnapshot struct {
	UpdatedAt     int64           `json:"updatedAt"`
	WindowSeconds int64           `json:"windowSeconds"`
	SampleCount   int             `json:"sampleCount"`
	StreamSamples int             `json:"streamSamples"`
	OutputTokens  int64           `json:"outputTokens"`
	StreamTPS     float64         `json:"streamTps"`
	E2ETPS        float64         `json:"e2eTps"`
	AvgTTFTMs     int64           `json:"avgTtftMs"`
	Latest        *TPSTurn        `json:"latest,omitempty"`
	Models        []ModelTPSStats `json:"models"`
}

// StepSpeed holds per-step speed telemetry injected into mobile TranscriptStep payloads.
type StepSpeed struct {
	OutputTokens int64
	TTFTMs       int64
	StreamingMs  int64
	StreamTPS    float64
	E2ETPS       float64
}

// Monitor incrementally collects generatorMetadata from local Antigravity LanguageServer
// and computes rolling 5h + latest-turn TPS/TTFT metrics backed by statestore.
type Monitor struct {
	daemonDir string
	store     *statestore.Store
	client    *http.Client
	nowFn     func() time.Time
	pidAlive  func(int) bool
	envLookup func(string) string

	syncMu sync.Mutex
}

// NewMonitor constructs a TPS monitor backed by local LanguageServer RPC and SQLite persistence.
func NewMonitor(daemonDir string, store *statestore.Store) *Monitor {
	return &Monitor{
		daemonDir: daemonDir,
		store:     store,
		client: &http.Client{
			Timeout:   4 * time.Second,
			Transport: &http.Transport{Proxy: nil}, // Always bypass system proxy for local loopback.
		},
		nowFn:     time.Now,
		pidAlive:  procutil.IsPIDAlive,
		envLookup: os.Getenv,
	}
}

type generatorMetadataResp struct {
	GeneratorMetadata []generatorMetadataItem `json:"generatorMetadata"`
}

type generatorMetadataItem struct {
	StepIndices []int  `json:"stepIndices"`
	Error       string `json:"error"`
	ChatModel   *struct {
		Model             string `json:"model"`
		ResponseModel     string `json:"responseModel"`
		ModelDisplayName  string `json:"modelDisplayName"`
		TimeToFirstToken  string `json:"timeToFirstToken"`
		StreamingDuration string `json:"streamingDuration"`
		Usage             *struct {
			OutputTokens         json.RawMessage `json:"outputTokens"`
			ThinkingOutputTokens json.RawMessage `json:"thinkingOutputTokens"`
			ResponseOutputTokens json.RawMessage `json:"responseOutputTokens"`
			APIProvider          string          `json:"apiProvider"`
		} `json:"usage"`
	} `json:"chatModel"`
}

// ConversationRef pairs a conversation ID with its known last-modified Unix timestamp
// so historical sessions without local transcript.jsonl never get mis-stamped as "now".
type ConversationRef struct {
	ConversationID   string
	LastModifiedUnix int64
}

// SyncConversation incrementally fetches new generatorMetadata entries for convID from local LS
// and persists completed turns into bridge_state.db.
func (m *Monitor) SyncConversation(ctx context.Context, convID string) (int, error) {
	return m.SyncConversationWithFallback(ctx, convID, 0)
}

// SyncConversationWithFallback syncs convID using fallbackUnix when a step's exact timestamp
// is absent from usage_ledger (falling back to now only when fallbackUnix <= 0).
func (m *Monitor) SyncConversationWithFallback(ctx context.Context, convID string, fallbackUnix int64) (int, error) {
	convID = strings.TrimSpace(convID)
	if convID == "" || m.store == nil {
		return 0, nil
	}

	addr, csrf, err := m.discoverEndpoint()
	if err != nil {
		return 0, err
	}

	m.syncMu.Lock()
	defer m.syncMu.Unlock()

	return m.syncConversationLocked(ctx, addr, csrf, convID, fallbackUnix)
}

// SyncRecent incrementally syncs up to maxConvs recent conversations.
func (m *Monitor) SyncRecent(ctx context.Context, refs []ConversationRef) int {
	if m.store == nil || len(refs) == 0 {
		return 0
	}
	addr, csrf, err := m.discoverEndpoint()
	if err != nil {
		return 0
	}

	const maxConvs = 25
	seen := make(map[string]struct{}, len(refs))
	targets := make([]ConversationRef, 0, min(len(refs), maxConvs))
	for _, ref := range refs {
		id := strings.TrimSpace(ref.ConversationID)
		if id == "" {
			continue
		}
		if _, dup := seen[id]; dup {
			continue
		}
		seen[id] = struct{}{}
		targets = append(targets, ConversationRef{
			ConversationID:   id,
			LastModifiedUnix: ref.LastModifiedUnix,
		})
		if len(targets) >= maxConvs {
			break
		}
	}

	m.syncMu.Lock()
	defer m.syncMu.Unlock()

	total := 0
	for _, ref := range targets {
		if ctx.Err() != nil {
			break
		}
		if n, err := m.syncConversationLocked(ctx, addr, csrf, ref.ConversationID, ref.LastModifiedUnix); err == nil {
			total += n
		}
	}
	return total
}

func (m *Monitor) syncConversationLocked(ctx context.Context, addr, csrf, convID string, fallbackUnix int64) (int, error) {
	offset, err := m.store.GetTPSOffset(convID)
	if err != nil {
		return 0, err
	}

	items, err := m.fetchGeneratorMetadata(ctx, addr, csrf, convID, offset)
	if err != nil {
		return 0, err
	}
	if len(items) == 0 {
		return 0, nil
	}

	stepTS, _ := m.store.LookupStepTimestamps(convID)
	nowUnix := m.nowFn().Unix()

	// Find the last terminal entry so we never advance offset past trailing in-flight generations.
	lastTerminal := -1
	for i := len(items) - 1; i >= 0; i-- {
		if isTerminalItem(items[i]) {
			lastTerminal = i
			break
		}
	}

	var batch []statestore.TPSSample
	for i, item := range items {
		if item.ChatModel == nil || item.ChatModel.Usage == nil || len(item.StepIndices) == 0 {
			continue
		}
		outTok := parseInt64Flex(item.ChatModel.Usage.OutputTokens)
		if outTok <= 0 {
			continue
		}
		thinkTok := parseInt64Flex(item.ChatModel.Usage.ThinkingOutputTokens)
		respTok := parseInt64Flex(item.ChatModel.Usage.ResponseOutputTokens)
		ttftMs := parseProtoDurationMs(item.ChatModel.TimeToFirstToken)
		streamMs := parseProtoDurationMs(item.ChatModel.StreamingDuration)
		if ttftMs <= 0 && streamMs <= 0 {
			continue
		}

		stepIdx := item.StepIndices[0]
		ts := stepTS[stepIdx]
		if ts <= 0 && fallbackUnix > 0 {
			ts = fallbackUnix
		}
		if ts <= 0 {
			ts = nowUnix
		}

		modelDisplay := strings.TrimSpace(item.ChatModel.ModelDisplayName)
		modelID := strings.TrimSpace(item.ChatModel.ResponseModel)
		if modelID == "" {
			modelID = modelDisplay
		}
		if modelID == "" {
			modelID = strings.TrimSpace(item.ChatModel.Model)
		}
		if modelDisplay == "" {
			modelDisplay = modelID
		}

		batch = append(batch, statestore.TPSSample{
			ConversationID: convID,
			StepIndex:      stepIdx,
			CreatedAtUnix:  ts,
			PoolID:         classifyPool(modelID, modelDisplay, item.ChatModel.Usage.APIProvider),
			Model:          modelID,
			ModelDisplay:   modelDisplay,
			OutputTokens:   outTok,
			ThinkingTokens: thinkTok,
			ResponseTokens: respTok,
			TTFTMs:         ttftMs,
			StreamingMs:    streamMs,
		})
		if i > lastTerminal {
			lastTerminal = i
		}
	}

	if len(batch) > 0 {
		if err := m.store.RecordTPSSamples(batch); err != nil {
			return 0, err
		}
	}
	if lastTerminal >= 0 {
		_ = m.store.SetTPSOffset(convID, offset+lastTerminal+1)
	}
	return len(batch), nil
}

func isTerminalItem(it generatorMetadataItem) bool {
	if strings.TrimSpace(it.Error) != "" {
		return true
	}
	if it.ChatModel != nil && it.ChatModel.Usage != nil {
		if parseInt64Flex(it.ChatModel.Usage.OutputTokens) > 0 {
			return true
		}
	}
	return false
}

func (m *Monitor) fetchGeneratorMetadata(ctx context.Context, addr, csrf, convID string, offset int) ([]generatorMetadataItem, error) {
	baseURL := addr
	if !strings.HasPrefix(baseURL, "http://") && !strings.HasPrefix(baseURL, "https://") {
		baseURL = "http://" + baseURL
	}
	endpoint := strings.TrimRight(baseURL, "/") + "/exa.language_server_pb.LanguageServerService/GetCascadeTrajectoryGeneratorMetadata"

	body, err := json.Marshal(map[string]any{
		"cascadeId":               convID,
		"generatorMetadataOffset": offset,
	})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connect-Protocol-Version", "1")
	if csrf != "" {
		req.Header.Set("x-codeium-csrf-token", csrf)
	}

	resp, err := m.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GetCascadeTrajectoryGeneratorMetadata HTTP %d", resp.StatusCode)
	}

	var parsed generatorMetadataResp
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return nil, err
	}
	return parsed.GeneratorMetadata, nil
}

// Snapshot computes the rolling 5h TPS snapshot plus the latest completed turn from persisted samples.
func (m *Monitor) Snapshot(_ context.Context) (*TPSSnapshot, error) {
	nowUnix := m.nowFn().Unix()
	snap := &TPSSnapshot{
		UpdatedAt:     nowUnix,
		WindowSeconds: Window5hSeconds,
		Models:        []ModelTPSStats{},
	}
	if m.store == nil {
		return snap, nil
	}

	samples, err := m.store.QueryTPSSamplesSince(nowUnix-Window5hSeconds, 2000)
	if err != nil {
		return nil, err
	}

	type modelAgg struct {
		model          string
		display        string
		poolID         string
		count          int
		streamCount    int
		outputTokens   int64
		streamTokens   int64
		streamMs       int64
		e2eMs          int64
		ttftMs         int64
		lastActiveUnix int64
	}

	byModel := make(map[string]*modelAgg)
	var totalOutput, totalStreamTokens, totalStreamMs, totalE2EMs, totalTTFTMs int64
	var totalSamples, totalStreamSamples int
	var latest *TPSTurn

	for i, sm := range samples {
		turn := sampleToTurn(sm)
		if i == 0 {
			t := turn
			latest = &t
		}

		totalSamples++
		totalOutput += sm.OutputTokens
		totalTTFTMs += sm.TTFTMs
		totalE2EMs += sm.TTFTMs + sm.StreamingMs

		validStream := isValidStreamSample(sm.OutputTokens, sm.StreamingMs)
		if validStream {
			totalStreamSamples++
			totalStreamTokens += sm.OutputTokens
			totalStreamMs += sm.StreamingMs
		}

		key := sm.ModelDisplay
		if key == "" {
			key = sm.Model
		}
		ma, ok := byModel[key]
		if !ok {
			ma = &modelAgg{
				model:   sm.Model,
				display: sm.ModelDisplay,
				poolID:  sm.PoolID,
			}
			byModel[key] = ma
		}
		ma.count++
		ma.outputTokens += sm.OutputTokens
		ma.ttftMs += sm.TTFTMs
		ma.e2eMs += sm.TTFTMs + sm.StreamingMs
		if validStream {
			ma.streamCount++
			ma.streamTokens += sm.OutputTokens
			ma.streamMs += sm.StreamingMs
		}
		if sm.CreatedAtUnix > ma.lastActiveUnix {
			ma.lastActiveUnix = sm.CreatedAtUnix
		}
	}

	// If no samples exist in the 5h window, still expose the most recent historical turn if present.
	if latest == nil {
		if hist, err := m.store.QueryLatestTPSSample(); err == nil && hist != nil {
			t := sampleToTurn(*hist)
			latest = &t
		}
	}

	snap.SampleCount = totalSamples
	snap.StreamSamples = totalStreamSamples
	snap.OutputTokens = totalOutput
	snap.StreamTPS = calcTPS(totalStreamTokens, totalStreamMs)
	snap.E2ETPS = calcTPS(totalOutput, totalE2EMs)
	if totalSamples > 0 {
		snap.AvgTTFTMs = totalTTFTMs / int64(totalSamples)
	}
	snap.Latest = latest

	models := make([]ModelTPSStats, 0, len(byModel))
	for _, ma := range byModel {
		avgTTFT := int64(0)
		if ma.count > 0 {
			avgTTFT = ma.ttftMs / int64(ma.count)
		}
		models = append(models, ModelTPSStats{
			Model:          ma.model,
			ModelDisplay:   ma.display,
			PoolID:         ma.poolID,
			SampleCount:    ma.count,
			StreamSamples:  ma.streamCount,
			OutputTokens:   ma.outputTokens,
			StreamTPS:      calcTPS(ma.streamTokens, ma.streamMs),
			E2ETPS:         calcTPS(ma.outputTokens, ma.e2eMs),
			AvgTTFTMs:      avgTTFT,
			LastActiveUnix: ma.lastActiveUnix,
		})
	}
	sort.Slice(models, func(i, j int) bool {
		if models[i].OutputTokens != models[j].OutputTokens {
			return models[i].OutputTokens > models[j].OutputTokens
		}
		return models[i].LastActiveUnix > models[j].LastActiveUnix
	})
	snap.Models = models
	return snap, nil
}

// StepSpeedsForConversation returns per-step speed telemetry keyed by step_index.
func (m *Monitor) StepSpeedsForConversation(convID string) map[int]StepSpeed {
	if m.store == nil || strings.TrimSpace(convID) == "" {
		return nil
	}
	samples, err := m.store.QueryConversationTPSSamples(convID)
	if err != nil || len(samples) == 0 {
		return nil
	}
	out := make(map[int]StepSpeed, len(samples))
	for stepIdx, sm := range samples {
		turn := sampleToTurn(sm)
		out[stepIdx] = StepSpeed{
			OutputTokens: sm.OutputTokens,
			TTFTMs:       sm.TTFTMs,
			StreamingMs:  sm.StreamingMs,
			StreamTPS:    turn.StreamTPS,
			E2ETPS:       turn.E2ETPS,
		}
	}
	return out
}

func sampleToTurn(sm statestore.TPSSample) TPSTurn {
	var streamTPS float64
	if isValidStreamSample(sm.OutputTokens, sm.StreamingMs) {
		streamTPS = calcTPS(sm.OutputTokens, sm.StreamingMs)
	}
	return TPSTurn{
		ConversationID: sm.ConversationID,
		StepIndex:      sm.StepIndex,
		CreatedAtUnix:  sm.CreatedAtUnix,
		PoolID:         sm.PoolID,
		Model:          sm.Model,
		ModelDisplay:   sm.ModelDisplay,
		OutputTokens:   sm.OutputTokens,
		ThinkingTokens: sm.ThinkingTokens,
		ResponseTokens: sm.ResponseTokens,
		TTFTMs:         sm.TTFTMs,
		StreamingMs:    sm.StreamingMs,
		StreamTPS:      streamTPS,
		E2ETPS:         calcTPS(sm.OutputTokens, sm.TTFTMs+sm.StreamingMs),
	}
}

func isValidStreamSample(outputTokens, streamingMs int64) bool {
	return outputTokens >= MinStreamOutputTokens && streamingMs >= MinStreamDurationMs
}

func calcTPS(tokens, durationMs int64) float64 {
	if tokens <= 0 || durationMs <= 0 {
		return 0
	}
	raw := float64(tokens) / (float64(durationMs) / 1000.0)
	return math.Round(raw*10.0) / 10.0
}

func parseProtoDurationMs(raw string) int64 {
	s := strings.TrimSpace(raw)
	if s == "" {
		return 0
	}
	if d, err := time.ParseDuration(s); err == nil {
		if d < 0 {
			return 0
		}
		return d.Milliseconds()
	}
	if strings.HasSuffix(s, "s") {
		if sec, err := strconv.ParseFloat(strings.TrimSuffix(s, "s"), 64); err == nil && sec > 0 {
			return int64(math.Round(sec * 1000.0))
		}
	}
	return 0
}

func parseInt64Flex(raw json.RawMessage) int64 {
	s := strings.TrimSpace(string(raw))
	if s == "" || s == "null" {
		return 0
	}
	s = strings.Trim(s, `"`)
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0
	}
	return v
}

func classifyPool(modelID, display, provider string) string {
	s := strings.ToLower(modelID + " " + display + " " + provider)
	if strings.Contains(s, "claude") || strings.Contains(s, "anthropic") ||
		strings.Contains(s, "gpt") || strings.Contains(s, "openai") ||
		strings.Contains(s, "opus") || strings.Contains(s, "sonnet") {
		return "claude_gpt"
	}
	return "gemini"
}

type daemonHubFile struct {
	PID       int    `json:"pid"`
	HTTPPort  int    `json:"httpPort"`
	HTTPSPort int    `json:"httpsPort"`
	CSRFToken string `json:"csrfToken"`
}

func (m *Monitor) discoverEndpoint() (string, string, error) {
	if addr := strings.TrimSpace(m.envLookup("ANTIGRAVITY_LS_ADDRESS")); addr != "" {
		return addr, strings.TrimSpace(m.envLookup("ANTIGRAVITY_CSRF_TOKEN")), nil
	}
	if m.daemonDir == "" {
		return "", "", errors.New("antigravity daemon dir not configured")
	}
	matches, err := filepath.Glob(filepath.Join(m.daemonDir, "hub_*.json"))
	if err != nil || len(matches) == 0 {
		return "", "", errors.New("no live antigravity hub metadata found")
	}

	var bestAddr, bestCSRF string
	var bestMtime int64
	for _, path := range matches {
		fi, err := os.Stat(path)
		if err != nil {
			continue
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var meta daemonHubFile
		if err := json.Unmarshal(raw, &meta); err != nil || meta.PID <= 0 {
			continue
		}
		if !m.pidAlive(meta.PID) {
			continue
		}
		port := meta.HTTPPort
		if port <= 0 {
			port = meta.HTTPSPort
		}
		if port <= 0 {
			continue
		}
		if fi.ModTime().UnixNano() >= bestMtime {
			bestMtime = fi.ModTime().UnixNano()
			bestAddr = fmt.Sprintf("127.0.0.1:%d", port)
			bestCSRF = meta.CSRFToken
		}
	}
	if bestAddr == "" {
		return "", "", errors.New("antigravity language server not running")
	}
	return bestAddr, bestCSRF, nil
}
