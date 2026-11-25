package quotamonitor

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/antigravity-mobile/bridge/internal/statestore"
)

func TestLanguageServerProviderParsesRealTierAndQuotas(t *testing.T) {
	var gotCSRF string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotCSRF = r.Header.Get("x-codeium-csrf-token")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"userStatus": {
				"userTier": {"id": "g1-pro-tier", "name": "Google AI Pro"},
				"cascadeModelConfigData": {
					"defaultOverrideModelConfig": {"modelOrAlias": {"model": "MODEL_PLACEHOLDER_M532"}},
					"clientModelConfigs": [
						{
							"label": "Gemini 4 Neon (High)",
							"modelId": "gemini-4-neon-high",
							"tagTitle": "New",
							"modelOrAlias": {"model": "MODEL_PLACEHOLDER_M532"},
							"quotaInfo": {"remainingFraction": 0.3902266, "resetTime": "2026-11-24T17:56:18Z"}
						},
						{
							"label": "Claude Opus 5.5 (High)",
							"modelId": "claude-opus-5-5-high",
							"tagTitle": "New",
							"modelOrAlias": {"model": "MODEL_PLACEHOLDER_M402"},
							"quotaInfo": {"remainingFraction": 1, "resetTime": "2026-11-24T19:40:21Z"}
						}
					]
				}
			}
		}`))
	}))
	defer ts.Close()

	addr := strings.TrimPrefix(ts.URL, "http://")
	prov := NewLanguageServerProvider("", nil)
	prov.envLookup = func(k string) string {
		if k == "ANTIGRAVITY_LS_ADDRESS" {
			return addr
		}
		if k == "ANTIGRAVITY_CSRF_TOKEN" {
			return "csrf_123"
		}
		return ""
	}

	now, _ := time.Parse(time.RFC3339, "2026-11-24T14:44:00Z")
	snap, err := prov.Fetch(context.Background(), now)
	if err != nil {
		t.Fatalf("Fetch failed: %v", err)
	}
	if gotCSRF != "csrf_123" {
		t.Fatalf("expected csrf header, got %q", gotCSRF)
	}
	if snap.SubscriptionTier != "Google AI Pro" {
		t.Fatalf("expected Google AI Pro, got %q", snap.SubscriptionTier)
	}
	if len(snap.Pools) != 2 {
		t.Fatalf("expected 2 pools, got %d", len(snap.Pools))
	}
	gem := snap.Pools[0]
	if gem.PoolID != "gemini" || gem.Remaining5hPct != 39 || gem.Level != "warning" || gem.Reset5hAt == nil || gem.Source != "direct" {
		t.Fatalf("unexpected gemini pool: %+v", gem)
	}
	claude := snap.Pools[1]
	if claude.PoolID != "claude_gpt" || claude.Remaining5hPct != 100 || claude.Reset5hAt != nil || claude.Level != "full" {
		t.Fatalf("unexpected claude pool: %+v", claude)
	}
	if len(snap.Models) != 2 {
		t.Fatalf("expected 2 models, got %d", len(snap.Models))
	}
	if snap.Models[0].ModelID != "gemini-4-neon-high" || !snap.Models[0].IsDefault || snap.Models[0].Tag != "New" || snap.Models[0].PoolID != "gemini" {
		t.Fatalf("unexpected first model: %+v", snap.Models[0])
	}
	if snap.Models[1].ModelID != "claude-opus-5-5-high" || snap.Models[1].IsDefault || snap.Models[1].PoolID != "claude_gpt" {
		t.Fatalf("unexpected second model: %+v", snap.Models[1])
	}
}

func TestRefreshSnapshotBypassesLanguageServerCacheAndKeeps7dMonotonic(t *testing.T) {
	callCount := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		frac := "0.50"
		if callCount >= 3 {
			frac = "0.42"
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"userStatus": {
				"userTier": {"id": "g1-pro-tier", "name": "Google AI Pro"},
				"cascadeModelConfigData": {
					"clientModelConfigs": [
						{
							"label": "Gemini 4 Neon (High)",
							"modelId": "gemini-4-neon-high",
							"quotaInfo": {"remainingFraction": ` + frac + `, "resetTime": "2026-11-24T17:56:18Z"}
						}
					]
				}
			}
		}`))
	}))
	defer ts.Close()

	st, err := statestore.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now, _ := time.Parse(time.RFC3339, "2026-11-24T14:44:00Z")
	_ = st.RecordUsageBatch([]statestore.UsageEntry{
		{ConversationID: "c1", StepIndex: 1, CreatedAtUnix: now.Unix() - 3600, PoolID: "gemini", Model: "gemini-4-neon-high", InputTokens: 1_000_000, OutputTokens: 200_000},
		{ConversationID: "c0", StepIndex: 1, CreatedAtUnix: now.Unix() - 86400, PoolID: "gemini", Model: "gemini-4-neon-high", InputTokens: 3_000_000, OutputTokens: 600_000},
	})

	prov := NewLanguageServerProvider("", st)
	addr := strings.TrimPrefix(ts.URL, "http://")
	prov.envLookup = func(k string) string {
		if k == "ANTIGRAVITY_LS_ADDRESS" {
			return addr
		}
		return ""
	}

	mon := &Monitor{store: st, providers: []QuotaProvider{prov}, nowFn: func() time.Time { return now }}

	snap1, err := mon.Snapshot(context.Background())
	if err != nil || snap1.Pools[0].Remaining5hPct != 50 {
		t.Fatalf("expected initial 50%%, got %+v err=%v", snap1, err)
	}
	initial7d := snap1.Pools[0].Remaining7dPct

	// Within TTL, cached Snapshot still avoids extra LS calls.
	snapCached, err := mon.Snapshot(context.Background())
	if err != nil || snapCached.Pools[0].Remaining5hPct != 50 || callCount != 1 {
		t.Fatalf("expected cached 50%% with 1 call, got %+v calls=%d err=%v", snapCached, callCount, err)
	}

	// Simulate more local token usage while LS 5h percentage hasn't synced yet (still 50%).
	_ = st.RecordUsageBatch([]statestore.UsageEntry{
		{ConversationID: "c1", StepIndex: 2, CreatedAtUnix: now.Unix() - 60, PoolID: "gemini", Model: "gemini-4-neon-high", InputTokens: 1_000_000, OutputTokens: 200_000},
	})
	snap2, err := mon.RefreshSnapshot(context.Background())
	if err != nil || callCount != 2 {
		t.Fatalf("expected 2nd LS call on RefreshSnapshot, calls=%d err=%v", callCount, err)
	}
	if snap2.Pools[0].Remaining7dPct > initial7d {
		t.Fatalf("expected 7d remaining pct not to bounce upward as usage grew: before=%d after=%d", initial7d, snap2.Pools[0].Remaining7dPct)
	}

	// Next RefreshSnapshot picks up the updated 42% from LS immediately.
	snapFresh, err := mon.RefreshSnapshot(context.Background())
	if err != nil || snapFresh.Pools[0].Remaining5hPct != 42 || callCount != 3 {
		t.Fatalf("expected refreshed 42%% with 3 calls, got %+v calls=%d err=%v", snapFresh, callCount, err)
	}
}
