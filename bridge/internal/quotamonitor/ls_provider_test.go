package quotamonitor

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
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
					"clientModelConfigs": [
						{
							"label": "Gemini 4 Neon (High)",
							"modelId": "gemini-4-neon-high",
							"quotaInfo": {"remainingFraction": 0.3902266, "resetTime": "2026-11-24T17:56:18Z"}
						},
						{
							"label": "Claude Opus 5.5 (High)",
							"modelId": "claude-opus-5-5-high",
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
}
