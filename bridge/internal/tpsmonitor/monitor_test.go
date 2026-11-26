package tpsmonitor

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/antigravity-mobile/bridge/internal/statestore"
)

func TestSyncConversationIncrementalOffsetAndBurstFilter(t *testing.T) {
	tmp := t.TempDir()
	st, err := statestore.Open(filepath.Join(tmp, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	baseNow := time.Unix(1795600000, 0)
	// Seed usage_ledger timestamps for steps 3, 8, 10 so syncConversation aligns timestamps accurately.
	if err := st.RecordUsageBatch([]statestore.UsageEntry{
		{ConversationID: "conv-1", StepIndex: 3, CreatedAtUnix: baseNow.Unix() - 120, PoolID: "gemini", Model: "gemini-4-neon-high", OutputTokens: 201},
		{ConversationID: "conv-1", StepIndex: 8, CreatedAtUnix: baseNow.Unix() - 60, PoolID: "gemini", Model: "gemini-4-neon-high", OutputTokens: 1655},
		{ConversationID: "conv-1", StepIndex: 10, CreatedAtUnix: baseNow.Unix() - 10, PoolID: "claude_gpt", Model: "claude-opus-5-5-high", OutputTokens: 800},
	}); err != nil {
		t.Fatal(err)
	}

	var gotOffsets []int
	callNum := 0
	mockLS := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-codeium-csrf-token") != "csrf_tok" {
			http.Error(w, "missing csrf", http.StatusForbidden)
			return
		}
		var req struct {
			CascadeID string `json:"cascadeId"`
			Offset    int    `json:"generatorMetadataOffset"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		gotOffsets = append(gotOffsets, req.Offset)
		callNum++

		var items []map[string]any
		if callNum == 1 {
			// Call 1 returns:
			// [0] canceled error entry (terminal)
			// [1] short single-chunk burst: out=201, stream=3.4ms (must NOT inflate streamTps)
			// [2] normal streaming turn: out=1655, ttft=6.0s, stream=10.0s -> streamTps=165.5, e2eTps=103.4
			// [3] in-flight trailing turn with outputTokens=0 and no error (offset must stop at 3, not 4!)
			items = []map[string]any{
				{
					"error": "context canceled",
					"chatModel": map[string]any{
						"model": "MODEL_PLACEHOLDER_M532",
					},
				},
				{
					"stepIndices": []int{3, 4},
					"chatModel": map[string]any{
						"responseModel":     "gemini-4-neon",
						"modelDisplayName":  "Gemini 4 Neon (High)",
						"timeToFirstToken":  "4.667s",
						"streamingDuration": "0.00347s",
						"usage": map[string]any{
							"outputTokens":         "201",
							"thinkingOutputTokens": "113",
							"responseOutputTokens": "88",
							"apiProvider":          "API_PROVIDER_GOOGLE_GEMINI",
						},
					},
				},
				{
					"stepIndices": []int{8, 9},
					"chatModel": map[string]any{
						"responseModel":     "gemini-4-neon",
						"modelDisplayName":  "Gemini 4 Neon (High)",
						"timeToFirstToken":  "6.0s",
						"streamingDuration": "10.0s",
						"usage": map[string]any{
							"outputTokens":         "1655",
							"thinkingOutputTokens": "343",
							"responseOutputTokens": "1312",
							"apiProvider":          "API_PROVIDER_GOOGLE_GEMINI",
						},
					},
				},
				{
					"stepIndices": []int{10},
					"chatModel": map[string]any{
						"modelDisplayName": "Claude Opus 5.5 (High)",
						"usage":            map[string]any{},
					},
				},
			}
		} else {
			// Call 2 resumes from offset=3 and now entry [3] has completed!
			items = []map[string]any{
				{
					"stepIndices": []int{10},
					"chatModel": map[string]any{
						"responseModel":     "claude-opus-5-5",
						"modelDisplayName":  "Claude Opus 5.5 (High)",
						"timeToFirstToken":  "2.0s",
						"streamingDuration": "8.0s",
						"usage": map[string]any{
							"outputTokens": "800",
							"apiProvider":  "API_PROVIDER_ANTHROPIC",
						},
					},
				},
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"generatorMetadata": items})
	}))
	defer mockLS.Close()

	mon := NewMonitor("", st)
	mon.nowFn = func() time.Time { return baseNow }
	mon.envLookup = func(k string) string {
		if k == "ANTIGRAVITY_LS_ADDRESS" {
			return strings.TrimPrefix(mockLS.URL, "http://")
		}
		if k == "ANTIGRAVITY_CSRF_TOKEN" {
			return "csrf_tok"
		}
		return ""
	}

	// First sync: captures step 3 & step 8, holds offset at 3 because index 3 is still in-flight.
	n1, err := mon.SyncConversation(context.Background(), "conv-1")
	if err != nil {
		t.Fatalf("first SyncConversation: %v", err)
	}
	if n1 != 2 {
		t.Fatalf("expected 2 synced samples, got %d", n1)
	}
	off1, _ := st.GetTPSOffset("conv-1")
	if off1 != 3 {
		t.Fatalf("expected offset=3 (stopping before in-flight trailing turn), got %d", off1)
	}

	// Verify burst sample (step 3) has streamTps == 0 (never inflated to 57k), while e2eTps > 0.
	speeds := mon.StepSpeedsForConversation("conv-1")
	if speeds[3].StreamTPS != 0 {
		t.Fatalf("expected burst sample streamTps=0, got %.1f", speeds[3].StreamTPS)
	}
	if speeds[3].E2ETPS <= 40 || speeds[3].E2ETPS >= 45 {
		t.Fatalf("expected burst sample e2eTps ~43.0, got %.1f", speeds[3].E2ETPS)
	}
	if speeds[8].StreamTPS != 165.5 {
		t.Fatalf("expected step 8 streamTps=165.5, got %.1f", speeds[8].StreamTPS)
	}

	// Second sync: resumes from offset=3 and picks up completed Claude turn (step 10).
	n2, err := mon.SyncConversation(context.Background(), "conv-1")
	if err != nil {
		t.Fatalf("second SyncConversation: %v", err)
	}
	if n2 != 1 {
		t.Fatalf("expected 1 new sample on second sync, got %d", n2)
	}
	if len(gotOffsets) != 2 || gotOffsets[0] != 0 || gotOffsets[1] != 3 {
		t.Fatalf("unexpected offsets sent to LS: %v", gotOffsets)
	}
	off2, _ := st.GetTPSOffset("conv-1")
	if off2 != 4 {
		t.Fatalf("expected offset=4 after completion, got %d", off2)
	}

	// Snapshot aggregates 5h window weighted across Gemini + Claude.
	snap, err := mon.Snapshot(context.Background())
	if err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	if snap.SampleCount != 3 || snap.StreamSamples != 2 {
		t.Fatalf("unexpected sample counts: total=%d stream=%d", snap.SampleCount, snap.StreamSamples)
	}
	// Weighted stream TPS = (1655 + 800) / (10s + 8s) = 2455 / 18 = 136.4
	if snap.StreamTPS != 136.4 {
		t.Fatalf("expected weighted streamTps=136.4, got %.1f", snap.StreamTPS)
	}
	if snap.Latest == nil || snap.Latest.StepIndex != 10 || snap.Latest.PoolID != "claude_gpt" {
		t.Fatalf("expected latest turn to be step 10 claude_gpt, got %+v", snap.Latest)
	}
	if snap.Latest.StreamTPS != 100.0 || snap.Latest.E2ETPS != 80.0 {
		t.Fatalf("expected latest turn stream=100.0 e2e=80.0, got %+v", snap.Latest)
	}
	if len(snap.Models) != 2 {
		t.Fatalf("expected 2 models, got %d", len(snap.Models))
	}
	// Sorted by outputTokens desc: Gemini (1856) before Claude (800)
	if snap.Models[0].ModelDisplay != "Gemini 4 Neon (High)" || snap.Models[0].StreamTPS != 165.5 {
		t.Fatalf("unexpected top model stats: %+v", snap.Models[0])
	}
	if snap.Models[1].ModelDisplay != "Claude Opus 5.5 (High)" || snap.Models[1].StreamTPS != 100.0 {
		t.Fatalf("unexpected second model stats: %+v", snap.Models[1])
	}
}

func TestSnapshotExcludesOldSamplesFrom5hWindowButKeepsLatestHistory(t *testing.T) {
	tmp := t.TempDir()
	st, err := statestore.Open(filepath.Join(tmp, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Unix(1795600000, 0)
	// Insert a sample from 8 hours ago (outside 5h window)
	if err := st.RecordTPSSamples([]statestore.TPSSample{
		{
			ConversationID: "conv-old",
			StepIndex:      5,
			CreatedAtUnix:  now.Unix() - 8*3600,
			PoolID:         "gemini",
			Model:          "gemini-4-hydrogen",
			ModelDisplay:   "Gemini 4 Hydrogen (High)",
			OutputTokens:   1000,
			TTFTMs:         3000,
			StreamingMs:    5000,
		},
	}); err != nil {
		t.Fatal(err)
	}

	mon := NewMonitor("", st)
	mon.nowFn = func() time.Time { return now }

	snap, err := mon.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if snap.SampleCount != 0 || len(snap.Models) != 0 || snap.StreamTPS != 0 {
		t.Fatalf("expected empty 5h window stats, got %+v", snap)
	}
	if snap.Latest == nil || snap.Latest.StreamTPS != 200.0 || snap.Latest.ConversationID != "conv-old" {
		t.Fatalf("expected historical latest fallback turn, got %+v", snap.Latest)
	}
}

func TestSyncRecentPreservesHistoricalTimestampWithoutUsageLedger(t *testing.T) {
	tmp := t.TempDir()
	st, err := statestore.Open(filepath.Join(tmp, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Unix(1795600000, 0)
	sixMonthsAgo := now.Unix() - 180*24*3600

	mockLS := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"generatorMetadata": []map[string]any{
				{
					"stepIndices": []int{4},
					"chatModel": map[string]any{
						"responseModel":     "gemini-3.1-pro-high",
						"modelDisplayName":  "gemini-3.1-pro-high",
						"timeToFirstToken":  "4.5s",
						"streamingDuration": "1.0s",
						"usage": map[string]any{
							"outputTokens": "200",
							"apiProvider":  "API_PROVIDER_GOOGLE_GEMINI",
						},
					},
				},
			},
		})
	}))
	defer mockLS.Close()

	mon := NewMonitor("", st)
	mon.nowFn = func() time.Time { return now }
	mon.envLookup = func(k string) string {
		if k == "ANTIGRAVITY_LS_ADDRESS" {
			return strings.TrimPrefix(mockLS.URL, "http://")
		}
		return ""
	}

	// Historical session has no usage_ledger rows; fallback LastModifiedUnix must keep it outside 5h window.
	n := mon.SyncRecent(context.Background(), []ConversationRef{
		{ConversationID: "conv-ancient", LastModifiedUnix: sixMonthsAgo},
	})
	if n != 1 {
		t.Fatalf("expected 1 synced historical sample, got %d", n)
	}

	snap, err := mon.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if snap.SampleCount != 0 || len(snap.Models) != 0 {
		t.Fatalf("historical conversation without usage_ledger must not pollute 5h window: %+v", snap)
	}
	if snap.Latest == nil || snap.Latest.CreatedAtUnix != sixMonthsAgo {
		t.Fatalf("expected latest fallback timestamp=%d, got %+v", sixMonthsAgo, snap.Latest)
	}
}
